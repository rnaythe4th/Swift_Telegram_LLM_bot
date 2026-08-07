import Foundation

// `/listen` — the same switch as the menu page, for people who type.
//
// It exists because of the rule that a setting which multiplies the price of an
// answer must be closed in *both* places (CLAUDE.md §14): a command that skips
// the gate the button enforces is the gate not existing.

extension BotCommandHandler {
    func handleListen(chatKey: ChatKey, argument: String, fromUser: TelegramUser?) async throws {
        guard chatKey.chatID.isGroup else {
            try await sendUserFeedback(
                chatKey: chatKey,
                text: """
                🎧 Прослушка беседы — для общих чатов: там бот читает разговор целиком.
                В личке он и так помнит всё, о чём вы говорили: /menu → ⚙️ Тонкая настройка → 📝 Память.
                """
            )
            return
        }

        let argument = argument.trimmingCharacters(in: .whitespaces).lowercased()
        let listening = await state.listening(chatKey: chatKey)

        // Status is a question, not a change: anyone in the chat may ask it.
        guard !argument.isEmpty else {
            try await sendUserFeedback(chatKey: chatKey, text: Self.listenStatus(listening))
            return
        }

        // Size first: it is the operator's lever, and the tighter gate has to
        // run before the looser one lets the value through.
        if let size = Int(argument) {
            guard await requireOperatorForTuning(
                chatKey: chatKey,
                fromUser: fromUser,
                refusal: "🔒 Размер буфера прослушки настраивает владелец бота."
            ) else { return }
            guard ChatTranscript.sizeRange.contains(size) else {
                try await sendUserFeedback(
                    chatKey: chatKey,
                    text: "⚠️ Нужно число от \(ChatTranscript.sizeRange.lowerBound) до \(ChatTranscript.sizeRange.upperBound)."
                )
                return
            }
            let applied = await state.setListenSize(chatKey: chatKey, size: size)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Буфер прослушки: <b>\(applied) сообщ.</b>")
            return
        }

        switch argument {
        case "on", "вкл", "включить":
            guard await requireFullAccessForTuning(chatKey: chatKey, fromUser: fromUser) else { return }
            let changed = await state.setListenMode(chatKey: chatKey, on: true)
            try await sendUserFeedback(
                chatKey: chatKey,
                text: changed ? BotMenuHandler.listenAnnouncement(on: true) : "🎧 Уже слушаю этот чат."
            )

        case "off", "выкл", "выключить":
            guard await requireFullAccessForTuning(chatKey: chatKey, fromUser: fromUser) else { return }
            let changed = await state.setListenMode(chatKey: chatKey, on: false)
            try await sendUserFeedback(
                chatKey: chatKey,
                text: changed ? BotMenuHandler.listenAnnouncement(on: false) : "🎧 И так не слушаю."
            )

        case "clear", "стереть", "забыть":
            // Same audience as the switch: whoever may stop the recording may
            // erase what it produced. Being harder to erase than to record is
            // the wrong way round for something that keeps what other people
            // said.
            guard await requireFullAccessForTuning(chatKey: chatKey, fromUser: fromUser) else { return }
            let erased = await state.clearTranscript(chatKey: chatKey)
            try await sendUserFeedback(
                chatKey: chatKey,
                text: erased > 0 ? "🧹 Бот забыл услышанное: \(erased) сообщ." : "🧹 Буфер и так пуст."
            )

        case "dump", "log", "показать":
            await menuHandler.sendTranscriptDump(chatKey: chatKey)

        default:
            try await sendUserFeedback(
                chatKey: chatKey,
                text: """
                🎧 <b>Прослушка беседы</b>

                <code>/listen</code> — что сейчас
                <code>/listen on</code> · <code>/listen off</code> — включить или выключить
                <code>/listen dump</code> — что бот слышал
                <code>/listen clear</code> — забыть услышанное
                <code>/listen \(ChatTranscript.defaultSize)</code> — размер буфера (владелец бота)
                """
            )
        }
    }

    private static func listenStatus(_ listening: ChatListening) -> String {
        guard listening.isOn else {
            return """
            ⚪️ <b>Прослушка выключена.</b> Бот отвечает только на то, что написали ему.
            Включить — <code>/listen on</code> или /menu → 🎧 Прослушка беседы.
            """
        }
        let cost = listening.promptCost
        return """
        🟢 <b>Слушаю этот чат.</b>
        В буфере · <b>\(listening.transcript.count)</b> из \(listening.size) сообщ. \
        (≈ \(cost.characters) симв., ~\(cost.tokens) токенов к каждому ответу)

        <code>/listen dump</code> — что бот слышал · <code>/listen off</code> — выключить
        """
    }
}
