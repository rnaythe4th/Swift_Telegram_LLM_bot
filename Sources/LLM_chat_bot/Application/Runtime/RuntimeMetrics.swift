import Foundation

/// Lightweight in-process counters exposed via GET /metrics. Enough to see at
/// a glance whether the bot keeps up with load; upgrade path is a real
/// Prometheus exporter, which these counters map onto directly.
actor RuntimeMetrics {
    private let startedAt = Date()
    private var counters: [String: Int] = [:]
    private var gauges: [String: Int] = [:]

    func increment(_ name: String, by amount: Int = 1) {
        counters[name, default: 0] += amount
    }

    func setGauge(_ name: String, value: Int) {
        gauges[name] = value
    }

    struct Snapshot: Codable, Sendable {
        let uptimeSeconds: Int
        let counters: [String: Int]
        let gauges: [String: Int]
    }

    func snapshot() -> Snapshot {
        Snapshot(
            uptimeSeconds: Int(Date().timeIntervalSince(startedAt)),
            counters: counters,
            gauges: gauges
        )
    }
}

enum MetricName {
    static let updatesReceived = "updates_received"
    static let updatesDeduplicated = "updates_deduplicated"
    static let updatesDropped = "updates_dropped_queue_full"
    static let generationsStarted = "generations_started"
    static let telegramRateLimited = "telegram_429"
    static let telegramSendErrors = "telegram_send_errors"
    static let persistenceFlushes = "persistence_flushes"
    static let persistenceErrors = "persistence_errors"
    static let paymentsProcessed = "payments_processed"
    static let paymentsDeduplicated = "payments_deduplicated"
    static let reminderSweeps = "reminder_sweeps"
    static let remindersSent = "reminders_sent"
    static let winbacksSent = "winbacks_sent"
    static let reminderSendErrors = "reminder_send_errors"

    static let activeGenerations = "active_generations"
    static let dirtyEntities = "dirty_entities"
}
