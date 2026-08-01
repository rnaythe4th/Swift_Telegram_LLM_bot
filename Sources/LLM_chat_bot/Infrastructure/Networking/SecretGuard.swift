import Foundation

/// Helpers for handling the bot's own secrets: comparing them without leaking
/// how much of a guess was right, and keeping them out of anything we print.
enum SecretGuard {
    /// Compares two secrets in time that does not depend on how many leading
    /// bytes match.
    ///
    /// `==` on `String` returns as soon as it finds a difference, so the reply
    /// latency of a rejected webhook carries a few bits about the expected
    /// token. Over the public internet that signal is buried in jitter, but a
    /// byte-by-byte compare costs nothing and removes the question.
    static func constantTimeEquals(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        // Length is not secret (and cannot be hidden by this loop anyway), but
        // the comparison still has to run over a fixed number of bytes.
        var difference = UInt8(a.count == b.count ? 0 : 1)
        let width = max(a.count, b.count)
        guard width > 0 else { return a.count == b.count }
        for index in 0..<width {
            let lhsByte = index < a.count ? a[index] : 0
            let rhsByte = index < b.count ? b[index] : 0
            difference |= lhsByte ^ rhsByte
        }
        return difference == 0
    }
}

/// Redacts the process's own secrets from any string on its way to the logs.
///
/// The Telegram bot token is part of every API URL the bot builds, and a leaked
/// token is a complete takeover: whoever holds it reads every chat and speaks
/// as the bot. Transport errors quote the request they failed on, so one
/// unlucky error path is all it takes to publish the token to the log
/// collector. Registering the secrets once at boot means nothing has to
/// remember to redact at each call site.
/// Safety is provided by the lock around the secret set; nothing reaches the
/// storage without it (§5.5).
final class SecretRedactor: @unchecked Sendable {
    static let shared = SecretRedactor()

    private let lock = NSLock()
    /// Longest first, so a token that contains another secret as a prefix is
    /// replaced whole rather than in pieces.
    private var secrets: [String] = []

    private init() {}

    /// Secrets shorter than this are not distinctive enough to blank out — a
    /// four-character "key" would censor ordinary log text.
    private static let minimumSecretLength = 12

    func register(_ values: [String?]) {
        lock.lock()
        defer { lock.unlock() }
        for value in values.compactMap({ $0 }) where value.count >= Self.minimumSecretLength {
            if !secrets.contains(value) { secrets.append(value) }
        }
        secrets.sort { $0.count > $1.count }
    }

    func redact(_ message: String) -> String {
        lock.lock()
        let current = secrets
        lock.unlock()
        guard !current.isEmpty else { return message }
        var result = message
        for secret in current where result.contains(secret) {
            result = result.replacingOccurrences(of: secret, with: "«redacted»")
        }
        return result
    }
}
