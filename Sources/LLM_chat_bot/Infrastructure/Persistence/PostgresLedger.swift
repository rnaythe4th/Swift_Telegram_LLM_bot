import Foundation
import Logging
import PostgresNIO

/// The money half of persistence: wallets, the journal, payment idempotency and
/// subscription end dates, all written through real transactions.
///
/// Every balance change here is a single statement — no read-modify-write —
/// so two turns of the same person cannot both spend the same remaining
/// balance, and two deliveries of one payment cannot both be applied. The row
/// lock Postgres takes on `UPDATE` does what an actor was accidentally doing
/// before, and does it across processes as well as across tasks.
final class PostgresLedger: LedgerPort, Sendable {
    private let client: PostgresClient
    private let queryLogger: Logger

    init(client: PostgresClient, logger: LoggerPort) {
        self.client = client
        self.queryLogger = Logger(label: "postgres.ledger") { _ in PostgresLogHandler(sink: logger) }
    }

    func inTransaction<T: Sendable>(
        _ body: @Sendable (any LedgerTransaction) async throws -> T
    ) async throws -> T {
        let log = queryLogger
        return try await client.withTransaction(logger: log) { connection in
            try await body(Transaction(connection: connection, logger: log))
        }
    }

    func syncWallets(changed: [UserKey: UserBalance], removed: [UserKey]) async throws {
        guard !changed.isEmpty || !removed.isEmpty else { return }
        let log = queryLogger
        try await client.withTransaction(logger: log) { db in
            for key in removed {
                // The journal outlives the wallet on purpose — it is the
                // evidence behind every движение — but `reconcile()` sums it
                // from the beginning, so rows left behind under a deleted key
                // would never balance again once somebody topped up under that
                // same key a second time: a permanent mismatch alert nobody can
                // clear. A closing line brings the sum back to zero and keeps
                // the history.
                let rows = try await db.query(
                    "delete from bot_wallet where user_key = \(key) returning balance_nanos",
                    logger: log
                )
                var closing = Money.zero
                for try await row in rows {
                    closing = .nanos(try PostgresRandomAccessRow(row)["balance_nanos"].decode(Int64.self))
                }
                guard !closing.isZero else { continue }
                try await db.query(
                    """
                    insert into bot_ledger (user_key, kind, amount_nanos, balance_after_nanos, ref)
                    values (\(key), \(LedgerEntryKind.correction.rawValue), \((-closing).nanoValue),
                            \(Int64(0)), 'wallet deleted')
                    """,
                    logger: log
                )
            }
            for (key, wallet) in changed {
                // The journal is why a balance can be explained, so a wallet
                // that moved outside a transaction still gets a line —
                // otherwise `reconcile()` would flag every rename and every
                // super-admin adjustment as corruption. The delta is measured
                // against what is stored, so writing the same wallet twice
                // records nothing the second time.
                var before = Money.zero
                let previous = try await db.query(
                    "select balance_nanos from bot_wallet where user_key = \(key) for update",
                    logger: log
                )
                for try await row in previous {
                    before = .nanos(try PostgresRandomAccessRow(row)["balance_nanos"].decode(Int64.self))
                }
                try await db.query(
                    """
                    insert into bot_wallet (
                        user_key, balance_nanos, topped_up_nanos, spent_billed_nanos, spent_real_nanos,
                        lapsed_notice_at, updated_at
                    ) values (
                        \(key), \(wallet.balance.nanoValue), \(wallet.toppedUp.nanoValue),
                        \(wallet.spentBilled.nanoValue), \(wallet.spentReal.nanoValue),
                        \(wallet.lapsedNoticeAt), now()
                    )
                    on conflict (user_key) do update set
                        balance_nanos = excluded.balance_nanos,
                        topped_up_nanos = excluded.topped_up_nanos,
                        spent_billed_nanos = excluded.spent_billed_nanos,
                        spent_real_nanos = excluded.spent_real_nanos,
                        lapsed_notice_at = excluded.lapsed_notice_at,
                        updated_at = excluded.updated_at
                    """,
                    logger: log
                )
                let delta = wallet.balance - before
                guard !delta.isZero else { continue }
                try await db.query(
                    """
                    insert into bot_ledger (user_key, kind, amount_nanos, balance_after_nanos, ref)
                    values (\(key), \(LedgerEntryKind.correction.rawValue), \(delta.nanoValue),
                            \(wallet.balance.nanoValue), 'sync')
                    """,
                    logger: log
                )
            }
        }
    }

