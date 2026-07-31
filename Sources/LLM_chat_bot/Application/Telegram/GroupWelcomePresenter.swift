import Foundation

/// The greeting a group gets when the bot joins it (roadmap step 4).
///
/// Two paths reach it and either may arrive first: the `my_chat_member` join
/// event, and the `/start <payload>` message Telegram posts into the chat when
/// the bot is added through a `?startgroup=` link. Both call
/// `ChatContextStore.claimGroupGreeting`, so the chat is greeted exactly once;
/// the copy and keyboard live here so the two paths can never drift apart.
enum GroupWelcomePresenter {
    struct Welcome: Sendable {
        let text: String
        let markup: InlineKeyboardMarkup
        /// True when example buttons made it into the keyboard — the caller
        /// counts the onboarding impression for the funnel.
        let showsExamples: Bool
    }

    /// - Parameter sponsor: ready-to-print label of whoever's active
    ///   subscription already covers this chat, if any. Present → the chat is greeted as unlocked and the
    ///   sponsor is credited (roadmap step 3) instead of being sold to.
    static func welcome(sponsor: String?, onboarding: OnboardingConfig) -> Welcome {
        var text = """
        <b>👋 Всем привет!</b> Я умный ИИ-ассистент.

        Отвечаю на @упоминание или на реплай моему сообщению. Понимаю текст, фото, голос и видео, помню разговор.
        """

        if let sponsor {
            text += "\n\n⚡ <b>Премиум в этом чате уже открыт</b> — спасибо, \(sponsor)! Всем участникам доступны умные модели, без рекламы и дневных лимитов."
        } else {
            text += "\n\n⚡ <b>Полный доступ</b> — умные модели, без рекламы и дневных лимитов — для этого чата может открыть любой участник, и он заработает сразу для всех."
        }

        var rows: [[InlineKeyboardButton]] = []
        var showsExamples = false
        if onboarding.showInGroups {
            let exampleRows = OnboardingPresenter.exampleRows(onboarding, inGroup: true)
            if !exampleRows.isEmpty {
                text += "\n\n" + OnboardingPresenter.invitation
                rows.append(contentsOf: exampleRows)
                showsExamples = true
            }
        }

        if sponsor == nil {
            rows.append([InlineKeyboardButton(
                text: "⚡ Премиум для чата",
                callback_data: BotCallbackAction.menu(action: MenuRoute.purchase(from: .welcome)).rawData
            )])
        }
        rows.append([InlineKeyboardButton(
            text: "⚙️ Настройки",
            callback_data: BotCallbackAction.menu(action: MenuRoute.link(.open)).rawData
        )])

        return Welcome(text: text, markup: InlineKeyboardMarkup(inline_keyboard: rows), showsExamples: showsExamples)
    }
}
