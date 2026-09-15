import XCTest
@testable import LLM_chat_bot

/// Rules about money that must hold whichever ledger is underneath: a payment
/// is applied once, a wallet never goes below zero, and the journal always adds
/// up to the balance it explains (§2.3, §3.2, §7.3).
///
/// These run against `InMemoryLedger`, which deliberately implements the same
/// contract as `PostgresLedger`. That makes them a statement about the contract
/// rather than about one implementation — and the Postgres side is held to it
/// by the same statements running against a real database in
/// `PostgresLedgerIntegrationTests` when one is available.
final class LedgerTests: XCTestCase {

    private static func receipt(
        _ key: UserKey = .identified(1),
        purpose: PurchasePurpose = .subscription,
        idempotencyKey: String = "charge-1"
    ) -> PaymentReceipt {
        PaymentReceipt(
            payerKey: key,
            payerUserID: 1,
            chatID: 1,
            purpose: purpose,
            idempotencyKey: idempotencyKey,
            method: .stars
        )
    }

    /// The rule the 500-entry list in memory could not keep: one payment is
    /// applied exactly once, however many times it is delivered.
    func testAPaymentKeyCanOnlyBeClaimedOnce() async throws {
        let ledger = InMemoryLedger()
        let delivery = Self.receipt()
        let first = try await ledger.inTransaction { try await $0.claimPayment(delivery) }
        let second = try await ledger.inTransaction { try await $0.claimPayment(delivery) }
        XCTAssertTrue(first)
        XCTAssertFalse(second, "a redelivered payment must not be applied twice")
    }

    /// Two deliveries racing each other still produce one activation. This is
    /// the test the old check-then-mark code could not pass.
    func testConcurrentDeliveriesProduceOneActivation() async throws {
        let ledger = InMemoryLedger()
        let attempts = 16

        let delivery = Self.receipt()
        let defaults = TenantDefaults(ownerKey: UserKey.identified(1), model: "m", role: "r", historyLength: 10)
        let winners = await withTaskGroup(of: Bool.self) { group -> Int in
            for _ in 0..<attempts {
                group.addTask {
                    (try? await ledger.inTransaction { transaction in
                        guard try await transaction.claimPayment(delivery) else { return false }
                        _ = try await transaction.extendSubscription(UserKey.identified(1), days: 30, defaults: defaults)
                        return true
                    }) ?? false
                }
            }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }

        XCTAssertEqual(winners, 1, "exactly one of \(attempts) concurrent deliveries may apply the payment")
    }

    /// The guard behind every payout that is not a payment. A referral bonus
    /// used to be gated by a timestamp in write-behind state: crash between the
    /// credit and the flush and the same bonus is paid again.
    func testAClaimCanOnlyBeTakenOnce() async throws {
        let ledger = InMemoryLedger()
        let first = try await ledger.inTransaction { try await $0.claim("refbonus:200") }
        let second = try await ledger.inTransaction { try await $0.claim("refbonus:200") }
        let other = try await ledger.inTransaction { try await $0.claim("refbonus:201") }
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertTrue(other, "a different pair is a different claim")
    }

    /// A payment claim and a payout claim live in the same namespace and must
    /// not be able to collide.
    func testPaymentAndPayoutClaimsDoNotCollide() async throws {
        let ledger = InMemoryLedger()
        let payment = Self.receipt(idempotencyKey: "refbonus:200")
        let paymentClaimed = try await ledger.inTransaction { try await $0.claimPayment(payment) }
        let payoutClaimed = try await ledger.inTransaction { try await $0.claim("refbonus:200") }
        XCTAssertTrue(paymentClaimed)
        XCTAssertTrue(
            payoutClaimed,
            "a payout key must not be consumed by a payment that happens to be spelled the same"
        )
    }

    /// Paying never shortens access, and an unlimited tenant stays unlimited.
    func testExtensionNeverShortensAccess() async throws {
        let ledger = InMemoryLedger()
        let defaults = TenantDefaults(ownerKey: UserKey.identified(7), model: "m", role: "r", historyLength: 10)

        let first = try await ledger.inTransaction {
            try await $0.extendSubscription(UserKey.identified(7), days: 30, defaults: defaults)
        }
        XCTAssertTrue(first.isNew)
        let second = try await ledger.inTransaction {
            try await $0.extendSubscription(UserKey.identified(7), days: 30, defaults: defaults)
        }
        XCTAssertFalse(second.isNew)
        XCTAssertGreaterThan(second.paidUntil!, first.paidUntil!, "a renewal extends from the current end")

        try await ledger.inTransaction { try await $0.setSubscription(UserKey.identified(7), paidUntil: nil) }
        let third = try await ledger.inTransaction {
            try await $0.extendSubscription(UserKey.identified(7), days: 30, defaults: defaults)
        }
        XCTAssertNil(third.paidUntil, "an unlimited tenant stays unlimited")
        XCTAssertTrue(third.wasUnlimited)
    }

