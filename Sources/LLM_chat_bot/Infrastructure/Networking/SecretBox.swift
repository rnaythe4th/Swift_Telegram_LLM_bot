import Foundation
import Crypto

/// Encrypts the handful of stored values that are worth stealing on their own:
/// the card provider token and the checkout's two signing words (§5.6).
///
/// Keeping them in the database rather than in the environment is the right
/// product decision — the owner configures payments from inside the bot, with
/// no redeploy — but it means a dump, a backup, or a leaked read-only
/// credential hands over the payment credentials themselves. `SecretRedactor`
/// only ever covered logs.
///
/// So they are sealed with AES-GCM under a key from the environment. The key
/// lives where the database is not: losing it costs re-entering the merchant
/// details from the vendor's dashboard, never the bot's state.
enum SecretBox {
    /// 32 bytes, base64. Generate with `openssl rand -base64 32`.
    static let environmentKey = "STATE_ENCRYPTION_KEY"

    /// Marks a value as sealed. A stored secret either starts with this, or it
    /// is plaintext from before a key was configured — both have to be readable
    /// or turning encryption on would lock the owner out of their own merchant
    /// settings.
    private static let prefix = "enc:v1:"

    private static let key = LockedValue<SymmetricKey?>(nil)

    /// Installs the key at boot. Returns false when one was configured but is
    /// not 32 bytes of base64 — the caller refuses to start rather than
    /// silently storing secrets in the clear.
    @discardableResult
    static func configure(base64Key: String?) -> Bool {
        guard let base64Key, !base64Key.isEmpty else {
            key.value = nil
            return true
        }
        guard let data = Data(base64Encoded: base64Key), data.count == 32 else {
            return false
        }
        key.value = SymmetricKey(data: data)
        return true
    }

    static var isConfigured: Bool { key.value != nil }

    /// Seals a value for storage. Without a key the value is stored as it
    /// always was: encryption is opt-in, and a bot that has never had a key
    /// must keep working.
    static func seal(_ value: String) -> String {
        guard !value.isEmpty, let key = key.value else { return value }
        guard let sealed = try? AES.GCM.seal(Data(value.utf8), using: key),
              let combined = sealed.combined else {
            return value
        }
        return prefix + combined.base64EncodedString()
    }

    /// Opens a stored value. Anything without the marker is returned unchanged
    /// (it predates the key); anything sealed with a *different* key comes back
    /// empty rather than as garbage — an unreadable merchant secret must look
    /// like "not configured", not like a wrong password at the vendor.
    static func open(_ stored: String) -> String {
        guard stored.hasPrefix(prefix) else { return stored }
        guard let key = key.value,
              let data = Data(base64Encoded: String(stored.dropFirst(prefix.count))),
              let box = try? AES.GCM.SealedBox(combined: data),
              let opened = try? AES.GCM.open(box, using: key) else {
            return ""
        }
        return String(decoding: opened, as: UTF8.self)
    }

    /// True when a stored value is sealed but cannot be opened — the shape of
    /// "the key changed and nobody re-entered the credentials".
    static func isUnreadable(_ stored: String) -> Bool {
        stored.hasPrefix(prefix) && open(stored).isEmpty
    }
}

/// A stored string that is encrypted at rest and masked everywhere else.
///
/// The type is what keeps this honest: `description` never yields the value, so
/// an accidental interpolation into a log line or a menu page prints `‹secret›`
/// rather than the card token. Reading it takes saying so.
@propertyWrapper
struct Secret: Codable, Sendable, Equatable, CustomStringConvertible {
    /// Ciphertext as stored. Encoding and decoding go through this, so the
    /// value is sealed exactly once on its way out and opened on its way in.
    private var sealed: String

    var wrappedValue: String {
        get { SecretBox.open(sealed) }
        set { sealed = SecretBox.seal(newValue) }
    }

    var projectedValue: Secret { self }

    init(wrappedValue: String) {
        self.sealed = SecretBox.seal(wrappedValue)
    }

    var isEmpty: Bool { wrappedValue.isEmpty }

    /// Set but not openable with the current key.
    var isUnreadable: Bool { SecretBox.isUnreadable(sealed) }

    var description: String { wrappedValue.isEmpty ? "" : "‹secret›" }

    // MARK: - Codable

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Stored as-is: already ciphertext, or plaintext written before a key
        // was configured.
        sealed = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        // Re-seal on the way out, so a value that was plaintext before the key
        // existed becomes encrypted the first time its document is rewritten.
        try container.encode(SecretBox.seal(SecretBox.open(sealed)))
    }
}
