import Foundation

// The «🎧 Прослушка беседы» page: one switch, the size of the buffer, and the
// two things anybody asks next — what exactly did it hear, and how do I make it
// forget.

extension BotMenuHandler {
    /// Sizes offered as buttons. The typed value covers everything in between;
    /// these are the three answers people actually want, in the order they cost.
    private static let listenSizes = [30, 100, 200]

    // MARK: - Page

    func renderListen(chatKey: ChatKey, invoker: UserKey? = nil) async -> MenuScreen {
        // A DM has no conversation to overhear except the one with the bot,
        // which is exactly what the ordinary memory already is. The button is
        // group-only; this is the second line of defence for a stale one.
        guard chatKey.chatID.isGroup else {
            return MenuScreen(
                """
                <b>🎧 Прослушка беседы</b>

                Это для общих чатов: там бот читает разговор целиком и отвечает \
                в его контексте.

                В личке он и так помнит всё, о чём вы говорили — это «📝 Память» \
                в тонкой настройке.
                """,
                [navButtons()]
            )
        }

        let listening = await state.listening(chatKey: chatKey)
        let isOperator = await state.isAdmin(invoker, chatID: chatKey.chatID)
        let cost = listening.promptCost

        var rows: Keyboard = []
        rows.row([
            listening.isOn
                ? menuButton("🟢 Слушаю — выключить", .listen, "off")
                : menuButton("⚪️ Не слушаю — включить", .listen, "on")
        ])
        if !listening.transcript.isEmpty {
            rows.row([
                menuButton("📜 Что бот слышал", .listen, "dump"),
                menuButton("🧹 Забыть услышанное", .listen, "clear"),
            ])
        }
        if isOperator {
            var sizeRow: [InlineKeyboardButton] = []
            for size in Self.listenSizes {
                let mark = size == listening.size ? "✓ " : ""
                sizeRow.append(menuButton("\(mark)\(size)", .listen, "size", size))
            }
            rows.row(sizeRow)
            rows.row([menuButton("✏️ Своё значение", .listen, "custom")])
        }
        rows.row(navButtons())

        let statusLine = listening.isOn
            ? "🟢 <b>Слушаю этот чат.</b> В буфере · <b>\(listening.transcript.count)</b> из \(listening.size) сообщ."
            : "⚪️ <b>Не слушаю.</b> Бот отвечает только на то, что написали ему."
        // The number that decides whether 200 is a good idea. Approximate on
        // purpose — the order of magnitude is the whole message.
        let costLine = listening.isOn && !listening.transcript.isEmpty
            ? "\n💸 К каждому ответу добавляется ≈ <b>\(cost.characters)</b> симв. (~\(cost.tokens) токенов) — это платно."
            : ""
        let sizeHint = isOperator
            ? "\n\nРазмер буфера меняет владелец бота: чем больше, тем лучше бот понимает разговор — и тем дороже каждый ответ (\(ChatTranscript.sizeRange.lowerBound)–\(ChatTranscript.sizeRange.upperBound))."
            : "\n\n<i>Размер буфера (сейчас \(listening.size)) настраивает владелец бота.</i>"

        let text = """
        <b>🎧 Прослушка беседы</b>

        \(statusLine)\(costLine)

        Когда включено, бот читает <b>все</b> сообщения этого чата и держит \
        последние \(listening.size) в памяти: кто написал, в каком порядке и кому отвечал. \
        Обратитесь к нему — упоминанием или ответом на его сообщение — и он ответит \
        именно на ваш вопрос, но зная, о чём шла речь до этого.

        <i>Картинки не сохраняются — только текст и подписи. У каждой темы (топика) \
        буфер свой.</i>\(sizeHint)
        """
        return MenuScreen(text, rows)
    }

    // MARK: - Actions

