import Foundation

/// Renders the onboarding example prompts (roadmap step 9) into Telegram
/// keyboards and texts. One place, so the /start greeting, the group welcome
/// and the super-admin preview always show the same thing.
enum OnboardingPresenter {
    /// Line above the example buttons.
    static let invitation = "💡 <b>Попробуйте прямо сейчас</b> — нажмите пример, я сразу отвечу:"

    /// Button rows for the examples active in this room (empty when onboarding
    /// is off or nothing applies here). Long captions get a row of their own so
    /// the text is never clipped.
    static func exampleRows(_ config: OnboardingConfig, inGroup: Bool) -> [[InlineKeyboardButton]] {
        var rows: [[InlineKeyboardButton]] = []
        var pending: [InlineKeyboardButton] = []
        for example in config.activeExamples(inGroup: inGroup) {
            let button = InlineKeyboardButton(
                text: example.label,
                callback_data: BotCallbackAction.example(id: example.id).rawData
            )
            if example.label.count > 18 {
                if !pending.isEmpty { rows.append(pending); pending = [] }
                rows.append([button])
            } else {
                pending.append(button)
                if pending.count == 2 { rows.append(pending); pending = [] }
            }
        }
        if !pending.isEmpty { rows.append(pending) }
        return rows
    }

    /// Echo posted in the chat when an example is tapped, so the conversation
    /// reads coherently (Telegram cannot post the prompt as the user).
    ///
    /// - Parameter asker: who tapped, printed only in groups. Without it a
    ///   shared chat sees a question appear out of nowhere and the answer that
    ///   follows looks like the bot talking to itself.
    static func tapEcho(example: OnboardingExample, asker: String?) -> String {
        let head = asker.map { "\(escape($0)) · \(escape(example.label))" } ?? escape(example.label)
        return "\(head)\n<blockquote>\(escape(example.prompt))</blockquote>"
    }

    /// Escapes text that goes into an HTML message. Example labels/prompts are
    /// free-form super-admin input — an unescaped `<` would make Telegram reject
    /// the whole message.
    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