    func recentEntries(userKey: UserKey, limit: Int) async throws -> [LedgerEntry] {
        let rows = try await client.query(
            """
            select kind, amount_nanos, balance_after_nanos, ref, created_at
              from bot_ledger where user_key = \(userKey)
             order by id desc limit \(limit)
            """,
            logger: queryLogger
        )
        var result: [LedgerEntry] = []
        for try await row in rows {
            let cells = PostgresRandomAccessRow(row)
            result.append(LedgerEntry(
                userKey: userKey,
                kind: LedgerEntryKind(rawValue: try cells["kind"].decode(String.self)) ?? .correction,
                amount: .nanos(try cells["amount_nanos"].decode(Int64.self)),
                balanceAfter: .nanos(try cells["balance_after_nanos"].decode(Int64.self)),
                ref: try cells["ref"].decode(String?.self),
                createdAt: try cells["created_at"].decode(Date.self)
            ))
        }
        return result
    }

    func reconcile() async throws -> [UserKey] {
        // A wallet whose journal does not add up to its balance means something
        // wrote money without writing its reason. Left to a support ticket this
        // is unanswerable; found by a sweep it is one line in an alert.
        let rows = try await client.query(
            """
            select w.user_key
              from bot_wallet w
              left join (
                  select user_key, sum(amount_nanos) as total from bot_ledger group by user_key
              ) l on l.user_key = w.user_key
             where w.balance_nanos <> coalesce(l.total, 0)
            """,
            logger: queryLogger
        )
        var mismatched: [UserKey] = []
        for try await row in rows {
            mismatched.append(try PostgresRandomAccessRow(row)["user_key"].decode(UserKey.self))
        }
        return mismatched
    }

    // MARK: - Transaction

    private struct Transaction: LedgerTransaction {
        let connection: PostgresConnection
        let logger: Logger

        func claimPayment(_ receipt: PaymentReceipt) async throws -> Bool {
            let amountCents: Int?
            let purpose: String
            switch receipt.purpose {
            case .subscription:
                purpose = "subscription"
                amountCents = nil
            case .credit(let cents):
                purpose = "credit"
                amountCents = cents
            }
            // `returning` yields a row only when the insert actually happened.
            // Checking and claiming in one statement is what makes this safe
            // against a redelivery landing in another process at the same time.
            let rows = try await connection.query(
                """
                insert into bot_payment (idempotency_key, user_key, purpose, amount_cents, chat_id, method)
                values (\(receipt.idempotencyKey), \(receipt.payerKey), \(purpose), \(amountCents),
                        \(Int64(receipt.chatID.value)), \(receipt.method.rawValue))
                on conflict (idempotency_key) do nothing
                returning idempotency_key
                """,
                logger: logger
            )
            for try await _ in rows { return true }
            return false
        }

        func claim(_ key: String) async throws -> Bool {
            let rows = try await connection.query(
                """
                insert into bot_claim (key) values (\(key))
                on conflict (key) do nothing
                returning key
                """,
                logger: logger
            )
            for try await _ in rows { return true }
            return false
        }

