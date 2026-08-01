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
    ///
    /// HTML-safe like `UserIdentity.displayLabel`: a group title is free text
    /// chosen by whoever can rename the chat, and it is printed straight into
    /// the admin's chat list — an unescaped one could open a tag there.
    var displayLabel: String {
        if let title, !title.isEmpty { return UserIdentity.sanitizeName(title) ?? type }
        if let username, !username.isEmpty { return "@\(UserIdentity.sanitizeName(username) ?? username)" }
        if let firstName, !firstName.isEmpty { return UserIdentity.sanitizeName(firstName) ?? type }
        return type
    }

    /// Title as it is safe to print. Same rule as `displayLabel`, for the call
    /// sites that want the title specifically (`/inspect`).
    var safeTitle: String? {
        guard let title, !title.isEmpty else { return nil }
        return UserIdentity.sanitizeName(title)
    }
}

/// One reusable invite link owned by an admin. Redeeming grants the visitor
/// paid-model access under that admin's licence.
struct InviteRecord: Codable, Sendable, Equatable {
    var ownerKey: UserKey
    var createdAt: Date
}