    /// A wallet cannot go below zero, and what it could not pay is reported
    /// rather than swallowed.
    func testDebitStopsAtZeroAndReportsTheShortfall() async throws {
        let ledger = InMemoryLedger()
        _ = try await ledger.inTransaction {
            try await $0.credit(UserKey.identified(2), .cents(10), kind: .topup, purchased: true, ref: nil)
        }

        let debit = try await ledger.inTransaction {
            try await $0.debit(UserKey.identified(2), upTo: .cents(25), real: .cents(20), ref: "gen-1")
        }
        XCTAssertEqual(debit.charged, .cents(10))
        XCTAssertEqual(debit.remaining, .zero)
        XCTAssertTrue(debit.depleted, "the charge that empties a wallet is the pitch moment")
    }

    /// The invariant that makes a balance explainable: the journal adds up to
    /// it, after any sequence of movements.
    func testJournalAlwaysAddsUpToTheBalance() async throws {
        let ledger = InMemoryLedger()
        for step in 0..<200 {
            let key = UserKey.identified(UserID(Int.random(in: 1...5)))
            let amount = Int.random(in: 1...500)
            switch step % 3 {
            case 0:
                _ = try await ledger.inTransaction {
                    try await $0.credit(key, .cents(amount), kind: .topup, purchased: true, ref: "s\(step)")
                }
            case 1:
                _ = try await ledger.inTransaction {
                    try await $0.debit(key, upTo: .cents(amount), real: .cents(1), ref: "s\(step)")
                }
            default:
                _ = try await ledger.inTransaction {
                    try await $0.credit(key, .cents(-amount), kind: .correction, purchased: false, ref: "s\(step)")
                }
            }
        }

        let mismatched = try await ledger.reconcile()
        XCTAssertTrue(mismatched.isEmpty, "unbalanced wallets: \(mismatched)")
    }

    /// Only a real purchase makes a proven payer; bonuses and grants must not.
    func testOnlyPurchasedCreditMarksAPayer() async throws {
        let ledger = InMemoryLedger()
        let bonus = try await ledger.inTransaction {
            try await $0.credit(UserKey.identified(3), .cents(100), kind: .referral, purchased: false, ref: nil)
        }
        XCTAssertEqual(bonus.toppedUp, .zero)

        let purchase = try await ledger.inTransaction {
            try await $0.credit(UserKey.identified(3), .cents(500), kind: .topup, purchased: true, ref: nil)
        }
        XCTAssertEqual(purchase.toppedUp, .cents(500))
        XCTAssertEqual(purchase.balance, .cents(600))
    }

    /// Setting a balance is still a movement, and the journal has to be able to
    /// explain it — otherwise `/balance set` is money appearing from nowhere and
    /// `reconcile()` calls the wallet corrupt.
    func testSettingABalanceRecordsTheDelta() async throws {
        let ledger = InMemoryLedger()
        let key = UserKey.identified(70)
        _ = try await ledger.inTransaction {
            try await $0.credit(key, .cents(200), kind: .topup, purchased: true, ref: nil)
        }
        let set = try await ledger.inTransaction { try await $0.setBalance(key, to: .cents(50), ref: "set") }
        XCTAssertEqual(set.balance, .cents(50))
        XCTAssertEqual(set.toppedUp, .cents(200), "a correction is not a refund of the top-up")

        let negative = try await ledger.inTransaction { try await $0.setBalance(key, to: .usd(-1), ref: "set") }
        XCTAssertEqual(negative.balance, .zero, "a wallet has a floor wherever it is written")

        let mismatched = try await ledger.reconcile()
        XCTAssertTrue(mismatched.isEmpty, "unbalanced wallets: \(mismatched)")
    }

    /// A super-admin grant is money, so it is written by a transaction and only
    /// then mirrored — it must never travel write-behind.
    ///
    /// The bug this pins down: the grant used to change the store's cache and
    /// wait up to two seconds for a flush. Any answer charged in that window
    /// opened its own transaction, read a row that did not have the grant yet,
    /// and mirrored that pre-grant balance back over the cache. The grant was
    /// gone, the answer was free, and nothing anywhere recorded either.
    func testASuperAdminGrantIsWrittenThroughTheLedger() async throws {
        let store = Fixtures.makeStore()
        let ledger = InMemoryLedger()
        let writer = WalletWriter(state: store, ledger: ledger, logger: SilentLogger())
        let key = Fixtures.key(71)

        let granted = await writer.grant(key: key, amount: .usd(5), ref: "balance add")
        XCTAssertEqual(granted?.balance, .usd(5))

        // Durable before it was reported: a charge landing immediately after
        // starts from the granted balance, not from what the cache alone knew.
        let debit = try await ledger.inTransaction {
            try await $0.debit(key, upTo: .cents(50), real: .cents(40), ref: "gen")
        }
        XCTAssertEqual(debit.charged, .cents(50), "the charge must see money the grant already committed")

        // And it must not be queued for the write-behind wallet sync as well —
        // that would write the pre-charge balance back over the row and log a
        // second journal line for a movement that never happened.
        let drained = await store.drainDirtyWallets()
        XCTAssertTrue(drained.changed.isEmpty, "a committed grant must not also be flushed as a cache change")
        let cached = await store.balance(key)?.balance
        XCTAssertEqual(cached, .usd(5), "the cache mirrors what committed")
    }

