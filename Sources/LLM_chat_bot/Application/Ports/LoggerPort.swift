/// What a log line is about.
///
/// Triage of "why did user X get no answer" used to mean grepping by
/// timestamp: the line said what happened but never who it happened to. Every
/// field is optional because most lines are about the process, not about one
/// person.
struct LogContext: Sendable, Equatable {
    var chat: ChatID?
    var thread: Int64?
    var user: UserID?
    var generation: GenerationID?

    static let none = LogContext()

    var isEmpty: Bool {
        chat == nil && thread == nil && user == nil && generation == nil
    }

    init(chat: ChatID? = nil, thread: Int64? = nil, user: UserID? = nil, generation: GenerationID? = nil) {
        self.chat = chat
        self.thread = thread
        self.user = user
        self.generation = generation
    }

    /// The chat a turn is happening in. `threadID == 0` is the main thread of a
    /// forum, which is not worth a field of its own in the output.
    init(chat key: ChatKey, user: UserID? = nil, generation: GenerationID? = nil) {
        self.init(
            chat: key.chatID,
            thread: key.threadID == 0 ? nil : key.threadID,
            user: user,
            generation: generation
        )
    }

    /// Fills in whatever the more specific context did not say. Used by
    /// `LoggerPort.with(_:)`, so a component can pin its chat once and every
    /// line it writes carries it.
    func merging(_ other: LogContext) -> LogContext {
        LogContext(
            chat: other.chat ?? chat,
            thread: other.thread ?? thread,
            user: other.user ?? user,
            generation: other.generation ?? generation
        )
    }
}

enum LogLevel: Int, Comparable, Sendable {
    case info = 0
    case warning = 1
    case error = 2

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var tag: String {
        switch self {
        case .info: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERROR"
        }
    }

    init?(name: String) {
        switch name.lowercased() {
        case "info", "debug": self = .info
        case "warn", "warning": self = .warning
        case "error": self = .error
        default: return nil
        }
    }
}

/// The one sink for everything the bot says about itself.
///
/// `@autoclosure` on the message means a line below the configured level costs
/// nothing: the interpolation is never evaluated.
protocol LoggerPort: Sendable {
    func log(_ level: LogLevel, _ message: @autoclosure () -> String, context: LogContext)
}

extension LoggerPort {
    func info(_ message: @autoclosure () -> String, context: LogContext = .none) {
        log(.info, message(), context: context)
    }

    func warning(_ message: @autoclosure () -> String, context: LogContext = .none) {
        log(.warning, message(), context: context)
    }

    func error(_ message: @autoclosure () -> String, context: LogContext = .none) {
        log(.error, message(), context: context)
    }

    /// A logger that stamps every line with this context. Handed to a component
    /// that works on one chat or one generation, so its call sites stay plain.
    func with(_ context: LogContext) -> LoggerPort {
        ScopedLogger(base: self, scope: context)
    }
}

/// Carries a pinned context into every line the wrapped logger writes. The
/// caller's own context wins field by field — a scoped logger says where the
/// work is happening, a call site says what it is doing.
private struct ScopedLogger: LoggerPort {
    let base: LoggerPort
    let scope: LogContext

    func log(_ level: LogLevel, _ message: @autoclosure () -> String, context: LogContext) {
        base.log(level, message(), context: scope.merging(context))
    }
}