        @discardableResult
        func credit(
            _ userKey: UserKey,
            _ amount: Money,
            kind: LedgerEntryKind,
            purchased: Bool,
            ref: String?
        ) async throws -> UserBalance {
            // Lock first, then write — two statements rather than one clever
            // CTE. A `select … for update` *inside* the same statement as the
            // UPDATE returns no row at all (the row version it would lock has
            // already been superseded by the UPDATE's own command), which is a
            // silent NULL rather than an error. Inside a transaction two
            // statements are just as atomic and say what they mean.
            let before = try await lockedBalance(userKey)
            let rows = try await connection.query(
                """
                insert into bot_wallet (user_key, balance_nanos, topped_up_nanos, updated_at)
                values (\(userKey), greatest(\(amount.nanoValue), 0), greatest(\(purchased ? amount.nanoValue : 0), 0), now())
                on conflict (user_key) do update set
                    balance_nanos = greatest(bot_wallet.balance_nanos + \(amount.nanoValue), 0),
                    topped_up_nanos = greatest(bot_wallet.topped_up_nanos + \(purchased ? amount.nanoValue : 0), 0),
                    lapsed_notice_at = case when \(purchased) then null else bot_wallet.lapsed_notice_at end,
                    updated_at = now()
                returning balance_nanos, topped_up_nanos, spent_billed_nanos, spent_real_nanos,
                          lapsed_notice_at, updated_at
                """,
                logger: logger
            )
            var wallet = UserBalance.empty
            for try await row in rows {
                wallet = try Self.wallet(from: PostgresRandomAccessRow(row))
            }
            // The journal line records the *actual* delta: a negative
            // correction against a small balance moves less than it asked for,
            // and writing the asked-for amount would make `reconcile()` report
            // a mismatch that is really just the floor doing its job.
            let delta = wallet.balance - (before ?? .zero)
            if !delta.isZero {
                try await writeEntry(userKey, kind: kind, amount: delta, balanceAfter: wallet.balance, ref: ref)
            }
            return wallet
        }

        func debit(
            _ userKey: UserKey,
            upTo amount: Money,
            real: Money,
            ref: String?
        ) async throws -> WalletDebit {
            // The row lock is taken before the arithmetic, so two turns of the
            // same person cannot both spend the same remainder. The floor is
            // expressed twice on purpose — here, and as a `check` constraint
            // one level down.
            guard let before = try await lockedBalance(userKey) else {
                // No wallet row: the caller only bills a key `billingKey` handed
                // it, so this is a race with a deletion.
                return WalletDebit(charged: .zero, remaining: .zero, depleted: false)
            }
            let rows = try await connection.query(
                """
                update bot_wallet
                   set balance_nanos      = greatest(balance_nanos - \(amount.nanoValue), 0),
                       spent_billed_nanos = spent_billed_nanos + least(\(amount.nanoValue), balance_nanos),
                       spent_real_nanos   = spent_real_nanos + \(real.nanoValue),
                       updated_at         = now()
                 where user_key = \(userKey)
                returning balance_nanos
                """,
                logger: logger
            )
            var remaining = Money.zero
            for try await row in rows {
                remaining = .nanos(try PostgresRandomAccessRow(row)["balance_nanos"].decode(Int64.self))
            }
            let charged = before - remaining
            if charged.isPositive {
                try await writeEntry(userKey, kind: .charge, amount: -charged, balanceAfter: remaining, ref: ref)
            }
            return WalletDebit(
                charged: charged,
                remaining: remaining,
                depleted: charged.isPositive && !remaining.isPositive
            )
        }

        @discardableResult
        func setBalance(_ userKey: UserKey, to amount: Money, ref: String?) async throws -> UserBalance {
            // Same shape as `credit`: lock, then write. The floor lives here as
            // well as in the column's `check` — a super-admin typing a negative
            // amount is a correction to zero, not a debt.
            let before = try await lockedBalance(userKey)
            let target = amount.clampedToZero
            let rows = try await connection.query(
                """
                insert into bot_wallet (user_key, balance_nanos, updated_at)
                values (\(userKey), \(target.nanoValue), now())
                on conflict (user_key) do update set
                    balance_nanos = excluded.balance_nanos,
                    updated_at = now()
                returning balance_nanos, topped_up_nanos, spent_billed_nanos, spent_real_nanos,
                          lapsed_notice_at, updated_at
                """,
                logger: logger
            )
            var wallet = UserBalance.empty
            for try await row in rows {
                wallet = try Self.wallet(from: PostgresRandomAccessRow(row))
            }
            let delta = wallet.balance - (before ?? .zero)
            if !delta.isZero {
                try await writeEntry(
                    userKey, kind: .correction, amount: delta, balanceAfter: wallet.balance, ref: ref
                )
            }
            return wallet
        }

