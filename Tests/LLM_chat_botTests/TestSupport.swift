import Foundation
@testable import LLM_chat_bot

// Shared builders. Everything here is in-memory: no network, no Supabase, no
// Telegram — the state actor and the domain types are pure by construction.

enum Fixtures {
    static let ownerUsername = "owner"
    static let ownerUserID = 1_000

    /// A store wired the way `main` wires it, minus the ports.
    static func makeStore(
        ownerUsername: String = Fixtures.ownerUsername,
        ownerUserID: Int? = Fixtures.ownerUserID,
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

    static func user(id: Int, username: String? = nil, firstName: String = "Name") -> TelegramUser {
        TelegramUser(id: id, is_bot: false, first_name: firstName, username: username)
    }

    static func chat(id: Int, type: String = "private", title: String? = nil) -> TelegramChat {
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
