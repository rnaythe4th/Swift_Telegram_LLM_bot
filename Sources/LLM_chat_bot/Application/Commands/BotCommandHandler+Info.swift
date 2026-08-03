import Foundation

// Read-only lookups: /chatid, /inspect and /history.

extension BotCommandHandler {
    func handleChatID(chatKey: ChatKey) async throws {
        let ownerLabel = await state.chatOwnerLabel(chatID: chatKey.chatID)
        let meta = await state.chatMeta(chatID: chatKey.chatID)
        var lines = ["<b>🆔 Этот чат</b>", ""]
        lines.append("ID · <code>\(chatKey.chatID)</code>")
        if chatKey.threadID != 0 {
            lines.append("Тема · <code>\(chatKey.threadID)</code>")
        }
        if let meta {
            lines.append("Тип · \(meta.type)" + (meta.safeTitle.map { " · «\($0)»" } ?? ""))
        }
        lines.append(ownerLabel.map { "Премиум · открыл \($0)" } ?? "Премиум · <i>здесь не открыт</i>")
        lines.append("")
        lines.append("<i>Если премиум есть у вас — включить его в этом чате: /tenant claim</i>")
        try await sendUserFeedback(chatKey: chatKey, text: lines.joined(separator: "\n"))
    }

    func handleInspect(chatKey: ChatKey, argument: String) async throws {
        let parts = argument.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first, let targetChatID = Int(first).map(ChatID.init) else {
            try await sendUserFeedback(chatKey: chatKey, text: """
                <b>👁 Инспекция чата</b>

                <code>/inspect &lt;chatID&gt;</code> — настройки и роль чата
                Список чатов с ID — /chats, либо /menu → Супер-админ → 👁 Чаты
                """)
            return
        }

        let label = await state.chatDisplayLabel(chatID: targetChatID)
        let owner = await state.chatOwnerLabel(chatID: targetChatID)
        let keys = await state.existingContextKeys(chatID: targetChatID)

        guard !keys.isEmpty else {
            try await sendUserFeedback(chatKey: chatKey, text: "Чат <code>\(targetChatID)</code> ещё не общался с ботом.")
            return
        }

        var lines = ["<b>👁 \(label)</b> · <code>\(targetChatID)</code>"]
        lines.append(owner.map { "Премиум · \($0)" } ?? "Премиум · <i>нет (бесплатный)</i>")

        for key in keys.prefix(6) {
            guard let help = await state.peekHelp(chatKey: key) else { continue }
            lines.append("")
            lines.append(key.threadID == 0 ? "<b>Основной тред</b>" : "<b>Топик \(key.threadID)</b>")
            lines.append("🤖 <code>\(help.escapedModel)</code> · 🌡 \(BotMenuHandler.formatTemp(help.temp)) · 📝 \(help.maxHistory)")
            let realStr = help.cumulativeUsage.totalCost.formatted()
            let billedStr = await state.billedCost(of: help.cumulativeUsage).formatted()
            lines.append("📈 запросов \(help.cumulativeUsage.generationCount) · токенов \(ResponseFooterFormatter.formatTokenValue(help.cumulativeUsage.totalTokens)) · реально \(realStr) · клиентам \(billedStr)")
            let rolePreview = help.role.count > 300 ? String(help.role.prefix(300)) + "…" : help.role
            lines.append("🎭 <blockquote expandable>\(rolePreview)</blockquote>")
        }
        if keys.count > 6 {
            lines.append("\n<i>…и ещё \(keys.count - 6) топиков</i>")
        }

        try await sendUserFeedback(chatKey: chatKey, text: lines.joined(separator: "\n"))
    }

    /// `/history` and the menu's «📜 Что бот помнит» are one report with two
    /// doors, so there is one implementation. The copy that used to live here
    /// printed the conversation into HTML raw and unbounded — and a
    /// conversation is exactly the text that contains `<` (every answer that
    /// ever quoted code) and exactly the text that outgrows one message. Both
    /// come back from Telegram as a rejection of the *whole* message, so the
    /// command answered nothing at all. `sendHistoryDump` escapes each line
    /// where it becomes markup and keeps the newest lines that fit.
    func handleHistory(chatKey: ChatKey) async throws {
        await menuHandler.sendHistoryDump(chatKey: chatKey)
    }
}

// MARK: - /forget (§7.2)

extension BotCommandHandler {
    /// Erases the conversation of the chat it is used in.
    ///
    /// In a group it is the shared history of everyone in the room, so only
    /// somebody who can already administer the chat's settings may do it — the
    /// alternative is any member wiping a team's context on a whim.
    ///
    /// The wallet, the subscription and the money journal are untouched: those
    /// are financial records, and the person's own evidence if a charge is ever
    /// disputed. Deleting them on request would erase the proof, not the data.
    func handleForget(chatKey: ChatKey, fromUser: TelegramUser?) async throws {
        if chatKey.chatID.isGroup {
            guard await isAdmin(fromUser, chatID: chatKey.chatID) else {
                try await sendUserFeedback(
                    chatKey: chatKey,
                    text: "🔒 В общем чате переписку стирает тот, кто им управляет — она общая."
                )
                return
            }
        }
        let erased = await state.forgetChat(chatKey: chatKey)
        try await sendUserFeedback(chatKey: chatKey, text: erased
            ? """
            🧹 <b>Переписка удалена.</b>

            Бот забыл всё, что здесь обсуждалось. Настройки чата, баланс, подписка и история платежей не тронуты — это ваши деньги и ваши документы по ним.
            """
            : "🧹 Здесь и так ничего не сохранено."
        )
    }
}
