import Foundation
@testable import LLM_chat_bot

// Shared builders. Everything here is in-memory: no network, no Supabase, no
// Telegram — the state actor and the domain types are pure by construction.

enum Fixtures {
    /// The @username the bot is configured with, and the key that handle
    /// resolves to once the owner has been seen.
    static let ownerHandle = "owner"
    static let ownerUserID: UserID = 1_000
    static var ownerKey: UserKey { .identified(ownerUserID) }

    /// Any key, for tests that only need "somebody".
    static func key(_ userID: UserID) -> UserKey { .identified(userID) }

    /// A store wired the way `main` wires it, minus the ports.
    static func makeStore(
        ownerUsername: String = Fixtures.ownerHandle,
        ownerUserID: UserID? = Fixtures.ownerUserID,
        model: String = "test/model",
        defaultHistoryLength: Int = 10
    ) -> ChatContextStore {
        ChatContextStore(
            ownerUsername: ownerUsername,
            ownerUserID: ownerUserID,
            model: model,
            systemPrompt: "system",
            formatOptions: "",
            companyChatId: -1,
            companyMembers: "",
            defaultHistoryLength: defaultHistoryLength,
            defaultSuffix: nil
        )
    }

    static func user(id: UserID, username: String? = nil, firstName: String = "Name") -> TelegramUser {
        TelegramUser(id: id, is_bot: false, first_name: firstName, username: username)
    }

    static func chat(id: ChatID, type: String = "private", title: String? = nil) -> TelegramChat {
        TelegramChat(id: id, type: type, title: title)
    }

    static func message(
        id: Int = 1,
        text: String? = nil,
        caption: String? = nil,
        from: TelegramUser? = nil,
        chat: TelegramChat,
        replyTo: TelegramMessage? = nil
    ) -> TelegramMessage {
        TelegramMessage(
            message_id: id,
            from: from,
            chat: chat,
            date: 0,
            text: text,
            caption: caption,
            voice: nil,
            video: nil,
            message_thread_id: nil,
            media_group_id: nil,
            reply_to_message: replyTo,
            photo: nil
        )
    }

    static func days(_ count: Double) -> TimeInterval { count * 86_400 }
}

// Integer literals for ids, in the test target only.
//
// `ChatID(-7_200)` at three hundred call sites reads as ceremony, not as
// meaning. The conformance lives here rather than next to the types on
// purpose: production code has to say which kind of id it means, and a bare
// number must stay unassignable there — that is the whole point of the types.
extension ChatID: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self.init(value) }
}

extension UserID: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self.init(value) }
}
