import Foundation

/// Human-readable identity of a chat, captured from incoming messages so
/// admins never have to work with bare numeric IDs.
struct ChatMetaInfo: Codable, Sendable, Equatable {
    /// "private", "group", "supergroup", "channel".
    var type: String
    /// Group/channel title.
    var title: String?
    /// Peer @username (private chats).
    var username: String?
    /// Peer first name (private chats).
    var firstName: String?
    /// Set when the bot was removed from this group (`my_chat_member` →
    /// left/kicked). Nothing can be delivered there any more, so broadcasts
    /// (renewal notices, sponsor congratulations) skip it. Cleared as soon as
    /// the bot is back or the chat talks to it again — hence optional, so old
    /// stored rows decode unchanged.
    var botRemoved: Bool?

    /// Compact display label: title for groups, @username / name for privates.
    var displayLabel: String {
        if let title, !title.isEmpty { return title }
        if let username, !username.isEmpty { return "@\(username)" }
        if let firstName, !firstName.isEmpty { return firstName }
        return type
    }
}

/// One reusable invite link owned by an admin. Redeeming grants the visitor
/// paid-model access under that admin's licence.
struct InviteRecord: Codable, Sendable, Equatable {
    var ownerUsername: String
    var createdAt: Date
}
