import Foundation

// Tenant-owner tooling: whitelist, defaults, chat and user listings, presets.

extension BotCommandHandler {
    func handleWhitelist(chatKey: ChatKey, argument: String) async throws {
        let parts = argument.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        let subcommand = parts.first ?? ""
        let value = parts.count > 1 ? parts[1] : ""

        switch subcommand.lowercased() {
        case "add":
            guard let userID = Int(value).map(UserID.init) else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Как пользоваться:</i> <code>/whitelist add &lt;номер пользователя&gt;</code>")
                return
            }
            await state.addToWhitelist(userID: userID, chatID: chatKey.chatID)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Пользователь <code>\(userID)</code> добавлен в гости этого чата — ваш премиум работает и для него.")

        case "remove":
            guard let userID = Int(value).map(UserID.init) else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Как пользоваться:</i> <code>/whitelist remove &lt;номер пользователя&gt;</code>")
                return
            }
            await state.removeFromWhitelist(userID: userID, chatID: chatKey.chatID)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Пользователь <code>\(userID)</code> больше не гость этого чата.")

        case "list":
            let ids = await state.listWhitelisted(chatID: chatKey.chatID)
            if ids.isEmpty {
                try await sendUserFeedback(chatKey: chatKey, text: "Гостей в этом чате пока нет.")
            } else {
                let sorted = ids.sorted()
                let list = sorted.map { "• <code>\($0)</code>" }.joined(separator: "\n")
                try await sendUserFeedback(chatKey: chatKey, text: "<b>👤 Гости этого чата</b> (\(sorted.count))\n\(list)")
            }

