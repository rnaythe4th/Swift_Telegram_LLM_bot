import Foundation

final class BotCommandHandler: @unchecked Sendable {
    private let telegram: TelegramGatewayPort
    private let state: ChatContextStore
    private let gateways: ProviderGatewayRegistry
    private let botUsername: String
    private let formatOptions: String
    private let menuHandler: BotMenuHandler
    private let modelPriceMonitor: ModelPriceMonitor?

    init(
        telegram: TelegramGatewayPort,
        state: ChatContextStore,
        gateways: ProviderGatewayRegistry,
        botUsername: String,
        formatOptions: String,
        menuHandler: BotMenuHandler,
        modelPriceMonitor: ModelPriceMonitor? = nil
    ) {
        self.telegram = telegram
        self.state = state
        self.gateways = gateways
        self.botUsername = botUsername
        self.formatOptions = formatOptions
        self.menuHandler = menuHandler
        self.modelPriceMonitor = modelPriceMonitor
    }

    func handleIfCommand(text: String?, chatKey: ChatKey, fromUser: TelegramUser?) async throws -> Bool {
        guard let text else {
            return false
        }

        let parsed = ParsedBotCommand.parse(
            from: text,
            botUsername: botUsername,
            suffix: await state.suffix(chatKey: chatKey)
        )

        guard parsed.name != .unknown, parsed.name != .mention else {
            return false
        }

        try await handle(parsed, chatKey: chatKey, fromUser: fromUser)
        return true
    }

    private func isSuperAdmin(_ user: TelegramUser?) async -> Bool {
        await state.isSuperAdmin(username: user?.username)
    }

    private func isAdmin(_ user: TelegramUser?, chatID: Int) async -> Bool {
        await state.isAdmin(username: user?.username, chatID: chatID)
    }

    private func requireAdmin(_ user: TelegramUser?, chatKey: ChatKey) async throws -> Bool {
        guard await isAdmin(user, chatID: chatKey.chatID) else {
            try await sendUserFeedback(chatKey: chatKey, text: "🔒 Команда только для администратора.")
            return false
        }
        return true
    }

    private func handle(_ parsed: ParsedBotCommand, chatKey: ChatKey, fromUser: TelegramUser?) async throws {
        switch parsed.name {
        case .whitelist:
            guard try await requireAdmin(fromUser, chatKey: chatKey) else { return }
            try await handleWhitelist(chatKey: chatKey, argument: parsed.argument)

        case .defaults:
            guard try await requireAdmin(fromUser, chatKey: chatKey) else { return }
            try await handleDefaults(chatKey: chatKey, argument: parsed.argument)

        case .chats:
            guard try await requireAdmin(fromUser, chatKey: chatKey) else { return }
            try await handleChats(chatKey: chatKey, fromUser: fromUser)

        case .users:
            guard try await requireAdmin(fromUser, chatKey: chatKey) else { return }
            try await handleUsers(chatKey: chatKey, fromUser: fromUser)

        case .presets:
            guard try await requireAdmin(fromUser, chatKey: chatKey) else { return }
            try await handlePresets(chatKey: chatKey, argument: parsed.argument)

        case .tenant:
            guard await isSuperAdmin(fromUser) else {
                try await sendUserFeedback(chatKey: chatKey, text: "🔒 Команда только для суперадминистратора.")
                return
            }
            try await handleTenant(chatKey: chatKey, argument: parsed.argument)

        case .buy:
            try await handleBuy(chatKey: chatKey, fromUser: fromUser)

        case .start:
            try await handleStart(chatKey: chatKey)

        case .setRole:
            let trimmed = parsed.argument.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: """
                    🎭 Укажите текст роли.
                    <i>Пример:</i> <code>/setrole Ты — эксперт по математике, отвечай кратко.</code>
                    """)
                return
            }
            _ = await state.setRoleAndResetHistory(chatKey: chatKey, role: trimmed + formatOptions)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Роль обновлена. История очищена.")

