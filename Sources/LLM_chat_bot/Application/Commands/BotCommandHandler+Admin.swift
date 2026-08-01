import Foundation

// Tenant-owner tooling: whitelist, defaults, chat and user listings, presets.

extension BotCommandHandler {
    func handleWhitelist(chatKey: ChatKey, argument: String) async throws {
        let parts = argument.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        let subcommand = parts.first ?? ""
        let value = parts.count > 1 ? parts[1] : ""

        switch subcommand.lowercased() {
        case "add":
            guard let userID = Int(value) else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Как пользоваться:</i> <code>/whitelist add &lt;номер пользователя&gt;</code>")
                return
            }
            await state.addToWhitelist(userID: userID, chatID: chatKey.chatID)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Пользователь <code>\(userID)</code> добавлен в гости этого чата — ваш премиум работает и для него.")

        case "remove":
            guard let userID = Int(value) else {
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
                try await sendUserFeedback(chatKey: chatKey, text: "Модель по умолчанию · <code>\(defs.model)</code>")
                return
            }
            let new = await state.setDefaultModel(value, chatID: chatKey.chatID)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Модель по умолчанию · <code>\(new)</code>")

        case "role":
            guard !value.isEmpty else {
                let defs = await state.getDefaults(chatID: chatKey.chatID)
                try await sendUserFeedback(chatKey: chatKey, text: "Роль по умолчанию:\n<blockquote expandable>\(defs.role)</blockquote>")
                return
            }
            let new = await state.setDefaultRole(value, chatID: chatKey.chatID)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Роль по умолчанию обновлена:\n<blockquote expandable>\(new)</blockquote>")

        case "historylength":
            guard !value.isEmpty, let length = Int(value), (1...50).contains(length) else {
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

                🤖 Модель · <code>\(defs.model)</code>
                📝 Память · <b>\(defs.historyLength) сообщ.</b>
                🎭 Роль:
                <blockquote expandable>\(defs.role)</blockquote>

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
            for (chatID, threadID) in groups.sorted(by: { $0.chatID < $1.chatID }) {
                let threadInfo = threadID != 0 ? " · thread \(threadID)" : ""
                let label = await state.chatMeta(chatID: chatID).map { " · \($0.displayLabel)" } ?? ""
                lines.append("• <code>\(chatID)</code>\(threadInfo)\(label)")
            }
        }

        lines.append("")
        lines.append("<b>👤 Личные чаты</b> (\(privates.count))")
        if privates.isEmpty {
            lines.append("<i>нет</i>")
        } else {
            for (chatID, threadID) in privates.sorted(by: { $0.chatID < $1.chatID }) {
                let threadInfo = threadID != 0 ? " · thread \(threadID)" : ""
                let label = await state.chatMeta(chatID: chatID).map { " · \($0.displayLabel)" } ?? ""
                lines.append("• <code>\(chatID)</code>\(threadInfo)\(label)")
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
        for entry in sorted {
            let label = await state.chatMeta(chatID: entry.chatID).map { " · \($0.displayLabel)" } ?? ""
            list.append("• <code>\(entry.chatID)</code>\(label)")
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

        switch presetType.lowercased() {
        case "model":
            try await handlePresetsSub(
                chatKey: chatKey,
                subcommand: subcommand,
                value: value,
                typeKey: "model",
                typeName: "моделей",
                list: { [self] in await state.modelPresets(chatID: chatKey.chatID) },
                add: { [self] display, val, provider in await state.addModelPreset(display: display, value: val, provider: provider, chatID: chatKey.chatID) },
                remove: { [self] val in await state.removeModelPreset(value: val, chatID: chatKey.chatID) }
            )

        case "temp":
            try await handlePresetsSub(
                chatKey: chatKey,
                subcommand: subcommand,
                value: value,
                typeKey: "temp",
                typeName: "стиля ответа",
                list: { [self] in await state.tempPresets(chatID: chatKey.chatID) },
                add: { [self] display, val, _ in await state.addTempPreset(display: display, value: val, chatID: chatKey.chatID) },
                remove: { [self] val in await state.removeTempPreset(value: val, chatID: chatKey.chatID) }
            )

        case "history", "historylength":
            try await handlePresetsSub(
                chatKey: chatKey,
                subcommand: subcommand,
                value: value,
                typeKey: "history",
                typeName: "памяти",
                list: { [self] in await state.historyLengthPresets(chatID: chatKey.chatID) },
                add: { [self] display, val, _ in await state.addHistoryLengthPreset(display: display, value: val, chatID: chatKey.chatID) },
                remove: { [self] val in await state.removeHistoryLengthPreset(value: val, chatID: chatKey.chatID) }
            )

        case "role":
            try await handlePresetsSub(
                chatKey: chatKey,
                subcommand: subcommand,
                value: value,
                typeKey: "role",
                typeName: "ролей",
                list: { [self] in await state.rolePresets(chatID: chatKey.chatID) },
                add: { [self] display, val, _ in await state.addRolePreset(display: display, value: val, chatID: chatKey.chatID) },
                remove: { [self] val in await state.removeRolePreset(value: val, chatID: chatKey.chatID) }
            )

        default:
            try await sendUserFeedback(chatKey: chatKey, text: """
                <b>🎛 Заготовки для меню</b>

                <code>/presets &lt;тип&gt; add &lt;название&gt; | &lt;значение&gt;</code>
                <code>/presets &lt;тип&gt; remove &lt;value&gt;</code>
                <code>/presets &lt;тип&gt; list</code>

                <b>Типы:</b> <code>model</code>, <code>temp</code>, <code>history</code>, <code>role</code>

                <i>Пример:</i>
                <code>/presets model add GPT-4o | openai/gpt-4o</code>
                """)
        }
    }

    private func handlePresetsSub(
        chatKey: ChatKey,
        subcommand: String,
        value: String,
        typeKey: String,
        typeName: String,
        list: @Sendable () async -> [Preset],
        add: @Sendable (String, String, String?) async -> Preset,
        remove: @Sendable (String) async -> Bool
    ) async throws {
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
            if typeKey == "model", addParts.count >= 3 {
                // Third part pins the OpenRouter upstream provider.
                presetValue = addParts[1]
                presetProvider = addParts[2]
            } else {
                presetValue = addParts.dropFirst().joined(separator: " ")
                presetProvider = nil
            }
            let preset = await add(display, presetValue, presetProvider)
            let providerNote = preset.provider.map { " · <code>\($0)</code>" } ?? ""
            try await sendUserFeedback(
                chatKey: chatKey,
                text: "✓ Заготовка \(typeName): <b>\(preset.display)</b> → <code>\(preset.value)</code>\(providerNote)"
            )

        case "remove":
            guard !value.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Как пользоваться:</i> <code>/presets \(typeKey) remove &lt;значение&gt;</code>")
                return
            }
            let removed = await remove(value)
            try await sendUserFeedback(
                chatKey: chatKey,
                text: removed
                    ? "✓ Заготовка \(typeName) <code>\(value)</code> удалена."
                    : "Заготовка \(typeName) <code>\(value)</code> не найдена."
            )

        case "list":
            let presets = await list()
            if presets.isEmpty {
                try await sendUserFeedback(chatKey: chatKey, text: "Заготовки \(typeName): пусто.")
            } else {
                var lines = ["<b>Заготовки \(typeName)</b> (\(presets.count))"]
                for (i, p) in presets.enumerated() {
                    let providerNote = p.provider.map { " · <code>\($0)</code>" } ?? ""
                    lines.append("\(i). <b>\(p.display)</b> → <code>\(p.value)</code>\(providerNote)")
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