    /// A wallet somebody deleted and then funded again still reconciles.
    ///
    /// The journal outlives the wallet on purpose — it is the evidence behind
    /// every movement — but `reconcile()` sums it from the beginning. Rows left
    /// under a deleted key made the next wallet under that key permanently
    /// unbalanced: an alert about corrupted money that no one could ever clear.
    func testAWalletDeletedAndFundedAgainStillReconciles() async throws {
        let ledger = InMemoryLedger()
        let key = UserKey.identified(72)
        _ = try await ledger.inTransaction {
            try await $0.credit(key, .cents(300), kind: .topup, purchased: true, ref: nil)
        }

        try await ledger.syncWallets(changed: [:], removed: [key])
        _ = try await ledger.inTransaction {
            try await $0.credit(key, .cents(100), kind: .topup, purchased: true, ref: nil)
        }

        let mismatched = try await ledger.reconcile()
        XCTAssertTrue(mismatched.isEmpty, "a recreated wallet must not inherit the old journal: \(mismatched)")
    }

    /// The wallet changes that really do happen outside a transaction — a
    /// rename folding two wallets into one — are journalled too, or the
    /// "journal always adds up" rule stops covering the only path that can
    /// move a balance without a transaction.
    func testSyncingAWalletOutsideATransactionIsJournalled() async throws {
        let ledger = InMemoryLedger()
        let key = UserKey.identified(73)
        _ = try await ledger.inTransaction {
            try await $0.credit(key, .cents(100), kind: .topup, purchased: true, ref: nil)
        }
        try await ledger.syncWallets(
            changed: [key: UserBalance(balance: .cents(400), toppedUp: .cents(400))],
            removed: []
        )
        let mismatched = try await ledger.reconcile()
        XCTAssertTrue(mismatched.isEmpty, "a synced wallet must carry its own journal line: \(mismatched)")
    }
}

/// Every `bot_config` key must survive the round trip store → batch → restore.
/// This is the one class of error nothing else catches: a key that is written
/// but never read comes back as its default on every restart, silently, and no
/// existing test looks at it.
final class ConfigRoundTripTests: XCTestCase {

    func testEveryConfigKeyIsExportedAndRestored() async throws {
        let store = Fixtures.makeStore()
        // Touch every key, then drain: `markAllDirty` is what the export is
        // for, and `allCases` makes this test self-updating — a new key joins
        // the check by existing.
        await store.markAllDirty()
        let batch = await store.drainDirtyBatch()

        let exported = Set(batch.configs.map(\.name))
        let missing = Set(ConfigName.allCases).subtracting(exported)
        XCTAssertTrue(missing.isEmpty, "config rows never exported: \(missing.map(\.rawValue).sorted())")

        // And each one has to survive being encoded the way the row encodes it.
        let encoder = JSONEncoder()
        for value in batch.configs {
            XCTAssertNoThrow(try encoder.encode(value), "config \(value.name.rawValue) cannot be written")
        }
    }

    /// The other half of the round trip, and the one that used to be missing:
    /// a row that is written but never *read back* silently reverts to its
    /// default on every restart, and nothing else in the suite can see it.
    /// The registry makes the load path a loop over declarations, so this test
    /// self-updates too.
    func testEveryDeclaredKeyIsLoadedBack() async throws {
        let store = Fixtures.makeStore()
        await store.markAllDirty()
        let batch = await store.drainDirtyBatch()

        let declared = Set(Config.all.map(\.name))
        XCTAssertEqual(declared, Set(ConfigName.allCases), "a declared row and an exported row must be the same set")

        let encoder = JSONEncoder()
        var rows: [ConfigName: Data] = [:]
        for value in batch.configs { rows[value.name] = try encoder.encode(value) }

        var failures: [String] = []
        let documents = ConfigDocuments(rows: rows, keys: Config.all) { name, error in
            failures.append("\(name.rawValue): \(error)")
        }
        XCTAssertTrue(failures.isEmpty, "config rows that do not decode: \(failures)")

        // A value the store actually changed has to come back changed, not as
        // the default — the exact failure mode a missing load line produces.
        await store.setMarkupPercent(42)
        let markupBatch = await store.drainDirtyBatch()
        let markupRow = try XCTUnwrap(markupBatch.configs.first { $0.name == .markup })
        let reloaded = ConfigDocuments(
            rows: [.markup: try encoder.encode(markupRow)],
            keys: Config.all,
            onError: { name, error in XCTFail("\(name.rawValue): \(error)") }
        )
        XCTAssertEqual(reloaded[Config.markup], 42)
        XCTAssertEqual(documents[Config.starsPerUsd], 77, "an untouched row reads as its default")
    }
}
