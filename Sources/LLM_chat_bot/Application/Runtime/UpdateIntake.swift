import Foundation

/// Fixed-capacity ring of recently seen update IDs. Telegram redelivers
/// updates whenever a webhook response is lost or a poll offset lags, so every
/// update passes through here exactly once before dispatch.
struct UpdateDeduplicator {
    private var ring: [Int?]
    private var members: Set<Int> = []
    private var index = 0

    init(capacity: Int = 2048) {
        self.ring = Array(repeating: nil, count: max(16, capacity))
    }

    func contains(_ id: Int) -> Bool { members.contains(id) }

    /// Returns true when the ID is new (and records it), false for a duplicate.
    mutating func insert(_ id: Int) -> Bool {
        guard !members.contains(id) else { return false }
        if let evicted = ring[index] {
            members.remove(evicted)
        }
        ring[index] = id
        members.insert(id)
        index = (index + 1) % ring.count
        return true
    }
}

/// Single entry point for updates from both sources (webhook and polling):
/// deduplicates, merges photo albums, and hands releasable updates to the
/// dispatcher. Owns the album flush timer, so albums are released after the
/// holdback interval even when no further traffic arrives — with webhooks
/// nobody else would ever tick the buffer.
actor UpdateIntake {
    private var deduplicator = UpdateDeduplicator()
    private var albumBuffer = TelegramPhotoAlbumBuffer()
    private var albumFlushTask: Task<Void, Never>?
    private var routingUpdates: [Int: Task<Bool?, Never>] = [:]
    private let deliver: @Sendable (TelegramUpdate) async -> Void
    private let metrics: RuntimeMetrics
    private let durableDelivery: (@Sendable (TelegramUpdate) async -> Bool?)?

    init(
        metrics: RuntimeMetrics,
        durableDelivery: (@Sendable (TelegramUpdate) async -> Bool?)? = nil,
        deliver: @escaping @Sendable (TelegramUpdate) async -> Void
    ) {
        self.metrics = metrics
        self.deliver = deliver
        self.durableDelivery = durableDelivery
    }

    /// Returns the number of consecutively acknowledged updates.
    @discardableResult
    func enqueue(_ updates: [TelegramUpdate]) async -> Int {
        guard !updates.isEmpty else { return 0 }
        await metrics.increment(MetricName.updatesReceived, by: updates.count)

        var accepted = 0
        var duplicates = 0
        for update in updates {
            if deduplicator.contains(update.update_id) {
                duplicates += 1
                accepted += 1
                continue
            }
            let handled = await confirmRouting(update)
            guard handled != false else { break }
            if deduplicator.insert(update.update_id) {
                if handled == nil {
                    for releasable in albumBuffer.ingest([update]) {
                        await deliver(releasable)
                    }
                }
            } else {
                duplicates += 1
            }
            accepted += 1
        }
        if duplicates > 0 {
            await metrics.increment(MetricName.updatesDeduplicated, by: duplicates)
        }

        scheduleAlbumFlushIfNeeded()
        return accepted
    }

    private func confirmRouting(_ update: TelegramUpdate) async -> Bool? {
        guard let durableDelivery else { return nil }
        let id = update.update_id
        if let pending = routingUpdates[id] { return await pending.value }
        let pending = Task { await durableDelivery(update) }
        routingUpdates[id] = pending
        let result = await pending.value
        routingUpdates.removeValue(forKey: id)
        return result
    }

    private func scheduleAlbumFlushIfNeeded() {
        guard albumBuffer.hasBufferedUpdates, albumFlushTask == nil else { return }
        albumFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            await self?.flushAlbums()
        }
    }

    private func flushAlbums() async {
        albumFlushTask = nil
        for update in albumBuffer.ingest([]) {
            await deliver(update)
        }
        scheduleAlbumFlushIfNeeded()
    }

    /// Stops the flush timer and hands on whatever is still buffered. Telegram
    /// considers an update delivered the moment the webhook answered 200, so a
    /// half-collected album left in the buffer at shutdown is a message lost
    /// for good.
    func shutdown() async {
        albumFlushTask?.cancel()
        albumFlushTask = nil
        for update in albumBuffer.flushAll() {
            await deliver(update)
        }
    }
}
