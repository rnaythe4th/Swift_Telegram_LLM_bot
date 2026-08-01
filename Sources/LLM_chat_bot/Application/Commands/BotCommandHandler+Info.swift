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
        guard let first = parts.first, let targetChatID = Int(first) else {
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
            lines.append("🤖 <code>\(help.model)</code> · 🌡 \(BotMenuHandler.formatTemp(help.temp)) · 📝 \(help.maxHistory)")
            let realStr = help.cumulativeUsage.totalCost.formatted()
            let billedStr = await state.billedCost(of: help.cumulativeUsage).formatted()
            lines.append("📈 запросов \(help.cumulativeUsage.generationCount) · токенов \(Int(help.cumulativeUsage.totalTokens)) · реально \(realStr) · клиентам \(billedStr)")
            let rolePreview = help.role.count > 300 ? String(help.role.prefix(300)) + "…" : help.role
            lines.append("🎭 <blockquote expandable>\(rolePreview)</blockquote>")
        }
        if keys.count > 6 {
            lines.append("\n<i>…и ещё \(keys.count - 6) топиков</i>")
        }

        try await sendUserFeedback(chatKey: chatKey, text: lines.joined(separator: "\n"))
    }

    func handleHistory(chatKey: ChatKey) async throws {
        let messages = await state.history(chatKey: chatKey)
        guard !messages.isEmpty else {
            try await sendUserFeedback(chatKey: chatKey, text: "📝 Бот пока ничего не помнит — переписки нет.")
            return
        }

        var lines: [String] = ["<b>📝 Что бот помнит</b> (\(messages.count))"]
        for msg in messages {
            let roleLabel: String
            switch msg.role {
            case "system": roleLabel = "⚙️"
            case "user": roleLabel = "👤"
            case "assistant": roleLabel = "🤖"
            default: roleLabel = msg.role
            }

            let content: String
            switch msg.content {
            case .text(let text):
                content = text
            case .parts(let parts):
                let textParts = parts.compactMap { $0.text }
                let mediaTags = parts.compactMap { part -> String? in
                    if part.inputImage != nil { return "[изображение]" }
                    if part.inputAudio != nil { return "[аудио]" }
                    if part.inputVideo != nil { return "[видео]" }
                    return nil
                }
                content = (textParts.joined(separator: " ") + " " + mediaTags.joined(separator: " ")).trimmingCharacters(in: .whitespaces)
            }
            let displayContent = content.isEmpty ? "<i>(пусто)</i>" : truncateForHistory(content)
            lines.append("\n\(roleLabel) \(displayContent)")
        }

        try await sendUserFeedback(chatKey: chatKey, text: lines.joined(separator: "\n"))
    }

    private func truncateForHistory(_ text: String) -> String {
        let limit = 280
        guard text.count > limit else { return text }
        let endIndex = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<endIndex]) + "…"
    }
}
