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

    /// What a stored value should look like on its way back to the row: sealed
    /// if it is still plaintext from before a key existed, and **untouched**
    /// otherwise — including when this process cannot open it.
    ///
    /// Ciphertext we cannot read still belongs to whoever holds the key.
    /// Re-sealing it would need the plaintext we do not have, and writing what
    /// we *do* have (nothing) turns one deploy without `STATE_ENCRYPTION_KEY`
    /// into permanently lost merchant credentials.
    static func resealingPlaintext(_ stored: String) -> String {
        stored.hasPrefix(prefix) ? stored : seal(stored)
    }
}

/// A payment credential in the form the row holds it: ciphertext under the
/// current key, ciphertext under a key this process does not have, or plaintext
/// written before a key was ever configured.
///
/// Keeping the *sealed* form rather than the opened one is the whole point.
/// `SecretBox.open` answers "" for a value it cannot decrypt, so a type that
/// kept only that answer would write "" back the next time its document is
/// saved: a rollback, a fresh environment or a rotated key would destroy the
/// merchant credentials for good — including for the deploy that brings the key
/// back — and nothing would say so, because an unreadable secret already reads
/// as "not configured".
///
/// The type is also what keeps the plaintext from leaking by accident: there is
/// no way to get it by interpolation (`description` prints `‹secret›`), and no
/// way to overwrite it with a plain `String` — assigning one does not compile,
/// which is what makes the round trip "read plaintext, write it back" —
/// the shape of the bug above — impossible to write by mistake.
struct SealedSecret: Codable, Sendable, Equatable, CustomStringConvertible, ExpressibleByStringLiteral {
    /// Exactly what belongs in the column.
    private var stored: String

    init(_ plaintext: String) {
        let trimmed = plaintext.trimmingCharacters(in: .whitespacesAndNewlines)
        stored = SecretBox.seal(trimmed)
        Self.registerForRedaction(trimmed)
    }

    /// Literals only, for the settings the tests and defaults spell out. A
    /// `String` variable — the shape a decoded-then-reassigned secret takes —
    /// stays uninhabitable on purpose.
    init(stringLiteral value: StringLiteralType) { self.init(value) }

    /// The credential, or nil when it is empty or sealed under another key.
    /// Callers read nil as "not configured", which is the fail-closed answer: a
    /// checkout that cannot sign must not run.
    var value: String? {
        let opened = SecretBox.open(stored)
        return opened.isEmpty ? nil : opened
    }

    /// Set, but not openable with the current key. A different problem from
    /// "never configured" and a different line on the settings page: the value
    /// is still in the row, and the key is what has to come back.
    var isUnreadable: Bool { SecretBox.isUnreadable(stored) }

    var description: String {
        if isUnreadable { return "‹unreadable›" }
        return value == nil ? "" : "‹secret›"
    }

    /// Equal when they mean the same thing. AES-GCM picks a fresh nonce per
    /// seal, so two seals of one secret never share ciphertext.
    static func == (lhs: SealedSecret, rhs: SealedSecret) -> Bool {
        if lhs.stored == rhs.stored { return true }
        guard let lhsValue = lhs.value, let rhsValue = rhs.value else { return false }
        return lhsValue == rhsValue
    }

    // MARK: - Codable

    init(from decoder: Decoder) throws {
        stored = try decoder.singleValueContainer().decode(String.self)
        Self.registerForRedaction(value)
    }

    /// A secret has to be redactable from the moment it exists, whether it was
    /// typed into a settings page or read back out of the row on restore — a
    /// transport error quotes the request it failed on, and for the checkout
    /// that request carries the signing word (§15). Doing it in the two
    /// initialisers is what makes it cover every sealed field, including ones
    /// added later, with nowhere to forget it.
    private static func registerForRedaction(_ plaintext: String?) {
        guard let plaintext, !plaintext.isEmpty else { return }
        SecretRedactor.shared.register([plaintext])
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(SecretBox.resealingPlaintext(stored))
    }
}

