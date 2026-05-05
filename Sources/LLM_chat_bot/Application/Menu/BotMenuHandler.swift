import Foundation

private enum MenuPage: String {
    case main
    case role
    case model
    case temp
    case stats
    case history
    case provider
    case reasoning
    case helpPage = "help"
    case close
}

final class BotMenuHandler: @unchecked Sendable {
    private let telegram: TelegramGatewayPort
    private let state: ChatContextStore
    private let gateways: ProviderGatewayRegistry
    private let logger: LoggerPort
    private let formatOptions: String

    init(
        telegram: TelegramGatewayPort,
        state: ChatContextStore,
        gateways: ProviderGatewayRegistry,
        logger: LoggerPort,
        formatOptions: String
    ) {
        self.telegram = telegram
        self.state = state
        self.gateways = gateways
        self.logger = logger
        self.formatOptions = formatOptions
    }

    func handle(action rawAction: String, callback: CallbackQuery) async {
        guard let message = callback.message else {
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Сообщение недоступно")
            return
        }

        let chatKey = ChatKey(chatID: message.chat.id, threadID: message.message_thread_id ?? 0)
        let action = rawAction.isEmpty ? "open" : rawAction
        let parts = action.split(separator: ":", omittingEmptySubsequences: false).map(String.init)

        do {
            try await processAction(parts: parts, chatKey: chatKey, callback: callback, message: message)
        } catch {
            logger.error("menu action failed: \(error)")
            let alertText = UserFacingError.shortMessage(error, context: "Ошибка")
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: alertText)
        }
    }

    func sendMenu(chatKey: ChatKey) async {
        let (text, markup) = await renderPage(.main, chatKey: chatKey)
        _ = try? await telegram.sendMessage(
            .init(
                chatID: chatKey.chatID,
                threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                replyTo: nil,
                text: text,
                replyMarkup: markup
            )
        )
    }

    private func processAction(
        parts: [String],
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard let command = parts.first, !command.isEmpty else {
            try await showPage(.main, chatKey: chatKey, callback: callback, message: message)
            return
        }

        switch command {
        case "open":
            try await showPage(.main, chatKey: chatKey, callback: callback, message: message)

        case "close":
            try await closeMenu(callback: callback, message: message)

        case "nav":
            guard parts.count >= 2 else {
                try await showPage(.main, chatKey: chatKey, callback: callback, message: message)
                return
            }
            let page = parts[1].lowercased()
            guard let menuPage = MenuPage(rawValue: page) else {
                try await showPage(.main, chatKey: chatKey, callback: callback, message: message)
                return
            }
            try await showPage(menuPage, chatKey: chatKey, callback: callback, message: message)

        case "role":
            guard parts.count >= 2 else { return }
            if parts[1] == "default" {
                let defaultRole = await state.defaultRole(chatID: chatKey.chatID)
                _ = await state.setRoleAndResetHistory(chatKey: chatKey, role: defaultRole)
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Роль по умолчанию")
                try await showPage(.role, chatKey: chatKey, callback: callback, message: message)
                return
            } else if parts[1] == "select", parts.count >= 3, let index = Int(parts[2]) {
                let presets = await state.rolePresets()
                guard index >= 0, index < presets.count else {
                    try await telegram.answerCallback(callbackQueryID: callback.id, text: "Пресет не найден")
                    return
                }
                let roleValue = presets[index].value + formatOptions
                _ = await state.setRoleAndResetHistory(chatKey: chatKey, role: roleValue)
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Роль: \(presets[index].display)")
                try await showPage(.role, chatKey: chatKey, callback: callback, message: message)
                return
            }

        case "model":
            guard parts.count >= 3, parts[1] == "select" else { return }
            let model = parts[2]
            let presets = await state.modelPresets()
            guard let preset = presets.first(where: { $0.value == model }) else {
                try await telegram.answerCallback(callbackQueryID: callback.id, text: "Модель не найдена")
                return
            }
            _ = await state.setModelAndResetHistory(chatKey: chatKey, newModel: model)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Модель: \(preset.display)")
            try await showPage(.model, chatKey: chatKey, callback: callback, message: message)
            return

        case "temp":
            guard parts.count >= 2, let temp = Float(parts[1]), (0.0...2.0).contains(temp) else { return }
            await state.setTemperature(chatKey: chatKey, value: temp)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Темп: \(Self.formatTemp(temp))")
            try await showPage(.temp, chatKey: chatKey, callback: callback, message: message)
            return

        case "stats":
            guard parts.count >= 3, parts[1] == "toggle" else { return }
            switch parts[2] {
            case "tokens":
                _ = await state.toggleShowStats(chatKey: chatKey)
            case "cost":
                _ = await state.toggleShowCost(chatKey: chatKey)
            case "model":
                _ = await state.toggleShowModel(chatKey: chatKey)
            case "backup":
                _ = await state.toggleBackupNotify(chatKey: chatKey)
            default:
                break
            }
            try await showPage(.stats, chatKey: chatKey, callback: callback, message: message)
            return

        case "history":
            guard parts.count >= 2 else { return }
            if parts[1] == "clear" {
                await state.clearHistory(chatKey: chatKey)
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "История очищена")
                try await showPage(.history, chatKey: chatKey, callback: callback, message: message)
                return
            } else if parts.count >= 3, parts[1] == "length", let length = Int(parts[2]), (1...50).contains(length) {
                await state.setMaxHistory(chatKey: chatKey, newMax: length)
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Длина истории: \(length)")
                try await showPage(.history, chatKey: chatKey, callback: callback, message: message)
                return
            }

        case "provider":
            guard parts.count >= 2 else { return }
            if let provider = ServiceProvider.parse(parts[1]) {
                _ = await state.changeProvider(chatKey: chatKey, newProvider: provider)
                let gateway = try gateways.gateway(for: provider)
                if await state.reasoningEnabled(chatKey: chatKey), !gateway.capabilities.supportsReasoning {
                     await state.setReasoningEffort(chatKey: chatKey, effort: nil)
                    try? await telegram.answerCallback(
                        callbackQueryID: callback.id,
                        text: "Провайдер сменён. Reasoning отключён — не поддерживается."
                    )
                } else {
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Провайдер: \(provider.commandValue)")
                }
            }
            try await showPage(.provider, chatKey: chatKey, callback: callback, message: message)
            return

        case "reasoning":
            guard parts.count >= 3, parts[1] == "set" else { return }
            let provider = await state.provider(chatKey: chatKey)
            let gateway = try gateways.gateway(for: provider)
            if gateway.capabilities.supportsReasoning {
                if parts[2] == "off" {
                    await state.setReasoningEffort(chatKey: chatKey, effort: nil)
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Reasoning отключён")
                } else if let effort = ReasoningEffort(rawValue: parts[2]) {
                    await state.setReasoningEffort(chatKey: chatKey, effort: effort)
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Reasoning: \(effort.rawValue)")
                }
            } else {
                try? await telegram.answerCallback(
                    callbackQueryID: callback.id,
                    text: "Провайдер \(provider.commandValue) не поддерживает reasoning"
                )
            }
            try await showPage(.reasoning, chatKey: chatKey, callback: callback, message: message)
            return

        case "reset":
            await state.resetChat(chatKey: chatKey)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Настройки сброшены")
            try await showPage(.main, chatKey: chatKey, callback: callback, message: message)
            return

        case "help":
            try await showPage(.helpPage, chatKey: chatKey, callback: callback, message: message)

        case "noop":
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: nil)
            return

        default:
            try await telegram.answerCallback(callbackQueryID: callback.id, text: "Неизвестное действие")
        }
    }

    private func showPage(_ page: MenuPage, chatKey: ChatKey, callback: CallbackQuery, message: MaybeInaccessibleMessage) async throws {
        let (text, markup) = await renderPage(page, chatKey: chatKey)
        try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)
    }

    private func closeMenu(callback: CallbackQuery, message: MaybeInaccessibleMessage) async throws {
        try await telegram.editMessage(
            .init(
                chatID: message.chat.id,
                messageID: message.message_id,
                text: "Меню закрыто. Откройте снова — /menu",
                replyMarkup: InlineKeyboardMarkup(inline_keyboard: [])
            )
        )
        try? await telegram.answerCallback(callbackQueryID: callback.id, text: nil)
    }

    private func editOrAnswer(
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage,
        text: String,
        markup: InlineKeyboardMarkup
    ) async throws {
        do {
            try await telegram.editMessage(
                .init(
                    chatID: message.chat.id,
                    messageID: message.message_id,
                    text: text,
                    replyMarkup: markup
                )
            )
        } catch {
            _ = try? await telegram.sendMessage(
                .init(
                    chatID: message.chat.id,
                    threadID: message.message_thread_id,
                    replyTo: nil,
                    text: text,
                    replyMarkup: markup
                )
            )
        }
        try? await telegram.answerCallback(callbackQueryID: callback.id, text: nil)
    }

    private func renderPage(_ page: MenuPage, chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        switch page {
        case .main:
            return await renderMain(chatKey: chatKey)
        case .role:
            return await renderRole(chatKey: chatKey)
        case .model:
            return await renderModel(chatKey: chatKey)
        case .temp:
            return await renderTemp(chatKey: chatKey)
        case .stats:
            return await renderStats(chatKey: chatKey)
        case .history:
            return await renderHistory(chatKey: chatKey)
        case .provider:
            return await renderProvider(chatKey: chatKey)
        case .reasoning:
            return await renderReasoning(chatKey: chatKey)
        case .helpPage:
            return await renderHelp(chatKey: chatKey)
        case .close:
            return ("Меню закрыто. Откройте снова — /menu", InlineKeyboardMarkup(inline_keyboard: []))
        }
    }

    // MARK: - Renderers

    private func renderMain(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let help = await state.fetchHelp(chatKey: chatKey)
        let provider = await state.provider(chatKey: chatKey)
        let gateway = try? gateways.gateway(for: provider)
        let reasoningSupported = gateway?.capabilities.supportsReasoning ?? false
        let reasoningLabel = help.reasoningEffort?.rawValue ?? "выкл"

        let text = """
        <b>⚙️ Настройки чата</b>

        🔌 Провайдер · <b>\(help.provider.commandValue)</b>
        🤖 Модель · <b>\(help.model)</b>
        🌡 Темп · <b>\(Self.formatTemp(help.temp))</b>
        📝 История · <b>\(help.maxHistory) сообщ.</b>\
        \(reasoningSupported ? "\n🧠 Reasoning · <b>\(reasoningLabel)</b>" : "")
        """

        var rows: [[InlineKeyboardButton]] = [
            [menuButton("🤖 Модель", action: "nav:model"), menuButton("🎭 Роль", action: "nav:role")],
            [menuButton("🌡 Температура", action: "nav:temp"), menuButton("📝 История", action: "nav:history")],
            [menuButton("🔌 Провайдер", action: "nav:provider")],
        ]
        if reasoningSupported {
            rows[2].append(menuButton("🧠 Reasoning", action: "nav:reasoning"))
        }
        rows.append([menuButton("📊 Что показывать", action: "nav:stats")])
        rows.append([menuButton("❓ Справка", action: "nav:help"), menuButton("↺ Сброс", action: "reset")])
        rows.append([menuButton("✕ Закрыть", action: "close")])

        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderRole(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let help = await state.fetchHelp(chatKey: chatKey)
        let presets = await state.rolePresets()
        let activeIndex = presets.firstIndex(where: { (help.role).hasPrefix($0.value) })

        var rows: [[InlineKeyboardButton]] = []
        var currentRow: [InlineKeyboardButton] = []
        for (i, preset) in presets.enumerated() {
            let label = (i == activeIndex ? "✓ " : "") + preset.display
            currentRow.append(menuButton(label, action: "role:select:\(i)"))
            if currentRow.count == 2 {
                rows.append(currentRow)
                currentRow = []
            }
        }
        if !currentRow.isEmpty {
            rows.append(currentRow)
        }
        rows.append([menuButton("↺ По умолчанию", action: "role:default")])
        rows.append(navButtons())

        let text = """
        <b>🎭 Роль ассистента</b>

        Текущая:
        <blockquote expandable>\(help.role)</blockquote>

        Выберите готовую или задайте свою — /setrole &lt;текст&gt;
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderModel(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let help = await state.fetchHelp(chatKey: chatKey)
        let presets = await state.modelPresets()
        var rows: [[InlineKeyboardButton]] = []
        var currentRow: [InlineKeyboardButton] = []
        for preset in presets {
            let label = (preset.value == help.model ? "✓ " : "") + preset.display
            currentRow.append(menuButton(label, action: "model:select:\(preset.value)"))
            if currentRow.count == 2 {
                rows.append(currentRow)
                currentRow = []
            }
        }
        if !currentRow.isEmpty {
            rows.append(currentRow)
        }
        rows.append(navButtons())

        let text = """
        <b>🤖 Модель</b>

        Текущая · <code>\(help.model)</code>

        <i>Смена модели очистит историю.</i>
        Своя модель — /model &lt;id&gt;
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderTemp(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let help = await state.fetchHelp(chatKey: chatKey)
        let presets = await state.tempPresets()
        var rows: [[InlineKeyboardButton]] = []
        var currentRow: [InlineKeyboardButton] = []
        for preset in presets {
            let isActive = Float(preset.value).map { abs($0 - help.temp) < 0.001 } ?? false
            let label = (isActive ? "✓ " : "") + preset.display
            currentRow.append(menuButton(label, action: "temp:\(preset.value)"))
            if currentRow.count == 2 {
                rows.append(currentRow)
                currentRow = []
            }
        }
        if !currentRow.isEmpty {
            rows.append(currentRow)
        }
        rows.append(navButtons())

        let bucket = Self.tempBucket(help.temp)
        let text = """
        <b>🌡 Температура</b>

        Текущая · <b>\(Self.formatTemp(help.temp))</b> — \(bucket)

        <i>0.0 — точно и предсказуемо · 2.0 — креативно и хаотично</i>
        Своё значение — /settemp &lt;0.0–2.0&gt;
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderStats(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let help = await state.fetchHelp(chatKey: chatKey)
        let rows: [[InlineKeyboardButton]] = [
            [menuButton("\(toggleMark(help.showTokens)) Токены", action: "stats:toggle:tokens"),
             menuButton("\(toggleMark(help.showCost)) Стоимость", action: "stats:toggle:cost")],
            [menuButton("\(toggleMark(help.showModel)) Модель", action: "stats:toggle:model")],
            [menuButton("\(toggleMark(help.backupNotify)) Уведомления о бэкапе", action: "stats:toggle:backup")],
            navButtons(),
        ]
        let text = """
        <b>📊 Что показывать в ответе</b>

        Нажмите, чтобы переключить.
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderHistory(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let help = await state.fetchHelp(chatKey: chatKey)
        let presets = await state.historyLengthPresets()
        var rows: [[InlineKeyboardButton]] = []
        var currentRow: [InlineKeyboardButton] = []
        for preset in presets {
            let isActive = Int(preset.value) == help.maxHistory
            let label = (isActive ? "✓ " : "") + preset.display
            currentRow.append(menuButton(label, action: "history:length:\(preset.value)"))
            if currentRow.count == 2 {
                rows.append(currentRow)
                currentRow = []
            }
        }
        if !currentRow.isEmpty {
            rows.append(currentRow)
        }
        rows.append([menuButton("🧹 Очистить историю", action: "history:clear")])
        rows.append(navButtons())

        let text = """
        <b>📝 Память бота</b>

        Помнит последние · <b>\(help.maxHistory) сообщ.</b>

        <i>Чем больше, тем лучше контекст, но дороже и медленнее.</i>
        Своё значение — /historylength &lt;1–50&gt;
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderProvider(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let help = await state.fetchHelp(chatKey: chatKey)
        let providers = ServiceProvider.allCases
        var rows: [[InlineKeyboardButton]] = []
        var currentRow: [InlineKeyboardButton] = []
        for provider in providers {
            let label = (provider == help.provider ? "✓ " : "") + provider.rawValue
            currentRow.append(menuButton(label, action: "provider:\(provider.commandValue)"))
            if currentRow.count == 2 {
                rows.append(currentRow)
                currentRow = []
            }
        }
        if !currentRow.isEmpty {
            rows.append(currentRow)
        }
        rows.append(navButtons())
        let text = """
        <b>🔌 Провайдер</b>

        Текущий · <b>\(help.provider.commandValue)</b>

        <i>Разные провайдеры — разные модели и возможности.</i>
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderReasoning(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let help = await state.fetchHelp(chatKey: chatKey)
        let provider = await state.provider(chatKey: chatKey)
        let gateway = try? gateways.gateway(for: provider)
        let supported = gateway?.capabilities.supportsReasoning ?? false
        let current = help.reasoningEffort?.rawValue

        if !supported {
            let rows = [navButtons()]
            let text = """
            <b>🧠 Reasoning</b>

            Провайдер <b>\(provider.commandValue)</b> не поддерживает reasoning.
            Смените провайдера, чтобы включить.
            """
            return (text, InlineKeyboardMarkup(inline_keyboard: rows))
        }

        func btn(_ value: String, label: String) -> InlineKeyboardButton {
            let mark = (current == value || (value == "off" && current == nil)) ? "✓ " : ""
            return menuButton(mark + label, action: "reasoning:set:\(value)")
        }

        let rows: [[InlineKeyboardButton]] = [
            [btn("low", label: "Low"), btn("medium", label: "Medium"), btn("high", label: "High")],
            [btn("off", label: "Выключить")],
            navButtons(),
        ]
        let text = """
        <b>🧠 Reasoning</b>

        Текущий · <b>\(current ?? "выкл")</b>

        <i>Глубина рассуждений модели перед ответом. Больше — точнее, но дольше и дороже.</i>
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderHelp(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let help = await state.fetchHelp(chatKey: chatKey)
        let rows: [[InlineKeyboardButton]] = [
            [InlineKeyboardButton(text: "📘 Полная инструкция", callback_data: BotCallbackAction.faq.rawData)],
            navButtons(),
        ]
        return (formatHelpText(help), InlineKeyboardMarkup(inline_keyboard: rows))
    }

    // MARK: - Helpers

    private func menuButton(_ text: String, action: String) -> InlineKeyboardButton {
        .init(text: text, callback_data: BotCallbackAction.menu(action: action).rawData)
    }

    private func navButtons() -> [InlineKeyboardButton] {
        [
            menuButton("← Назад", action: "open"),
            menuButton("✕ Закрыть", action: "close"),
        ]
    }

    private func toggleMark(_ value: Bool) -> String {
        value ? "🟢" : "⚪️"
    }

    static func formatTemp(_ value: Float) -> String {
        if value.rounded() == value {
            return String(format: "%.1f", value)
        }
        return String(format: "%.2f", value)
    }

    static func tempBucket(_ value: Float) -> String {
        switch value {
        case ..<0.4: return "точно"
        case ..<0.9: return "сдержанно"
        case ..<1.3: return "сбалансировано"
        case ..<1.7: return "креативно"
        default: return "хаотично"
        }
    }

    private func formatHelpText(_ help: HelpData) -> String {
        let reasoningLabel = help.reasoningEffort?.rawValue ?? "выкл"
        let suffix = help.testModeSuffix.map(String.init) ?? "выкл"
        return """
        <b>⚙️ Настройки чата</b>

        🔌 Провайдер · <b>\(help.provider.commandValue)</b>
        🤖 Модель · <b>\(help.model)</b>
        🌡 Темп · <b>\(Self.formatTemp(help.temp))</b> — \(Self.tempBucket(help.temp))
        📝 История · <b>\(help.maxHistory) сообщ.</b>
        🧠 Reasoning · <b>\(reasoningLabel)</b>

        <b>Показ в ответе:</b>
        \(yesNo(help.showTokens)) Токены
        \(yesNo(help.showCost)) Стоимость
        \(yesNo(help.showModel)) Модель
        \(yesNo(help.backupNotify)) Уведомления о бэкапе

        <b>🎭 Роль:</b>
        <blockquote expandable>\(help.role)</blockquote>

        <b>Роль по умолчанию:</b>
        <blockquote expandable>\(help.defaultRole)</blockquote>

        <i>Test mode suffix · \(suffix)</i>
        """
    }

    private func yesNo(_ value: Bool) -> String {
        value ? "✓" : "·"
    }
}

extension ServiceProvider: CaseIterable {
    public static var allCases: [ServiceProvider] {
        [.openrouter, .deepseek, .yandex]
    }
}
