import Foundation

/// One line per event on stdout: ISO-8601 timestamp, level, correlation
/// context, message. stdout is flushed per line so Railway's collector sees
/// entries immediately (it is block-buffered on Linux when not a TTY).
///
/// `LOG_FORMAT=json` switches to one JSON object per line instead. Railway and
/// every hosted log search index those fields, which is the difference between
/// reading the last hour by eye and asking for `chat=-100123` — the whole
/// reason the context exists.
struct ConsoleLogger: LoggerPort {
    enum Format: Sendable {
        case text
        case json

        init(name: String) {
            self = name.lowercased() == "json" ? .json : .text
        }
    }

    let minLevel: LogLevel
    let format: Format

    init(minLevel: LogLevel = .info, format: Format = .text) {
        self.minLevel = minLevel
        self.format = format
    }

    static func fromEnvironment() -> ConsoleLogger {
        let environment = ProcessInfo.processInfo.environment
        return ConsoleLogger(
            minLevel: LogLevel(name: environment["LOG_LEVEL"] ?? "") ?? .info,
            format: Format(name: environment["LOG_FORMAT"] ?? "")
        )
    }

    func log(_ level: LogLevel, _ message: @autoclosure () -> String, context: LogContext) {
        guard level >= minLevel else { return }
        // Errors quote the request that failed, and every Telegram request URL
        // carries the bot token. Redacting here covers every call site at once.
        let text = SecretRedactor.shared.redact(message())
        switch format {
        case .text:
            print("\(Self.timestamp()) [\(level.tag)]\(Self.suffix(context)) \(text)")
        case .json:
            print(Self.jsonLine(level: level, message: text, context: context))
        }
        fflush(stdout)
    }

    /// `[chat=-100 user=42 gen=…]`, omitted entirely when there is nothing to
    /// correlate — most lines are about the process, not about one person.
    private static func suffix(_ context: LogContext) -> String {
        guard !context.isEmpty else { return "" }
        var parts: [String] = []
        if let chat = context.chat { parts.append("chat=\(chat)") }
        if let thread = context.thread { parts.append("thread=\(thread)") }
        if let user = context.user { parts.append("user=\(user)") }
        if let generation = context.generation { parts.append("gen=\(generation.raw.uuidString)") }
        return " [\(parts.joined(separator: " "))]"
    }

    private static func jsonLine(level: LogLevel, message: String, context: LogContext) -> String {
        var fields: [(String, String)] = [
            ("ts", quoted(timestamp())),
            ("level", quoted(level.tag.lowercased())),
            ("msg", quoted(message)),
        ]
        if let chat = context.chat { fields.append(("chat", String(chat))) }
        if let thread = context.thread { fields.append(("thread", String(thread))) }
        if let user = context.user { fields.append(("user", String(user))) }
        if let generation = context.generation {
            fields.append(("generation", quoted(generation.raw.uuidString)))
        }
        return "{" + fields.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}"
    }

    /// Hand-rolled rather than `JSONEncoder`: a logger that can throw, or that
    /// allocates an encoder per line, stops logging exactly under the load
    /// where the lines matter most.
    private static func quoted(_ raw: String) -> String {
        var out = "\""
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
