import Foundation

/// Write-behind persistence: drains the store's dirty entities every couple of
/// seconds and upserts them as rows. A failed flush is retried merged into the
/// next one, so a transient database hiccup never loses data — the batch just
/// waits in memory.
///
/// Money does not travel this way. Wallet balances, subscription end dates and
/// payment claims are written through `LedgerPort` inside a transaction and are
/// durable before the payer is told anything (§3.2); what this coordinator
/// carries is everything whose loss for two seconds is survivable. The one
/// exception is a wallet that changed *without* money moving — a rename folding
/// a pending wallet into an identified one — which is synced here because no
/// transaction was involved.
actor PersistenceCoordinator {
    private let store: ChatContextStore
    private let persistence: StatePersistencePort
    private let ledger: LedgerPort
    private let logger: LoggerPort
    private let metrics: RuntimeMetrics
    private let flushInterval: Duration

    private var loopTask: Task<Void, Never>?
    private var retryCarry: PersistenceBatch?
    private var flushing = false
    private var abandoned = false

    private var lastErrorMessage: String?
    private var lastSuccessAt: Date?
    private var totalEntitiesFlushed = 0
    private var totalFlushes = 0
    private var totalFailures = 0

    init(
        store: ChatContextStore,
        persistence: StatePersistencePort,
        ledger: LedgerPort,
        logger: LoggerPort,
        metrics: RuntimeMetrics,
        flushInterval: Duration = .seconds(2)
    ) {
        self.store = store
        self.persistence = persistence
        self.ledger = ledger
        self.logger = logger
        self.metrics = metrics
        self.flushInterval = flushInterval
    }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: self.flushInterval)
                await self.flushOnce()
            }
        }
    }

    func flushNow() async {
        await flushOnce()
    }

    /// Cancels the loop and flushes whatever is still dirty. One retry after a
    /// short pause — this runs during the SIGTERM grace window.
    func stop() async {
        loopTask?.cancel()
        loopTask = nil
        await flushOnce()
        if retryCarry != nil {
            try? await Task.sleep(for: .seconds(1))
            await flushOnce()
        }
        if let carry = retryCarry {
            logger.error("shutdown flush still failing; \(carry.entityCount) entities not persisted")
        }
    }

    /// Stops without flushing. Used when the writer lock is gone: the rows in
    /// hand describe a world another instance now owns, and writing them would
    /// overwrite its work with ours.
    func abandon() {
        loopTask?.cancel()
        loopTask = nil
        retryCarry = nil
        abandoned = true
    }

    private func flushOnce() async {
        guard !abandoned else { return }
        // Serialize concurrent flushes (actor reentrancy across the await):
        // two overlapping applies could write an older row after a newer one.
        while flushing {
            try? await Task.sleep(for: .milliseconds(100))
        }
        flushing = true
        defer { flushing = false }

        var batch = await store.drainDirtyBatch()
        if let carry = retryCarry {
            batch = PersistenceBatch.merged(older: carry, newer: batch)
            retryCarry = nil
        }
        let wallets = await store.drainDirtyWallets()
        guard !batch.isEmpty || !wallets.changed.isEmpty || !wallets.removed.isEmpty else { return }

        do {
            try await persistence.apply(batch)
            try await ledger.syncWallets(changed: wallets.changed, removed: wallets.removed)
            lastSuccessAt = Date()
            lastErrorMessage = nil
            totalEntitiesFlushed += batch.entityCount
            totalFlushes += 1
            await metrics.increment(MetricName.persistenceFlushes)
        } catch {
            retryCarry = batch
            totalFailures += 1
            lastErrorMessage = UserFacingError.message(error)
            logger.error("persistence flush failed (\(batch.entityCount) entities, will retry): \(error)")
            await metrics.increment(MetricName.persistenceErrors)
        }
    }

    // MARK: - Status for /metrics and backup-notify chats

    struct Status: Sendable {
        let lastSuccessAt: Date?
        let lastErrorMessage: String?
        let pendingRetryEntities: Int
        let totalEntitiesFlushed: Int
        let totalFlushes: Int
        let totalFailures: Int
    }

    func status() -> Status {
        Status(
            lastSuccessAt: lastSuccessAt,
            lastErrorMessage: lastErrorMessage,
            pendingRetryEntities: retryCarry?.entityCount ?? 0,
            totalEntitiesFlushed: totalEntitiesFlushed,
            totalFlushes: totalFlushes,
            totalFailures: totalFailures
        )
    }

    func statusLine() -> String {
        if let error = lastErrorMessage {
            return "✗ " + error
        }
        guard let lastSuccessAt else {
            return "— ещё не было записей"
        }
        let seconds = Int(Date().timeIntervalSince(lastSuccessAt))
        return "✓ синхронизировано · \(totalEntitiesFlushed) объектов всего · последняя запись \(seconds)с назад"
    }
}