        /// Locks one wallet row and returns its balance, or nil when there is
        /// no such wallet yet.
        private func lockedBalance(_ userKey: UserKey) async throws -> Money? {
            let rows = try await connection.query(
                "select balance_nanos from bot_wallet where user_key = \(userKey) for update",
                logger: logger
            )
            for try await row in rows {
                return .nanos(try PostgresRandomAccessRow(row)["balance_nanos"].decode(Int64.self))
            }
            return nil
        }

        func extendSubscription(
            _ userKey: UserKey,
            days: Int,
            defaults: TenantDefaults
        ) async throws -> SubscriptionExtension {
            // `greatest(now(), paid_until)` in SQL rather than in Swift: two
            // renewals arriving together would otherwise both read the same end
            // date and the second would swallow the first.
            //
            // An unlimited tenant (`paid_until is null`) stays unlimited —
            // paying must never shorten access.
            let rows = try await connection.query(
                """
                insert into bot_tenant (
                    user_key, owner_username, paid_until, default_model, default_role, default_history, created_at
                ) values (
                    \(userKey), \(defaults.ownerKey), now() + (\(Double(days)) * interval '1 day'),
                    \(defaults.model), \(defaults.role), \(defaults.historyLength), now()
                )
                on conflict (user_key) do update set
                    paid_until = case
                        when bot_tenant.paid_until is null then null
                        else greatest(now(), bot_tenant.paid_until) + (\(Double(days)) * interval '1 day')
                    end,
                    updated_at = now()
                returning paid_until, (xmax = 0) as inserted
                """,
                logger: logger
            )
            for try await row in rows {
                let cells = PostgresRandomAccessRow(row)
                let paidUntil = try cells["paid_until"].decode(Date?.self)
                let inserted = try cells["inserted"].decode(Bool.self)
                return SubscriptionExtension(
                    paidUntil: paidUntil,
                    isNew: inserted,
                    wasUnlimited: !inserted && paidUntil == nil
                )
            }
            return SubscriptionExtension(paidUntil: nil, isNew: false, wasUnlimited: true)
        }

        func setSubscription(_ userKey: UserKey, paidUntil: Date?) async throws {
            try await connection.query(
                "update bot_tenant set paid_until = \(paidUntil), updated_at = now() where user_key = \(userKey)",
                logger: logger
            )
        }

        func setWinbackDiscount(_ userKey: UserKey, _ discount: SubscriptionDiscount?) async throws {
            try await connection.query(
                """
                update bot_tenant
                   set winback_percent = \(discount?.percent),
                       winback_expires_at = \(discount?.expiresAt),
                       updated_at = now()
                 where user_key = \(userKey)
                """,
                logger: logger
            )
        }

        private func writeEntry(
            _ userKey: UserKey,
            kind: LedgerEntryKind,
            amount: Money,
            balanceAfter: Money,
            ref: String?
        ) async throws {
            try await connection.query(
                """
                insert into bot_ledger (user_key, kind, amount_nanos, balance_after_nanos, ref)
                values (\(userKey), \(kind.rawValue), \(amount.nanoValue), \(balanceAfter.nanoValue), \(ref))
                """,
                logger: logger
            )
        }

        private static func wallet(from cells: PostgresRandomAccessRow) throws -> UserBalance {
            UserBalance(
                balance: .nanos(try cells["balance_nanos"].decode(Int64.self)),
                spentBilled: .nanos(try cells["spent_billed_nanos"].decode(Int64.self)),
                spentReal: .nanos(try cells["spent_real_nanos"].decode(Int64.self)),
                updatedAt: try cells["updated_at"].decode(Date.self),
                toppedUp: .nanos(try cells["topped_up_nanos"].decode(Int64.self)),
                lapsedNoticeAt: try cells["lapsed_notice_at"].decode(Date?.self)
            )
        }
    }
}
