import Foundation

/// The ledger when there is no database: local development, the test suite, and
/// the degraded mode a failed restore leaves the bot in (§4.3).
///
/// It keeps the same shape — a claim that can only be taken once, a journal
/// line for every movement, a balance that cannot go below zero — so the code
/// above it cannot tell the two apart and cannot grow a dependency on Postgres
/// semantics that only Postgres provides. What it does *not* provide is
/// durability, which is exactly why `StateDurability.volatile` refuses to sell
/// anything while this is the ledger in use.
actor InMemoryLedger: LedgerPort {
    private var claims: Set<String> = []
    private var wallets: [UserKey: UserBalance] = [:]
    private var entries: [LedgerEntry] = []
    private var subscriptions: [UserKey: Date?] = [:]
    private var discounts: [UserKey: SubscriptionDiscount?] = [:]

    /// Where a fresh instance gets its starting wallets from — the store's
    /// restored cache, so a memory-only bot still knows what it knew.
    init(wallets: [UserKey: UserBalance] = [:]) {
        self.wallets = wallets
    }

    func inTransaction<T: Sendable>(
        _ body: @Sendable (any LedgerTransaction) async throws -> T
    ) async throws -> T {
        // The actor is the transaction: nothing else runs while `body` does, so
        // a partial application is not observable. A thrown error still leaves
        // the mutations that already happened — the honest difference from a
        // real transaction, and the reason this type is not used in production.
        try await body(Transaction(ledger: self))
    }

    func syncWallets(changed: [UserKey: UserBalance], removed: [UserKey]) async throws {
        // Journalled exactly like the Postgres side: a wallet that moved outside
        // a transaction still gets its line, and a deleted one gets a closing
        // line that brings its journal back to zero. Without this the two
        // implementations disagree about `reconcile()`, and a rule proved
        // against the in-memory ledger would say nothing about the real one.
        for key in removed {
            guard let wallet = wallets.removeValue(forKey: key), !wallet.balance.isZero else { continue }
            entries.append(LedgerEntry(
                userKey: key, kind: .correction, amount: -wallet.balance,
                balanceAfter: .zero, ref: "wallet deleted", createdAt: Date()
            ))
        }
        for (key, wallet) in changed {
            let before = wallets[key]?.balance ?? .zero
            wallets[key] = wallet
            let delta = wallet.balance - before
            guard !delta.isZero else { continue }
            entries.append(LedgerEntry(
                userKey: key, kind: .correction, amount: delta,
                balanceAfter: wallet.balance, ref: "sync", createdAt: Date()
            ))
        }
    }

    func recentEntries(userKey: UserKey, limit: Int) async throws -> [LedgerEntry] {
        entries.filter { $0.userKey == userKey }.suffix(limit).reversed()
    }

    func reconcile() async throws -> [UserKey] {
        var sums: [UserKey: Money] = [:]
        for entry in entries { sums[entry.userKey, default: .zero] += entry.amount }
        return wallets.compactMap { key, wallet in
            (sums[key] ?? .zero) == wallet.balance ? nil : key
        }
    }

    // MARK: - Operations

    fileprivate func claim(_ key: String) -> Bool { claims.insert(key).inserted }

    fileprivate func applyCredit(
        _ key: UserKey,
        _ amount: Money,
        kind: LedgerEntryKind,
        purchased: Bool,
        ref: String?
    ) -> UserBalance {
        var wallet = wallets[key] ?? .empty
        let before = wallet.balance
        wallet.balance = (wallet.balance + amount).clampedToZero
        if purchased {
            wallet.toppedUp += amount
            wallet.lapsedNoticeAt = nil
        }
        wallet.updatedAt = Date()
        wallets[key] = wallet
        let delta = wallet.balance - before
        if !delta.isZero {
            entries.append(LedgerEntry(
                userKey: key, kind: kind, amount: delta,
                balanceAfter: wallet.balance, ref: ref, createdAt: Date()
            ))
        }
        return wallet
    }

    fileprivate func applyDebit(_ key: UserKey, upTo amount: Money, real: Money, ref: String?) -> WalletDebit {
        guard var wallet = wallets[key] else {
            return WalletDebit(charged: .zero, remaining: .zero, depleted: false)
        }
        let charged = Money.min(amount, wallet.balance)
        wallet.balance -= charged
        wallet.spentBilled += charged
        wallet.spentReal += real
        wallet.updatedAt = Date()
        wallets[key] = wallet
        if charged.isPositive {
            entries.append(LedgerEntry(
                userKey: key, kind: .charge, amount: -charged,
                balanceAfter: wallet.balance, ref: ref, createdAt: Date()
            ))
        }
        return WalletDebit(
            charged: charged,
            remaining: wallet.balance,
            depleted: charged.isPositive && !wallet.balance.isPositive
        )
    }

    fileprivate func applySetBalance(_ key: UserKey, to amount: Money, ref: String?) -> UserBalance {
        var wallet = wallets[key] ?? .empty
        let before = wallet.balance
        wallet.balance = amount.clampedToZero
        wallet.updatedAt = Date()
        wallets[key] = wallet
        let delta = wallet.balance - before
        if !delta.isZero {
            entries.append(LedgerEntry(
                userKey: key, kind: .correction, amount: delta,
                balanceAfter: wallet.balance, ref: ref, createdAt: Date()
            ))
        }
        return wallet
    }

    fileprivate func applyExtension(_ key: UserKey, days: Int) -> SubscriptionExtension {
        let existing = subscriptions[key]
        guard let current = existing else {
            let until = Date().addingTimeInterval(TimeInterval(days) * 86_400)
            subscriptions[key] = .some(until)
            return SubscriptionExtension(paidUntil: until, isNew: true, wasUnlimited: false)
        }
        guard let paidUntil = current else {
            return SubscriptionExtension(paidUntil: nil, isNew: false, wasUnlimited: true)
        }
        let until = max(Date(), paidUntil).addingTimeInterval(TimeInterval(days) * 86_400)
        subscriptions[key] = .some(until)
        return SubscriptionExtension(paidUntil: until, isNew: false, wasUnlimited: false)
    }

    fileprivate func applySubscription(_ key: UserKey, paidUntil: Date?) {
        subscriptions[key] = .some(paidUntil)
    }

    fileprivate func applyDiscount(_ key: UserKey, _ discount: SubscriptionDiscount?) {
        discounts[key] = .some(discount)
    }

    private struct Transaction: LedgerTransaction {
        let ledger: InMemoryLedger

        func claimPayment(_ receipt: PaymentReceipt) async throws -> Bool {
            await ledger.claim("pay:" + receipt.idempotencyKey)
        }

        func claim(_ key: String) async throws -> Bool {
            await ledger.claim(key)
        }

        @discardableResult
        func credit(
            _ userKey: UserKey, _ amount: Money, kind: LedgerEntryKind, purchased: Bool, ref: String?
        ) async throws -> UserBalance {
            await ledger.applyCredit(userKey, amount, kind: kind, purchased: purchased, ref: ref)
        }

        func debit(_ userKey: UserKey, upTo amount: Money, real: Money, ref: String?) async throws -> WalletDebit {
            await ledger.applyDebit(userKey, upTo: amount, real: real, ref: ref)
        }

        @discardableResult
        func setBalance(_ userKey: UserKey, to amount: Money, ref: String?) async throws -> UserBalance {
            await ledger.applySetBalance(userKey, to: amount, ref: ref)
        }

        func extendSubscription(
            _ userKey: UserKey, days: Int, defaults: TenantDefaults
        ) async throws -> SubscriptionExtension {
            await ledger.applyExtension(userKey, days: days)
        }

        func setSubscription(_ userKey: UserKey, paidUntil: Date?) async throws {
            await ledger.applySubscription(userKey, paidUntil: paidUntil)
        }

        func setWinbackDiscount(_ userKey: UserKey, _ discount: SubscriptionDiscount?) async throws {
            await ledger.applyDiscount(userKey, discount)
        }
    }
}
