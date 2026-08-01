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
    private var retryCarry: PendingFlush?
    /// The flush currently running (or the last one that ran). A new flush is
    /// chained behind it instead of polling a flag: two overlapping applies
    /// could write an older row after a newer one, and a spin-wait that a
    /// cancelled task falls straight through burns a core during shutdown.
    private var flushChain: Task<Void, Never>?
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

    /// Queues one flush behind whatever is already running and waits for it.
    ///
    /// The chain is what serializes flushes (an actor does not: every `await`
    /// inside one lets the next in). It is an unstructured `Task` on purpose —
    /// a flush that started must finish even if the caller that asked for it
    /// was cancelled, which is exactly the shutdown case.
    private func flushOnce() async {
        let previous = flushChain
        let task = Task { [weak self] in
            await previous?.value
            await self?.performFlush()
        }
        flushChain = task
        await task.value
    }

    private func performFlush() async {
        guard !abandoned else { return }

        var pending = PendingFlush(
            batch: await store.drainDirtyBatch(),
            wallets: await store.drainDirtyWallets()
        )
        if let carry = retryCarry {
            pending = PendingFlush.merged(older: carry, newer: pending)
            retryCarry = nil
        }
        guard !pending.isEmpty else { return }
        // The lock may have gone while we were draining. These rows describe a
        // world another instance now owns, and `abandon()` already accepted
        // losing them — writing them anyway is the one thing it exists to stop.
        guard !abandoned else { return }

        do {
            try await persistence.apply(pending.batch)
            try await ledger.syncWallets(changed: pending.changedWallets, removed: Array(pending.removedWallets))
            lastSuccessAt = Date()
            lastErrorMessage = nil
            totalEntitiesFlushed += pending.entityCount
            totalFlushes += 1
            await metrics.increment(MetricName.persistenceFlushes)
        } catch {
            retryCarry = pending
            totalFailures += 1
            lastErrorMessage = UserFacingError.message(error)
            logger.error("persistence flush failed (\(pending.entityCount) entities, will retry): \(error)")
            await metrics.increment(MetricName.persistenceErrors)
        }
    }

    /// One drain, both halves of it.
    ///
    /// The rows and the wallets are drained together, so they have to be
    /// retried together: a failed flush that kept the batch and dropped the
    /// wallets loses a change the store no longer knows about. The wallet
    /// half is small but it is money — a rename folding a pending wallet into
    /// an identified one is written here and nowhere else, and losing it
    /// leaves both rows in the database for the next boot to merge a second
    /// time.
    struct PendingFlush: Sendable {
        var batch: PersistenceBatch
        var changedWallets: [UserKey: UserBalance]
        var removedWallets: Set<UserKey>

        init(batch: PersistenceBatch = PersistenceBatch(), wallets: (changed: [UserKey: UserBalance], removed: [UserKey])) {
            self.batch = batch
            self.changedWallets = wallets.changed
            self.removedWallets = Set(wallets.removed)
        }

        var isEmpty: Bool { batch.isEmpty && changedWallets.isEmpty && removedWallets.isEmpty }

        var entityCount: Int { batch.entityCount + changedWallets.count + removedWallets.count }

        /// Newer wins, and a delete cancels an older write of the same wallet
        /// (and the other way round) — the same rule `PersistenceBatch.merged`
        /// applies to rows.
        static func merged(older: PendingFlush, newer: PendingFlush) -> PendingFlush {
            var result = older
            result.batch = PersistenceBatch.merged(older: older.batch, newer: newer.batch)
            for key in newer.removedWallets {
                result.removedWallets.insert(key)
                result.changedWallets.removeValue(forKey: key)
            }
            for (key, wallet) in newer.changedWallets {
                result.changedWallets[key] = wallet
                result.removedWallets.remove(key)
            }
            return result
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