        case .clearHistory:
            await state.clearHistory(chatKey: chatKey)
            try await sendUserFeedback(chatKey: chatKey, text: "🧹 История очищена.")

        case .setTemp:
            guard let temp = Float(parsed.argument), (0.0...2.0).contains(temp) else {
                let hint = "<i>Нужно число от 0.0 до 2.0.</i>\n<i>Пример:</i> <code>/settemp 1.0</code>"
                try await sendUserFeedback(chatKey: chatKey, text: hint)
                return
            }
            await state.setTemperature(chatKey: chatKey, value: temp)
            let bucket = BotMenuHandler.tempBucket(temp)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Темп: <b>\(BotMenuHandler.formatTemp(temp))</b> — \(bucket)")

        case .model:
            let trimmed = parsed.argument.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: """
                    🤖 Укажите модель.
                    <i>Пример:</i> <code>/model openai/gpt-4o</code>
                    Готовые варианты — /menu → Модель
                    """)
                return
            }
            let hasAccess = await state.hasFullModelAccess(username: fromUser?.username)
            let effectiveFree = await state.effectiveFreeModelIDs()
            if !hasAccess, let eff = effectiveFree, !eff.contains(trimmed) {
                let price = await state.starsPrice()
                let buyHint = price.map { "\n\nКупить полный доступ (\($0) ⭐): /buy" } ?? "\n\nОформите полный доступ: /buy"
                try await sendUserFeedback(chatKey: chatKey, text: "⭐ <b>\(trimmed)</b> — модель с полным доступом.\(buyHint)")
                return
            }
            let changed = await state.setModelAndResetHistory(chatKey: chatKey, newModel: trimmed)
            if modelPriceMonitor != nil {
                await modelPriceMonitor?.refreshPricesIfNeeded(for: trimmed)
            }
            var priceNote = ""
            if let price = await state.openRouterModelPrice(for: trimmed) {
                let inP = BotMenuHandler.formatPriceM(price.inputPerToken)
                let outP = BotMenuHandler.formatPriceM(price.outputPerToken)
                priceNote = "\n⬇️$\(inP)/M · ⬆️$\(outP)/M"
            }
            try await sendUserFeedback(chatKey: chatKey, text: """
                ✓ Модель: <code>\(changed.new)</code>
                <i>Была:</i> <code>\(changed.old)</code>
                История очищена.\(priceNote)
                """)

        case .showTokens:
            let new = await state.toggleShowStats(chatKey: chatKey)
            try await sendUserFeedback(chatKey: chatKey, text: "📊 Показ токенов · <b>\(onOff(new))</b>")

        case .showCost:
            let new = await state.toggleShowCost(chatKey: chatKey)
            try await sendUserFeedback(chatKey: chatKey, text: "💵 Показ стоимости · <b>\(onOff(new))</b>")

        case .showModel:
            let new = await state.toggleShowModel(chatKey: chatKey)
            try await sendUserFeedback(chatKey: chatKey, text: "🤖 Показ модели · <b>\(onOff(new))</b>")

        case .backupNotify:
            let new = await state.toggleBackupNotify(chatKey: chatKey)
            try await sendUserFeedback(chatKey: chatKey, text: "💾 Уведомления о бэкапе · <b>\(onOff(new))</b>")

        case .help:
            let help = await state.fetchHelp(chatKey: chatKey)
            let isAdminUser = await isAdmin(fromUser, chatID: chatKey.chatID)
            let markup = InlineKeyboardMarkup(inline_keyboard: [
                [InlineKeyboardButton(text: "⚙️ Открыть меню", callback_data: BotCallbackAction.menu(action: "open").rawData)],
                [InlineKeyboardButton(text: "📘 Полная инструкция", callback_data: BotCallbackAction.faq.rawData)],
            ])
            _ = try await telegram.sendMessage(.init(
                chatID: chatKey.chatID,
                threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                replyTo: nil,
                text: formatHelp(help, isAdmin: isAdminUser),
                replyMarkup: markup
            ))

        case .faq:
            try await sendUserFeedback(chatKey: chatKey, text: BotCallbackHandler.faqText)

        case .defaultRole:
            let defaultRole = await state.defaultRole(chatID: chatKey.chatID)
            _ = await state.setRoleAndResetHistory(chatKey: chatKey, role: defaultRole)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Роль сброшена к стандартной. История очищена.")

        case .historyLength:
            guard let newMax = Int(parsed.argument), (1...50).contains(newMax) else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Нужно число от 1 до 50.</i>\n<i>Пример:</i> <code>/historylength 11</code>")
                return
            }
            await state.setMaxHistory(chatKey: chatKey, newMax: newMax)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Длина истории: <b>\(newMax) сообщ.</b>")

        case .provider:
            if let provider = ServiceProvider.parse(parsed.argument) {
                let old = await state.changeProvider(chatKey: chatKey, newProvider: provider)
                var lines = ["✓ Провайдер: <b>\(provider.commandValue)</b>"]
                if old != provider {
                    lines.append("<i>Был:</i> <b>\(old.commandValue)</b>")
                }

                let gateway = try gateways.gateway(for: provider)
                let reasoningEnabled = await state.reasoningEnabled(chatKey: chatKey)
                if reasoningEnabled, !gateway.capabilities.supportsReasoning {
                    await state.setReasoningEffort(chatKey: chatKey, effort: nil)
                    lines.append("<i>Reasoning отключён — провайдер не поддерживает.</i>")
                }
                try await sendUserFeedback(chatKey: chatKey, text: lines.joined(separator: "\n"))
            } else {
                try await sendUserFeedback(chatKey: chatKey, text: "Неизвестный провайдер. Доступны: <code>deepseek</code>, <code>openrouter</code>, <code>yandex</code>.")
            }

        case .testMode:
            let suffix = await state.toggleTestMode(chatKey: chatKey)
            if let suffix {
                try await sendUserFeedback(chatKey: chatKey, text: """
                    🧪 <b>Тест-режим включён.</b>
                    Суффикс · <code>\(suffix)</code>

                    Используйте суффикс с командами:
                    <code>/help\(suffix)</code>
                    <code>/setrole\(suffix) Ты — Дональд Трамп.</code>
                    """)
            } else {
                try await sendUserFeedback(chatKey: chatKey, text: "🧪 Тест-режим выключен.")
            }

        case .reasoning:
            let provider = await state.provider(chatKey: chatKey)
            let gateway = try gateways.gateway(for: provider)

            guard gateway.capabilities.supportsReasoning else {
                try await sendUserFeedback(
                    chatKey: chatKey,
                    text: "🧠 Провайдер <b>\(provider.commandValue)</b> не поддерживает reasoning."
                )
                return
            }

            let arg = parsed.argument.trimmingCharacters(in: .whitespaces).lowercased()
            if let effort = ReasoningEffort(rawValue: arg) {
                await state.setReasoningEffort(chatKey: chatKey, effort: effort)
            } else if arg == "off" || arg == "выкл" {
                await state.setReasoningEffort(chatKey: chatKey, effort: nil)
            } else if arg.isEmpty {
                _ = await state.toggleReasoning(chatKey: chatKey)
            } else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/reasoning low|medium|high|off</code>")
                return
            }
            let current = await state.reasoningEffort(chatKey: chatKey)
            try await sendUserFeedback(chatKey: chatKey, text: "🧠 Reasoning · <b>\(current?.rawValue ?? "выкл")</b>")

        case .menu:
            await menuHandler.sendMenu(chatKey: chatKey, username: fromUser?.username)

        case .reset:
            await state.resetChat(chatKey: chatKey)
            try await sendUserFeedback(chatKey: chatKey, text: "↺ Настройки сброшены к стандартным.")

        case .history:
            try await handleHistory(chatKey: chatKey)

        case .mention, .unknown:
            return
        }
    }

    private func handleStart(chatKey: ChatKey) async throws {
        let text = """
        <b>👋 Привет!</b>

        Я — ИИ-ассистент в Telegram. Просто напишите — отвечу.

        <b>Умею:</b>
        • Отвечать на вопросы, помогать и рассуждать
        • Понимать картинки, голосовые и видео
        • Помнить контекст разговора
        • Работать с GPT, Claude, Gemini, DeepSeek и другими

        <b>Быстрый старт:</b>
        ⚙️ /menu — все настройки
        📘 /faq — полная инструкция
        🎭 /setrole — задать характер бота
        ↺ /reset — сбросить к стандарту
        """
        let markup = InlineKeyboardMarkup(inline_keyboard: [
            [InlineKeyboardButton(text: "⚙️ Открыть меню", callback_data: BotCallbackAction.menu(action: "open").rawData)],
            [InlineKeyboardButton(text: "📘 Инструкция", callback_data: BotCallbackAction.faq.rawData)],
        ])
        _ = try await telegram.sendMessage(.init(
            chatID: chatKey.chatID,
            threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
            replyTo: nil,
            text: text,
            replyMarkup: markup
        ))
    }

    private func formatHelp(_ help: HelpData, isAdmin: Bool) -> String {
        let reasoningLabel = help.reasoningEffort?.rawValue ?? "выкл"
        let suffix = help.testModeSuffix.map(String.init) ?? "выкл"
        let adminLine = isAdmin
            ? "\n<i>Вы администратор · /whitelist /defaults /presets /chats /users</i>"
            : ""
        return """
        <b>⚙️ Настройки чата</b>

        🔌 Провайдер · <b>\(help.provider.commandValue)</b>
        🤖 Модель · <code>\(help.model)</code>
        🌡 Темп · <b>\(BotMenuHandler.formatTemp(help.temp))</b> — \(BotMenuHandler.tempBucket(help.temp))
        📝 История · <b>\(help.maxHistory) сообщ.</b>
        🧠 Reasoning · <b>\(reasoningLabel)</b>

        <b>Показ в ответе:</b>
        \(yesNo(help.showTokens)) Токены
        \(yesNo(help.showCost)) Стоимость
        \(yesNo(help.showModel)) Модель
        \(yesNo(help.backupNotify)) Уведомления о бэкапе

        <b>🎭 Роль:</b>
        <blockquote expandable>\(help.role)</blockquote>

        <i>Тест-режим · \(suffix)</i>\(adminLine)
        """
    }

    private func yesNo(_ v: Bool) -> String { v ? "✓" : "·" }
    private func onOff(_ v: Bool) -> String { v ? "вкл" : "выкл" }

    private func handleWhitelist(chatKey: ChatKey, argument: String) async throws {
        let parts = argument.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        let subcommand = parts.first ?? ""
        let value = parts.count > 1 ? parts[1] : ""

        switch subcommand.lowercased() {
        case "add":
            guard let userID = Int(value) else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/whitelist add &lt;ID&gt;</code>")
                return
            }
            await state.addToWhitelist(userID: userID, chatID: chatKey.chatID)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Пользователь <code>\(userID)</code> добавлен в белый список.")

        case "remove":
            guard let userID = Int(value) else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/whitelist remove &lt;ID&gt;</code>")
                return
            }
            await state.removeFromWhitelist(userID: userID, chatID: chatKey.chatID)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Пользователь <code>\(userID)</code> удалён из белого списка.")

        case "list":
            let ids = await state.listWhitelisted(chatID: chatKey.chatID)
            if ids.isEmpty {
                try await sendUserFeedback(chatKey: chatKey, text: "Белый список пуст.")
            } else {
                let sorted = ids.sorted()
                let list = sorted.map { "• <code>\($0)</code>" }.joined(separator: "\n")
                try await sendUserFeedback(chatKey: chatKey, text: "<b>Белый список</b> (\(sorted.count))\n\(list)")
            }

        default:
            try await sendUserFeedback(chatKey: chatKey, text: """
                <b>/whitelist</b>
                <code>/whitelist add &lt;ID&gt;</code> — добавить
                <code>/whitelist remove &lt;ID&gt;</code> — удалить
                <code>/whitelist list</code> — показать
                """)
        }
    }

    private func handleDefaults(chatKey: ChatKey, argument: String) async throws {
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
                    try await sendUserFeedback(chatKey: chatKey, text: "Длина истории по умолчанию · <b>\(defs.historyLength)</b>")
                } else {
                    try await sendUserFeedback(chatKey: chatKey, text: "<i>Нужно число от 1 до 50.</i>\n<i>Пример:</i> <code>/defaults historylength 11</code>")
                }
                return
            }
            let new = await state.setDefaultHistoryLength(length, chatID: chatKey.chatID)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Длина истории по умолчанию · <b>\(new)</b>")

        default:
            let defs = await state.getDefaults(chatID: chatKey.chatID)
            try await sendUserFeedback(chatKey: chatKey, text: """
                <b>⚙️ Значения по умолчанию</b>

                🤖 Модель · <code>\(defs.model)</code>
                📝 История · <b>\(defs.historyLength) сообщ.</b>
                🎭 Роль:
                <blockquote expandable>\(defs.role)</blockquote>

                <b>Команды:</b>
                <code>/defaults model &lt;id&gt;</code>
                <code>/defaults role &lt;текст&gt;</code>
                <code>/defaults historylength &lt;1–50&gt;</code>

                <i>Управление пресетами меню — /presets</i>
                """)
        }
    }

    private func handleChats(chatKey: ChatKey, fromUser: TelegramUser?) async throws {
        let isSuperAdmin = await self.isSuperAdmin(fromUser)
        let ownerFilter: String? = isSuperAdmin ? nil : fromUser?.username?.lowercased()
        let groups = await state.groupChats(ownedBy: ownerFilter)
        let privates = await state.privateChats(ownedBy: ownerFilter)

        var lines: [String] = []

        lines.append("<b>👥 Групповые чаты</b> (\(groups.count))")
        if groups.isEmpty {
            lines.append("<i>нет</i>")
        } else {
            for (chatID, threadID) in groups.sorted(by: { $0.chatID < $1.chatID }) {
                let threadInfo = threadID != 0 ? " · thread \(threadID)" : ""
                lines.append("• <code>\(chatID)</code>\(threadInfo)")
            }
        }

        lines.append("")
        lines.append("<b>👤 Личные чаты</b> (\(privates.count))")
        if privates.isEmpty {
            lines.append("<i>нет</i>")
        } else {
            for (chatID, threadID) in privates.sorted(by: { $0.chatID < $1.chatID }) {
                let threadInfo = threadID != 0 ? " · thread \(threadID)" : ""
                lines.append("• <code>\(chatID)</code>\(threadInfo)")
            }
        }

        try await sendUserFeedback(chatKey: chatKey, text: lines.joined(separator: "\n"))
    }

    private func handleUsers(chatKey: ChatKey, fromUser: TelegramUser?) async throws {
        let isSuperAdmin = await self.isSuperAdmin(fromUser)
        let ownerFilter: String? = isSuperAdmin ? nil : fromUser?.username?.lowercased()
        let privates = await state.privateChats(ownedBy: ownerFilter)

        if privates.isEmpty {
            try await sendUserFeedback(chatKey: chatKey, text: "В личке пока пусто.")
            return
        }

        let sorted = privates.sorted(by: { $0.chatID < $1.chatID })
        let list = sorted.map { "• <code>\($0.chatID)</code>" }.joined(separator: "\n")
        try await sendUserFeedback(chatKey: chatKey, text: """
            <b>👤 Пользователи в личке</b> (\(sorted.count))
            \(list)

            <i>Добавить в whitelist:</i> <code>/whitelist add &lt;ID&gt;</code>
            """)
    }

    private func handlePresets(chatKey: ChatKey, argument: String) async throws {
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
                add: { [self] display, val in await state.addModelPreset(display: display, value: val, chatID: chatKey.chatID) },
                remove: { [self] val in await state.removeModelPreset(value: val, chatID: chatKey.chatID) }
            )

        case "temp":
            try await handlePresetsSub(
                chatKey: chatKey,
                subcommand: subcommand,
                value: value,
                typeKey: "temp",
                typeName: "температуры",
                list: { [self] in await state.tempPresets(chatID: chatKey.chatID) },
                add: { [self] display, val in await state.addTempPreset(display: display, value: val, chatID: chatKey.chatID) },
                remove: { [self] val in await state.removeTempPreset(value: val, chatID: chatKey.chatID) }
            )

        case "history", "historylength":
            try await handlePresetsSub(
                chatKey: chatKey,
                subcommand: subcommand,
                value: value,
                typeKey: "history",
                typeName: "длины истории",
                list: { [self] in await state.historyLengthPresets(chatID: chatKey.chatID) },
                add: { [self] display, val in await state.addHistoryLengthPreset(display: display, value: val, chatID: chatKey.chatID) },
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
                add: { [self] display, val in await state.addRolePreset(display: display, value: val, chatID: chatKey.chatID) },
                remove: { [self] val in await state.removeRolePreset(value: val, chatID: chatKey.chatID) }
            )

        default:
            try await sendUserFeedback(chatKey: chatKey, text: """
                <b>🎛 Пресеты меню</b>

                <code>/presets &lt;тип&gt; add &lt;label&gt; | &lt;value&gt;</code>
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
        add: @Sendable (String, String) async -> Preset,
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
                    <i>Использование:</i> <code>/presets \(typeKey) add &lt;label&gt; | &lt;value&gt;</code>
                    <i>Пример:</i> <code>/presets model add Gemini 3 Flash | google/gemini-3-flash-preview</code>
                    """
                )
                return
            }

            let display = addParts[0]
            let presetValue = addParts.dropFirst().joined(separator: " ")
            let preset = await add(display, presetValue)
            try await sendUserFeedback(
                chatKey: chatKey,
                text: "✓ Пресет \(typeName): <b>\(preset.display)</b> → <code>\(preset.value)</code>"
            )

        case "remove":
            guard !value.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/presets \(typeKey) remove &lt;value&gt;</code>")
                return
            }
            let removed = await remove(value)
            try await sendUserFeedback(
                chatKey: chatKey,
                text: removed
                    ? "✓ Пресет \(typeName) <code>\(value)</code> удалён."
                    : "Пресет \(typeName) <code>\(value)</code> не найден."
            )

        case "list":
            let presets = await list()
            if presets.isEmpty {
                try await sendUserFeedback(chatKey: chatKey, text: "Пресеты \(typeName): пусто.")
            } else {
                var lines = ["<b>Пресеты \(typeName)</b> (\(presets.count))"]
                for (i, p) in presets.enumerated() {
                    lines.append("\(i). <b>\(p.display)</b> → <code>\(p.value)</code>")
                }
                try await sendUserFeedback(chatKey: chatKey, text: lines.joined(separator: "\n"))
            }

        default:
            try await sendUserFeedback(chatKey: chatKey, text: """
                <b>/presets \(typeKey)</b>
                <code>/presets \(typeKey) add &lt;label&gt; | &lt;value&gt;</code>
                <code>/presets \(typeKey) remove &lt;value&gt;</code>
                <code>/presets \(typeKey) list</code>
                """)
        }
    }

    private func handleTenant(chatKey: ChatKey, argument: String) async throws {
        let parts = argument.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        let subcommand = parts.first ?? ""
        let arg1 = parts.count > 1 ? parts[1] : ""
        let arg2 = parts.count > 2 ? parts[2] : ""

        func normalizeUsername(_ raw: String) -> String {
            raw.hasPrefix("@") ? String(raw.dropFirst()) : raw
        }

        switch subcommand.lowercased() {
        case "add":
            let username = normalizeUsername(arg1)
            guard !username.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant add @username</code>")
                return
            }
            await state.registerTenant(username: username)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Tenant @\(username) зарегистрирован.")

        case "remove":
            let username = normalizeUsername(arg1)
            guard !username.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant remove @username</code>")
                return
            }
            let removed = await state.removeTenant(username: username)
            try await sendUserFeedback(chatKey: chatKey, text: removed
                ? "✓ Tenant @\(username) удалён."
                : "Tenant @\(username) не найден или является владельцем.")

        case "list":
            let tenants = await state.listTenants()
            if tenants.isEmpty {
                try await sendUserFeedback(chatKey: chatKey, text: "Tenants: пусто.")
            } else {
                let list = tenants.map { "• @\($0)" }.joined(separator: "\n")
                try await sendUserFeedback(chatKey: chatKey, text: "<b>🏢 Tenants</b> (\(tenants.count))\n\(list)")
            }

        case "assign":
            let username = normalizeUsername(arg1)
            guard !username.isEmpty, let chatID = Int(arg2) else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant assign @username &lt;chatID&gt;</code>")
                return
            }
            let ok = await state.assignChat(chatID: chatID, to: username)
            try await sendUserFeedback(chatKey: chatKey, text: ok
                ? "✓ Chat <code>\(chatID)</code> назначен @\(username)."
                : "Tenant @\(username) не найден.")

        case "freemodels":
            try await handleFreeModels(chatKey: chatKey, subcommand: arg1, value: arg2)

        case "price":
            if arg1.isEmpty {
                let price = await state.starsPrice()
                if let price {
                    try await sendUserFeedback(chatKey: chatKey, text: "💫 Цена доступа: <b>\(price) Stars</b>")
                } else {
                    try await sendUserFeedback(chatKey: chatKey, text: "💫 Продажа доступа отключена.")
                }
            } else if arg1 == "0" || arg1.lowercased() == "off" {
                await state.setStarsPrice(nil)
                try await sendUserFeedback(chatKey: chatKey, text: "✓ Продажа доступа отключена.")
            } else if let price = Int(arg1), price > 0 {
                await state.setStarsPrice(price)
                try await sendUserFeedback(chatKey: chatKey, text: "✓ Цена доступа: <b>\(price) Stars</b>")
            } else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant price &lt;число&gt;</code> или <code>/tenant price 0</code> (отключить)")
            }

        default:
            try await sendUserFeedback(chatKey: chatKey, text: """
                <b>🏢 Управление tenants</b>

                <code>/tenant add @username</code> — зарегистрировать
                <code>/tenant remove @username</code> — удалить
                <code>/tenant list</code> — список
                <code>/tenant assign @username &lt;chatID&gt;</code> — назначить чат
                <code>/tenant price &lt;число&gt;</code> — цена доступа в Stars (0 = отключить)
                <code>/tenant freemodels add &lt;id&gt;</code> — добавить бесплатную модель
                <code>/tenant freemodels remove &lt;id&gt;</code> — удалить
                <code>/tenant freemodels list</code> — список (пусто = все бесплатны)
                <code>/tenant freemodels available</code> — бесплатные модели OpenRouter сейчас
                """)
        }
    }

    private func handleFreeModels(chatKey: ChatKey, subcommand: String, value: String) async throws {
        switch subcommand.lowercased() {
        case "add":
            let id = value.trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant freemodels add &lt;model-id&gt;</code>")
                return
            }
            let added = await state.addFreeModel(id)
            try await sendUserFeedback(chatKey: chatKey, text: added
                ? "✓ Бесплатная модель добавлена: <code>\(id)</code>"
                : "Модель <code>\(id)</code> уже в списке.")

        case "remove":
            let id = value.trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant freemodels remove &lt;model-id&gt;</code>")
                return
            }
            let removed = await state.removeFreeModel(id)
            try await sendUserFeedback(chatKey: chatKey, text: removed
                ? "✓ Модель <code>\(id)</code> удалена из бесплатных."
                : "Модель <code>\(id)</code> не найдена в списке.")

        case "list":
            let ids = await state.freeModelIDs()
            if ids.isEmpty {
                try await sendUserFeedback(chatKey: chatKey, text: "💡 Список бесплатных моделей пуст — все модели доступны всем.")
            } else {
                let list = ids.enumerated().map { "\($0.offset + 1). <code>\($0.element)</code>" }.joined(separator: "\n")
                try await sendUserFeedback(chatKey: chatKey, text: "<b>Бесплатные модели</b> (\(ids.count))\n\(list)")
            }

        case "available":
            guard let monitor = modelPriceMonitor else {
                try await sendUserFeedback(chatKey: chatKey, text: "⚠️ Мониторинг моделей недоступен.")
                return
            }
            try await sendUserFeedback(chatKey: chatKey, text: "⏳ Запрашиваю список бесплатных моделей OpenRouter…")
            let freeModels = try await monitor.fetchCurrentFreeModels()
            if freeModels.isEmpty {
                try await sendUserFeedback(chatKey: chatKey, text: "Бесплатных моделей на OpenRouter сейчас нет.")
            } else {
                let list = freeModels.map { "• <code>\($0.id)</code>" }.joined(separator: "\n")
                try await sendUserFeedback(chatKey: chatKey, text: "<b>🆓 Бесплатные модели OpenRouter сейчас</b> (\(freeModels.count))\n\(list)")
            }

        default:
            let ids = await state.freeModelIDs()
            let status = ids.isEmpty
                ? "<i>Список пуст — все модели доступны всем.</i>"
                : ids.map { "• <code>\($0)</code>" }.joined(separator: "\n")
            try await sendUserFeedback(chatKey: chatKey, text: """
                <b>🆓 Бесплатные модели</b>

                \(status)

                <code>/tenant freemodels add &lt;id&gt;</code>
                <code>/tenant freemodels remove &lt;id&gt;</code>
                <code>/tenant freemodels list</code>
                <code>/tenant freemodels available</code> — актуальный список от OpenRouter
                """)
        }
    }

    private func handleBuy(chatKey: ChatKey, fromUser: TelegramUser?) async throws {
        guard let price = await state.starsPrice(), price > 0 else {
            try await sendUserFeedback(chatKey: chatKey, text: "ℹ️ Продажа доступа сейчас недоступна.")
            return
        }
        guard let username = fromUser?.username else {
            try await sendUserFeedback(chatKey: chatKey, text: """
                ⚠️ <b>Для покупки нужен username в Telegram.</b>

                Установите @username в настройках Telegram и попробуйте снова.
                """)
            return
        }
        if await state.isTenant(username: username) {
            try await sendUserFeedback(chatKey: chatKey, text: "✅ У вас уже есть доступ к боту.")
            return
        }
        try await telegram.sendInvoice(.init(
            chatID: chatKey.chatID,
            title: "Доступ к боту",
            description: "Персональная копия ИИ-бота — единоразовая покупка",
            payload: "buy_access",
            starsAmount: price
        ))
    }

    private func handleHistory(chatKey: ChatKey) async throws {
        let messages = await state.history(chatKey: chatKey)
        guard !messages.isEmpty else {
            try await sendUserFeedback(chatKey: chatKey, text: "📝 История пуста.")
            return
        }

        var lines: [String] = ["<b>📝 История</b> (\(messages.count))"]
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

    private func sendUserFeedback(chatKey: ChatKey, text: String) async throws {
        _ = try await telegram.sendMessage(
            .init(
                chatID: chatKey.chatID,
                threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                replyTo: nil,
                text: text,
                replyMarkup: nil
            )
        )
    }
}