    func processListenAction(
        route: MenuRoute,
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard chatKey.chatID.isGroup else {
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🎧 Прослушка — только для общих чатов")
            return
        }

        switch route.sub {
        case "on", "off":
            let on = route.sub == "on"
            let changed = await state.setListenMode(chatKey: chatKey, on: on)
            try? await telegram.answerCallback(
                callbackQueryID: callback.id,
                text: on ? "🎧 Слушаю этот чат" : "🎧 Больше не слушаю"
            )
            // Said out loud, in the chat, every time it changes. A bot that
            // starts recording a room silently is a bot nobody should install:
            // the people whose messages are being kept are not the person who
            // tapped the button, and they never see this menu.
            if changed {
                await sendPlain(chatKey: chatKey, text: Self.listenAnnouncement(on: on))
            }
            try await showPage(.listen, chatKey: chatKey, callback: callback, message: message)

        case "dump":
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: nil)
            await sendTranscriptDump(chatKey: chatKey)

        case "clear":
            let erased = await state.clearTranscript(chatKey: chatKey)
            try? await telegram.answerCallback(
                callbackQueryID: callback.id,
                text: erased > 0 ? "🧹 Забыто сообщений: \(erased)" : "Буфер и так пуст"
            )
            try await showPage(.listen, chatKey: chatKey, callback: callback, message: message)

        case "size", "custom":
            // The size is what the buffer *costs*, and the cost lands on
            // whoever pays for this chat — same gate as the memory length.
            guard await requireOperator(callback, chatKey: chatKey,
                                        refusal: "🔒 Размер буфера настраивает владелец бота") else { return }
            if route.sub == "custom" {
                await state.setPending(
                    .admin(.init(kind: .chatListenSize)),
                    menuMessageID: message.message_id,
                    chatKey: chatKey
                )
                let prompt = """
                <b>🎧 Размер буфера прослушки</b>

                Отправьте число от <code>\(ChatTranscript.sizeRange.lowerBound)</code> до \
                <code>\(ChatTranscript.sizeRange.upperBound)</code> одним сообщением — \
                сколько последних сообщений чата бот держит в памяти.

                <i>Чем больше, тем дороже каждый ответ.</i>
                """
                try await editOrAnswer(callback: callback, message: message, screen: MenuScreen(prompt, [[cancelButton(to: .listen)]]))
                return
            }
            guard let size = route.int(2) else { return try await staleTap(callback) }
            let applied = await state.setListenSize(chatKey: chatKey, size: size)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Буфер: \(applied) сообщ.")
            try await showPage(.listen, chatKey: chatKey, callback: callback, message: message)

        default:
            try await staleTap(callback)
        }
    }

    /// What the chat is told when listening is switched on or off. Plain and
    /// unmissable: this is the only notice the other members of the group ever
    /// get, and it has to be true about what is kept and for how long.
    static func listenAnnouncement(on: Bool) -> String {
        on
            ? """
            🎧 <b>Бот теперь читает этот чат.</b>

            Последние сообщения (текст и подписи, без картинок) он держит в памяти, \
            чтобы отвечать по делу, когда к нему обращаются. Посмотреть, что \
            накопилось, или стереть — /menu → 🎧 Прослушка беседы.
            """
            : """
            🎧 <b>Бот больше не читает этот чат.</b>

            Новые сообщения не сохраняются. Он отвечает только на то, что написали \
            лично ему. Накопленное осталось в буфере — стереть можно там же, \
            /menu → 🎧 Прослушка беседы.
            """
    }

    /// The buffer read back, the same way `sendHistoryDump` reads back the
    /// memory: newest lines that fit, escaped where they become markup, with a
    /// header that says how many of them there are. One implementation of "read
    /// it back" per memory, and both are capped the same way — a report that
    /// silently sends nothing reads as a broken button.
    func sendTranscriptDump(chatKey: ChatKey) async {
        let (lines, total) = await state.transcriptLines(chatKey: chatKey)
        let text: String
        if lines.isEmpty {
            text = "🎧 Бот пока ничего не слышал в этом чате."
        } else {
            text = Self.transcriptDumpText(lines: lines.map { "\n" + $0 }, total: total)
        }
        await sendPlain(chatKey: chatKey, text: text)
    }

    static func transcriptDumpText(lines: [String], total: Int) -> String {
        var kept: [String] = []
        var used = 0
        for line in lines.reversed() {
            let cost = line.utf16.count + 1
            guard used + cost <= MessageSplitter.charLimit else { break }
            used += cost
            kept.insert(line, at: 0)
        }
        let header = kept.count == total
            ? "<b>🎧 Что бот слышал</b> (\(total))"
            : "<b>🎧 Что бот слышал</b> · последние <b>\(kept.count)</b> из \(total)"
        guard !kept.isEmpty else {
            return MessageSplitter.splitRendered(header + (lines.last ?? "")).done
        }
        return ([header] + kept).joined(separator: "\n")
    }
}
