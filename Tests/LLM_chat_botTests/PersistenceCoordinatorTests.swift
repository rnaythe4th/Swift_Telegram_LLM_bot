import XCTest
@testable import LLM_chat_bot

/// The write-behind loop, and the one rule that makes it safe to drain the
/// store into memory: whatever a failed flush was holding is still there for
/// the next one.
final class PersistenceCoordinatorTests: XCTestCase {

    /// A drain empties the store's dirty sets, so a batch that fails to land is
    /// the *only* copy left. Both halves have to be kept — the rows and the
    /// wallets — because a wallet dropped here is money the store believes it
    /// already wrote: the rename that folded a pending wallet into an
    /// identified one leaves both rows in the database, and the next boot
    /// merges them a second time.
    func testAFailedFlushKeepsBothHalvesForTheNextOne() async {
        let store = Fixtures.makeStore()
        let persistence = FlakyPersistence(failures: 1)
        let ledger = RecordingLedger()
        let coordinator = makeCoordinator(store: store, persistence: persistence, ledger: ledger)

        await store.identifyUser(userID: 991, username: "payer", firstName: nil)
        _ = await store.creditPurchasedBalance(key: Fixtures.key(991), amount: .usd(2))
        await store.setMarkupPercent(37)

        await coordinator.flushNow()
        let synced = await ledger.changed
        XCTAssertTrue(synced.isEmpty, "the failing flush must not have written anything")

        // The store handed everything over already: if the carry lost it, it is
        // lost for good.
        let leftovers = await store.drainDirtyBatch()
        let leftoverWallets = await store.drainDirtyWallets()
        XCTAssertTrue(leftovers.isEmpty)
        XCTAssertTrue(leftoverWallets.changed.isEmpty)

        await coordinator.flushNow()

        let wallets = await ledger.changed
        XCTAssertEqual(wallets[Fixtures.key(991)]?.toppedUp, .usd(2), "a wallet drained by a failed flush must be retried, not dropped")
        let applied = await persistence.applied
        XCTAssertEqual(applied.count, 1)
        XCTAssertTrue(applied[0].configs.contains { $0.name == .markup }, "and so must the rows it travelled with")
    }

    /// A wallet removal that arrives after a failed change of the same wallet
    /// wins, exactly like a deleted row beats an older upsert.
    func testTheRetryHonoursALaterWalletRemoval() async {
        let store = Fixtures.makeStore()
        let persistence = FlakyPersistence(failures: 1)
        let ledger = RecordingLedger()
        let coordinator = makeCoordinator(store: store, persistence: persistence, ledger: ledger)

        _ = await store.creditBalance(key: Fixtures.key(992), amount: .usd(1))
        await coordinator.flushNow()          // fails, wallet sits in the carry

        _ = await store.removeBalance(Fixtures.key(992))
        await coordinator.flushNow()          // succeeds, merged with the carry

        let wallets = await ledger.changed
        let removed = await ledger.removed
        XCTAssertTrue(wallets.isEmpty, "the removal must cancel the older write")
        XCTAssertEqual(removed, [Fixtures.key(992)])
    }

    /// Losing the writer lock means another instance owns these rows now.
    /// `abandon()` accepts losing the last couple of seconds; what it must not
    /// do is let a queued flush write them anyway.
    func testAbandonWritesNothingAfterwards() async {
        let store = Fixtures.makeStore()
        let persistence = FlakyPersistence(failures: 1)
        let ledger = RecordingLedger()
        let coordinator = makeCoordinator(store: store, persistence: persistence, ledger: ledger)

        await store.setMarkupPercent(11)
        await coordinator.flushNow()          // fails: the batch is in the carry
        await coordinator.abandon()

        await store.setMarkupPercent(22)
        await coordinator.flushNow()

        let applied = await persistence.applied
        XCTAssertTrue(applied.isEmpty, "an abandoned coordinator must never write again")
    }

    private func makeCoordinator(
        store: ChatContextStore,
        persistence: StatePersistencePort,
        ledger: LedgerPort
    ) -> PersistenceCoordinator {
        PersistenceCoordinator(
            store: store,
            persistence: persistence,
            ledger: ledger,
            logger: SilentLogger(),
            metrics: RuntimeMetrics(),
            // No loop: these tests drive the flushes themselves.
            flushInterval: .seconds(3600)
        )
    }
}

/// Storage that refuses the first `failures` batches — the database being
/// briefly unreachable, which is the whole reason the retry carry exists.
private actor FlakyPersistence: StatePersistencePort {
    struct Refused: Error {}

    private var failuresLeft: Int
    private(set) var applied: [PersistenceBatch] = []

    init(failures: Int) { self.failuresLeft = failures }

    func apply(_ batch: PersistenceBatch) async throws {
        if failuresLeft > 0 {
            failuresLeft -= 1
            throw Refused()
        }
        applied.append(batch)
    }

    func loadEverything() async throws -> PersistedBotState { PersistedBotState() }

    func pruneChatContexts(idleDays: Int, protecting: Set<ChatID>) async throws -> [ChatKey] { [] }
}

/// Records what the write-behind loop asked the ledger to sync.
private actor RecordingLedger: LedgerPort {
    struct Unsupported: Error {}

    private(set) var changed: [UserKey: UserBalance] = [:]
    private(set) var removed: [UserKey] = []

    func inTransaction<T: Sendable>(
        _ body: @Sendable (any LedgerTransaction) async throws -> T
    ) async throws -> T {
        throw Unsupported()
    }

    func syncWallets(changed: [UserKey: UserBalance], removed: [UserKey]) async throws {
        for (key, wallet) in changed { self.changed[key] = wallet }
        for key in removed {
            self.changed.removeValue(forKey: key)
            self.removed.append(key)
        }
    }

    func recentEntries(userKey: UserKey, limit: Int) async throws -> [LedgerEntry] { [] }

    func reconcile() async throws -> [UserKey] { [] }
}