        default:
            try await sendUserFeedback(chatKey: chatKey, text: """
                <b>👤 Гости этого чата</b>
                Ваш премиум работает и для них — даже если сам чат к нему не подключён.

                <code>/whitelist add &lt;номер&gt;</code> — добавить
                <code>/whitelist remove &lt;номер&gt;</code> — убрать
                <code>/whitelist list</code> — показать

                <i>То же самое кнопками: /menu → ⚡ Мой премиум → 👤 Гости этого чата</i>
                """)
        }
    }

    func handleDefaults(chatKey: ChatKey, argument: String) async throws {
        let parts = argument.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        let subcommand = parts.first ?? ""
        let value = parts.count > 1 ? parts[1] : ""

        switch subcommand.lowercased() {
        case "model":
            guard !value.isEmpty else {
                let defs = await state.getDefaults(chatID: chatKey.chatID)
                try await sendUserFeedback(chatKey: chatKey, text: "Модель по умолчанию · <code>\(MessageText.escaped(defs.model))</code>")
                return
            }
            let new = await state.setDefaultModel(value, chatID: chatKey.chatID)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Модель по умолчанию · <code>\(MessageText.escaped(new))</code>")

        case "role":
            guard !value.isEmpty else {
                let defs = await state.getDefaults(chatID: chatKey.chatID)
                try await sendUserFeedback(chatKey: chatKey, text: "Роль по умолчанию:\n<blockquote expandable>\(MessageText.escaped(defs.role))</blockquote>")
                return
            }
            let new = await state.setDefaultRole(value, chatID: chatKey.chatID)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Роль по умолчанию обновлена:\n<blockquote expandable>\(MessageText.escaped(new))</blockquote>")

        case "historylength":
            guard !value.isEmpty, let length = Int(value), ChatContext.historyRange.contains(length) else {
                if value.isEmpty {
                    let defs = await state.getDefaults(chatID: chatKey.chatID)
                    try await sendUserFeedback(chatKey: chatKey, text: "Память в новых чатах · <b>\(defs.historyLength) сообщ.</b>")
                } else {
                    try await sendUserFeedback(chatKey: chatKey, text: "<i>Нужно число от 1 до 50.</i>\n<i>Пример:</i> <code>/defaults historylength 11</code>")
                }
                return
            }
            let new = await state.setDefaultHistoryLength(length, chatID: chatKey.chatID)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Память в новых чатах · <b>\(new) сообщ.</b>")

        default:
            let defs = await state.getDefaults(chatID: chatKey.chatID)
            try await sendUserFeedback(chatKey: chatKey, text: """
                <b>⚙️ Значения по умолчанию</b>

                🤖 Модель · <code>\(MessageText.escaped(defs.model))</code>
                📝 Память · <b>\(defs.historyLength) сообщ.</b>
                🎭 Роль:
                <blockquote expandable>\(MessageText.escaped(defs.role))</blockquote>

                <b>Команды:</b>
                <code>/defaults model &lt;id&gt;</code>
                <code>/defaults role &lt;текст&gt;</code>
                <code>/defaults historylength &lt;1–50&gt;</code>

                <i>Заготовки для кнопок меню — /presets</i>
                """)
        }
    }

    func handleChats(chatKey: ChatKey, fromUser: TelegramUser?) async throws {
        let isSuperAdmin = await self.isSuperAdmin(fromUser)
        // `chatOwnership` stores a UserKey (`#12345`), so a raw handle would
        // never match and the licence owner would see an empty list. Filtering
        // is off entirely for a super-admin (nil = every chat).
        let ownerFilter: UserKey? = isSuperAdmin ? nil : await ownerKey(for: fromUser)
        let groups = await state.groupChats(ownedBy: ownerFilter)
        let privates = await state.privateChats(ownedBy: ownerFilter)

        var lines: [String] = []

        lines.append("<b>👥 Групповые чаты</b> (\(groups.count))")
        if groups.isEmpty {
            lines.append("<i>нет</i>")
        } else {
            for (chatID, threadID) in groups.sorted(by: { $0.chatID < $1.chatID }).prefix(Self.listCap) {
                let threadInfo = threadID != 0 ? " · thread \(threadID)" : ""
                let label = await state.chatMeta(chatID: chatID).map { " · \($0.displayLabel)" } ?? ""
                lines.append("• <code>\(chatID)</code>\(threadInfo)\(label)")
            }
            if groups.count > Self.listCap {
                lines.append("<i>…и ещё \(groups.count - Self.listCap)</i>")
            }
        }

        lines.append("")
        lines.append("<b>👤 Личные чаты</b> (\(privates.count))")
        if privates.isEmpty {
            lines.append("<i>нет</i>")
        } else {
            for (chatID, threadID) in privates.sorted(by: { $0.chatID < $1.chatID }).prefix(Self.listCap) {
                let threadInfo = threadID != 0 ? " · thread \(threadID)" : ""
                let label = await state.chatMeta(chatID: chatID).map { " · \($0.displayLabel)" } ?? ""
                lines.append("• <code>\(chatID)</code>\(threadInfo)\(label)")
            }
            if privates.count > Self.listCap {
                lines.append("<i>…и ещё \(privates.count - Self.listCap)</i>")
            }
        }

        if isSuperAdmin {
            lines.append("")
            lines.append("<i>Настройки любого чата: /inspect &lt;chatID&gt;</i>")
        }

        try await sendUserFeedback(chatKey: chatKey, text: lines.joined(separator: "\n"))
    }

    func handleUsers(chatKey: ChatKey, fromUser: TelegramUser?) async throws {
        let isSuperAdmin = await self.isSuperAdmin(fromUser)
        // `chatOwnership` stores a UserKey (`#12345`), so a raw handle would
        // never match and the licence owner would see an empty list. Filtering
        // is off entirely for a super-admin (nil = every chat).
        let ownerFilter: UserKey? = isSuperAdmin ? nil : await ownerKey(for: fromUser)
        let privates = await state.privateChats(ownedBy: ownerFilter)

        if privates.isEmpty {
            try await sendUserFeedback(chatKey: chatKey, text: "В личке пока пусто.")
            return
        }

        let sorted = privates.sorted(by: { $0.chatID < $1.chatID })
        var list: [String] = []
        for entry in sorted.prefix(Self.listCap) {
            let label = await state.chatMeta(chatID: entry.chatID).map { " · \($0.displayLabel)" } ?? ""
            list.append("• <code>\(entry.chatID)</code>\(label)")
        }
        if sorted.count > Self.listCap {
            list.append("<i>…и ещё \(sorted.count - Self.listCap)</i>")
        }
        try await sendUserFeedback(chatKey: chatKey, text: """
            <b>👤 Пользователи в личке</b> (\(sorted.count))
            \(list.joined(separator: "\n"))

            <i>Открыть кому-то премиум в этом чате:</i> <code>/whitelist add &lt;номер&gt;</code>
            """)
    }

    func handlePresets(chatKey: ChatKey, argument: String) async throws {
        let parts = argument.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        let presetType = parts.first ?? ""
        let subcommand = parts.count > 1 ? parts[1] : ""
        let value = parts.count > 2 ? parts[2] : ""

        guard let category = PresetCategory(commandWord: presetType) else {
            try await sendUserFeedback(chatKey: chatKey, text: """
                <b>🎛 Заготовки для меню</b>

                <code>/presets &lt;тип&gt; add &lt;название&gt; | &lt;значение&gt;</code>
                <code>/presets &lt;тип&gt; remove &lt;value&gt;</code>
                <code>/presets &lt;тип&gt; list</code>

                <b>Типы:</b> <code>model</code>, <code>temp</code>, <code>history</code>, <code>role</code>

                <i>Пример:</i>
                <code>/presets model add GPT-4o | openai/gpt-4o</code>
                """)
            return
        }
        try await handlePresetsSub(
            chatKey: chatKey,
            category: category,
            subcommand: subcommand,
            value: value
        )
    }

    private func handlePresetsSub(
        chatKey: ChatKey,
        category: PresetCategory,
        subcommand: String,
        value: String
    ) async throws {
        let typeKey = category.rawValue
        let typeName = category.listName
        switch subcommand.lowercased() {
        case "add":
            let separator = value.contains("|") ? "|" : " ~ "
            let addParts = value
                .components(separatedBy: separator)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            guard addParts.count >= 2 else {
                try await sendUserFeedback(
                    chatKey: chatKey,
                    text: """
                    <i>Как пользоваться:</i> <code>/presets \(typeKey) add &lt;название&gt; | &lt;значение&gt;</code>
                    <i>Пример:</i> <code>/presets model add Gemini 3 Flash | google/gemini-3-flash-preview</code>
                    <i>Модель через конкретный сервис:</i> <code>/presets model add DeepSeek V4 | deepseek/deepseek-v4-pro | deepseek</code>
                    """
                )
                return
            }

            let display = addParts[0]
            let presetValue: String
            let presetProvider: String?
            if category == .model, addParts.count >= 3 {
                // Third part pins the OpenRouter upstream provider.
                presetValue = addParts[1]
                presetProvider = addParts[2]
            } else {
                presetValue = addParts.dropFirst().joined(separator: " ")
                presetProvider = nil
            }
            switch await state.addPreset(
                category: category,
                display: display,
                value: presetValue,
                provider: presetProvider,
                chatID: chatKey.chatID
            ) {
            case .added(let preset):
                let providerNote = preset.escapedProvider.map { " · <code>\($0)</code>" } ?? ""
                try await sendUserFeedback(
                    chatKey: chatKey,
                    text: "✓ Заготовка \(typeName): <b>\(preset.escapedDisplay)</b> → <code>\(preset.escapedValue)</code>\(providerNote)"
                )
            case .full:
                try await sendUserFeedback(chatKey: chatKey, text: Texts.presetListFull)
            }

        case "remove":
            guard !value.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Как пользоваться:</i> <code>/presets \(typeKey) remove &lt;значение&gt;</code>")
                return
            }
            let removed = await state.removePreset(category: category, value: value, chatID: chatKey.chatID)
            let shownValue = Preset.escapedForMessage(value)
            try await sendUserFeedback(
                chatKey: chatKey,
                text: removed
                    ? "✓ Заготовка \(typeName) <code>\(shownValue)</code> удалена."
                    : "Заготовка \(typeName) <code>\(shownValue)</code> не найдена."
            )

        case "list":
            let presets = await state.presets(for: category, chatID: chatKey.chatID)
            if presets.isEmpty {
                try await sendUserFeedback(chatKey: chatKey, text: "Заготовки \(typeName): пусто.")
            } else {
                var lines = ["<b>Заготовки \(typeName)</b> (\(presets.count))"]
                for (i, p) in presets.enumerated() {
                    let providerNote = p.escapedProvider.map { " · <code>\($0)</code>" } ?? ""
                    lines.append("\(i). <b>\(p.escapedDisplay)</b> → <code>\(p.escapedValue)</code>\(providerNote)")
                }
                try await sendUserFeedback(chatKey: chatKey, text: lines.joined(separator: "\n"))
            }

        default:
            try await sendUserFeedback(chatKey: chatKey, text: """
                <b>📋 Заготовки \(typeName)</b>
                <code>/presets \(typeKey) add &lt;название&gt; | &lt;значение&gt;</code>
                <code>/presets \(typeKey) remove &lt;значение&gt;</code>
                <code>/presets \(typeKey) list</code>
                """)
        }
    }
}
