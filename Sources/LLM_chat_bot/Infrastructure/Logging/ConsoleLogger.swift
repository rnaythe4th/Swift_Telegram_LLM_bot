import Foundation

/// Single-line structured logs: ISO-8601 timestamp + level + message.
/// stdout is flushed per line so Railway's log collector sees entries
/// immediately (stdout is block-buffered on Linux when not a TTY).
struct ConsoleLogger: LoggerPort {
    enum Level: Int, Comparable, Sendable {
        case info = 0
        case warning = 1
        case error = 2

        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }

        init?(name: String) {
            switch name.lowercased() {
            case "info", "debug": self = .info
            case "warn", "warning": self = .warning
            case "error": self = .error
            default: return nil
            }
        }
    }

    let minLevel: Level

    init(minLevel: Level = .info) {
        self.minLevel = minLevel
    }

    static func fromEnvironment() -> ConsoleLogger {
        let raw = ProcessInfo.processInfo.environment["LOG_LEVEL"] ?? ""
        return ConsoleLogger(minLevel: Level(name: raw) ?? .info)
    }

    func info(_ message: String) { log(.info, "INFO", message) }
    func warning(_ message: String) { log(.warning, "WARN", message) }
    func error(_ message: String) { log(.error, "ERROR", message) }

    private func log(_ level: Level, _ tag: String, _ message: String) {
        guard level >= minLevel else { return }
        // Errors quote the request that failed, and every Telegram request URL
        // carries the bot token. Redacting here covers every call site at once.
        print("\(Self.timestamp()) [\(tag)] \(SecretRedactor.shared.redact(message))")
        fflush(stdout)
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
