import Foundation

/// A Telegram chat.
///
/// `Int` for both a chat and a user made them interchangeable at every call
/// site, and the one place the two genuinely *are* the same number — a private
/// chat's id equals the user's id — was expressed by passing one where the
/// other was expected. That is a convention, not a type, and conventions are
/// what the compiler cannot check: `chatID: bonus.inviterUserID` is correct
/// today and silently wrong the day somebody passes a group.
///
/// Decoded straight from the wire, so the boundary needs no conversion layer:
/// the API's number *is* this value.
struct ChatID: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    let value: Int

    init(_ value: Int) { self.value = value }

    /// The private chat with one person. Telegram gives it the same id as the
    /// user — this is the single place the bot leans on that, and naming it is
    /// the point: everywhere else the assumption is now unexpressible.
    static func privateChat(with user: UserID) -> ChatID { ChatID(user.value) }

    /// Groups, supergroups and channels have negative ids; private chats are
    /// positive. Replaces the scattered `chatID < 0` and its repeated
    /// "Telegram convention" comment.
    var isGroup: Bool { value < 0 }
    var isPrivate: Bool { value > 0 }

    /// The person behind a private chat, when it is one.
    var asUserID: UserID? { isPrivate ? UserID(value) : nil }

    /// Chat ids are shown to admins (`/chatid`, the chat lists), so unlike a
    /// `UserKey` this one prints as itself.
    var description: String { String(value) }

    static func < (lhs: ChatID, rhs: ChatID) -> Bool { lhs.value < rhs.value }

    init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(Int.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// A Telegram account. Permanent, unlike the @username, which is why every
/// stable record is filed under a `UserKey` built from one.
struct UserID: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    let value: Int

    init(_ value: Int) { self.value = value }

    /// This person's DM with the bot. The other half of the convention named
    /// in `ChatID.privateChat(with:)`.
    var privateChat: ChatID { .privateChat(with: self) }

    var description: String { String(value) }

    static func < (lhs: UserID, rhs: UserID) -> Bool { lhs.value < rhs.value }

    init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(Int.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

