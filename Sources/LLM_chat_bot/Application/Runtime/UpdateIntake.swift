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
    private let deliver: @Sendable (TelegramUpdate) async -> Void
    private let metrics: RuntimeMetrics

    init(metrics: RuntimeMetrics, deliver: @escaping @Sendable (TelegramUpdate) async -> Void) {
        self.metrics = metrics
        self.deliver = deliver
    }

    func enqueue(_ updates: [TelegramUpdate]) async {
        guard !updates.isEmpty else { return }
        await metrics.increment(MetricName.updatesReceived, by: updates.count)

        var fresh: [TelegramUpdate] = []
        for update in updates {
            if deduplicator.insert(update.update_id) {
                fresh.append(update)
            }
        }
        if fresh.count < updates.count {
            await metrics.increment(MetricName.updatesDeduplicated, by: updates.count - fresh.count)
        }

        for update in albumBuffer.ingest(fresh) {
            await deliver(update)
        }
        scheduleAlbumFlushIfNeeded()
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

    func shutdown() {
        albumFlushTask?.cancel()
        albumFlushTask = nil
    }
}
