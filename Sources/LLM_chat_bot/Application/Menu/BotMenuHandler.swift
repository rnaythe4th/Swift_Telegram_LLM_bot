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
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Ошибка")
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
                try await showPage(.role, chatKey: chatKey, callback: callback, message: message)
            } else if parts[1] == "select", parts.count >= 3, let index = Int(parts[2]) {
                let presets = await state.rolePresets()
                guard index >= 0, index < presets.count else {
                    try await telegram.answerCallback(callbackQueryID: callback.id, text: "Пресет не найден")
                    return
                }
                let roleValue = presets[index].value + formatOptions
                _ = await state.setRoleAndResetHistory(chatKey: chatKey, role: roleValue)
                try await showPage(.role, chatKey: chatKey, callback: callback, message: message)
            }

        case "model":
            guard parts.count >= 3, parts[1] == "select" else { return }
            let model = parts[2]
            _ = await state.setModelAndResetHistory(chatKey: chatKey, newModel: model)
            try await showPage(.model, chatKey: chatKey, callback: callback, message: message)

        case "temp":
            guard parts.count >= 2, let temp = Float(parts[1]), (0.0...2.0).contains(temp) else { return }
            await state.setTemperature(chatKey: chatKey, value: temp)
            try await showPage(.temp, chatKey: chatKey, callback: callback, message: message)

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

        case "history":
            guard parts.count >= 2 else { return }
            if parts[1] == "clear" {
                await state.clearHistory(chatKey: chatKey)
                try await showPage(.history, chatKey: chatKey, callback: callback, message: message)
            } else if parts.count >= 3, parts[1] == "length", let length = Int(parts[2]) {
                await state.setMaxHistory(chatKey: chatKey, newMax: length)
                try await showPage(.history, chatKey: chatKey, callback: callback, message: message)
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
                        text: "Reasoning отключен: провайдер не поддерживает"
                    )
                }
            }
            try await showPage(.provider, chatKey: chatKey, callback: callback, message: message)

        case "reasoning":
            guard parts.count >= 3, parts[1] == "set" else { return }
            let provider = await state.provider(chatKey: chatKey)
            let gateway = try gateways.gateway(for: provider)
            if gateway.capabilities.supportsReasoning {
                if parts[2] == "off" {
                    await state.setReasoningEffort(chatKey: chatKey, effort: nil)
                } else if let effort = ReasoningEffort(rawValue: parts[2]) {
                    await state.setReasoningEffort(chatKey: chatKey, effort: effort)
                }
            } else {
                try? await telegram.answerCallback(
                    callbackQueryID: callback.id,
                    text: "Провайдер \(provider.commandValue) не поддерживает reasoning"
                )
            }
            try await showPage(.reasoning, chatKey: chatKey, callback: callback, message: message)

        case "reset":
            await state.resetChat(chatKey: chatKey)
            try await showPage(.main, chatKey: chatKey, callback: callback, message: message)

        case "help":
            try await showPage(.helpPage, chatKey: chatKey, callback: callback, message: message)

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
                text: "📋 Меню закрыто",
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
            return ("📋 Меню закрыто", InlineKeyboardMarkup(inline_keyboard: []))
        }
    }

    // MARK: - Renderers

    private func renderMain(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let help = await state.fetchHelp(chatKey: chatKey)
        let reasoningLabel = help.reasoningEffort?.rawValue ?? "выкл"
        let rows: [[InlineKeyboardButton]] = [
            [menuButton("🎭 Роль", action: "nav:role"), menuButton("🔧 Модель", action: "nav:model")],
            [menuButton("🌡️ Температура", action: "nav:temp"), menuButton("📊 Статистика", action: "nav:stats")],
            [menuButton("📝 История", action: "nav:history"), menuButton("🔌 Провайдер", action: "nav:provider")],
            [menuButton("🧠 Reasoning", action: "nav:reasoning"), menuButton("🔄 Сброс", action: "reset")],
            [menuButton("📋 Помощь", action: "nav:help")],
            [menuButton("❌ Закрыть", action: "close")],
        ]
        let text = "📋 Меню настроек\n\n🔌 Provider: \(help.provider.commandValue)\n🔧 \(help.model)\n🌡️ Temp: \(help.temp)\n🧠 Reasoning: \(reasoningLabel)"
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderRole(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let help = await state.fetchHelp(chatKey: chatKey)
        let presets = await state.rolePresets()
        var rows: [[InlineKeyboardButton]] = []
        var currentRow: [InlineKeyboardButton] = []
        for (i, preset) in presets.enumerated() {
            currentRow.append(menuButton(preset.display, action: "role:select:\(i)"))
            if currentRow.count == 2 {
                rows.append(currentRow)
                currentRow = []
            }
        }
        if !currentRow.isEmpty {
            rows.append(currentRow)
        }
        rows.append([menuButton("🔄 По умолчанию", action: "role:default")])
        rows.append(navButtons(page: .role))
        let text = "🎭 Текущая роль:\n\n<blockquote>\(help.role)</blockquote>\n\nИспользуйте /setrole для произвольной роли."
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderModel(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let help = await state.fetchHelp(chatKey: chatKey)
        let presets = await state.modelPresets()
        var rows: [[InlineKeyboardButton]] = []
        var currentRow: [InlineKeyboardButton] = []
        for preset in presets {
            currentRow.append(menuButton(preset.display, action: "model:select:\(preset.value)"))
            if currentRow.count == 2 {
                rows.append(currentRow)
                currentRow = []
            }
        }
        if !currentRow.isEmpty {
            rows.append(currentRow)
        }
        rows.append(navButtons(page: .model))
        let text = "🔧 Текущая модель: \(help.model)\n\nВыберите модель (история будет очищена):"
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderTemp(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let help = await state.fetchHelp(chatKey: chatKey)
        let presets = await state.tempPresets()
        var rows: [[InlineKeyboardButton]] = []
        var currentRow: [InlineKeyboardButton] = []
        for preset in presets {
            currentRow.append(menuButton(preset.display, action: "temp:\(preset.value)"))
            if currentRow.count == 2 {
                rows.append(currentRow)
                currentRow = []
            }
        }
        if !currentRow.isEmpty {
            rows.append(currentRow)
        }
        rows.append(navButtons(page: .temp))
        let text = "🌡️ Temperature: \(help.temp)"
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderStats(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let help = await state.fetchHelp(chatKey: chatKey)
        let tokensLabel = "Токены: \(help.showTokens ? "✅" : "❌")"
        let costLabel = "Стоимость: \(help.showCost ? "✅" : "❌")"
        let modelLabel = "Модель: \(help.showModel ? "✅" : "❌")"
        let backupLabel = "Уведомления о бэкапе: \(help.backupNotify ? "✅" : "❌")"
        let rows: [[InlineKeyboardButton]] = [
            [menuButton(tokensLabel, action: "stats:toggle:tokens"), menuButton(costLabel, action: "stats:toggle:cost")],
            [menuButton(modelLabel, action: "stats:toggle:model")],
            [menuButton(backupLabel, action: "stats:toggle:backup")],
            navButtons(page: .stats),
        ]
        let text = "📊 Показывать в ответах:"
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderHistory(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let help = await state.fetchHelp(chatKey: chatKey)
        let presets = await state.historyLengthPresets()
        var rows: [[InlineKeyboardButton]] = []
        var currentRow: [InlineKeyboardButton] = []
        for preset in presets {
            currentRow.append(menuButton(preset.display, action: "history:length:\(preset.value)"))
            if currentRow.count == 2 {
                rows.append(currentRow)
                currentRow = []
            }
        }
        if !currentRow.isEmpty {
            rows.append(currentRow)
        }
        rows.append([menuButton("🗑️ Очистить историю", action: "history:clear")])
        rows.append(navButtons(page: .history))
        let text = "📝 Длина истории: \(help.maxHistory)"
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderProvider(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let help = await state.fetchHelp(chatKey: chatKey)
        let providers = ServiceProvider.allCases
        var rows: [[InlineKeyboardButton]] = []
        var currentRow: [InlineKeyboardButton] = []
        for provider in providers {
            let marker = provider == help.provider ? "✅ " : ""
            currentRow.append(menuButton("\(marker)\(provider.rawValue)", action: "provider:\(provider.commandValue)"))
        }
        rows.append(currentRow)
        rows.append(navButtons(page: .provider))
        let text = "🔌 Текущий провайдер: \(help.provider.commandValue)"
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderReasoning(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let help = await state.fetchHelp(chatKey: chatKey)
        let current = help.reasoningEffort?.rawValue ?? "выкл"
        let rows: [[InlineKeyboardButton]] = [
            [menuButton("🧠 high", action: "reasoning:set:high"), menuButton("🧠 medium", action: "reasoning:set:medium")],
            [menuButton("🧠 low", action: "reasoning:set:low"), menuButton("❌ выкл", action: "reasoning:set:off")],
            navButtons(page: .reasoning),
        ]
        let text = "🧠 Reasoning: \(current)"
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderHelp(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let help = await state.fetchHelp(chatKey: chatKey)
        let rows: [[InlineKeyboardButton]] = [
            [InlineKeyboardButton(text: "Открыть инструкцию к боту", callback_data: BotCallbackAction.faq.rawData)],
            navButtons(page: .helpPage),
        ]
        return (formatHelpText(help), InlineKeyboardMarkup(inline_keyboard: rows))
    }

    // MARK: - Helpers

    private func menuButton(_ text: String, action: String) -> InlineKeyboardButton {
        .init(text: text, callback_data: BotCallbackAction.menu(action: action).rawData)
    }

    private func navButtons(page: MenuPage) -> [InlineKeyboardButton] {
        [
            menuButton("⬅️ Назад", action: "open"),
            menuButton("❌ Закрыть", action: "close"),
        ]
    }

    private func formatHelpText(_ help: HelpData) -> String {
        """
        Текущие настройки для этого чата:
        -------------------
        • Провайдер: \(help.provider.commandValue)
        • Модель: \(help.model)
        • Temperature: \(help.temp)
        • Длина истории: \(help.maxHistory)
        • Показать расход токенов: \(help.showTokens)
        • Показать стоимость сообщения: \(help.showCost)
        • Показать использованную модель: \(help.showModel)
        • Reasoning: \(help.reasoningEffort?.rawValue ?? "выкл")
        • Уведомления о бэкапе: \(help.backupNotify)
        • Роль: <blockquote>\(help.role)</blockquote>
        • TestMode Suffix: \(help.testModeSuffix, default: "disabled")
        -------------------
        Дефолтная роль:
        -------------------
        <blockquote>\(help.defaultRole)</blockquote>
        """
    }
}

extension ServiceProvider: CaseIterable {
    public static var allCases: [ServiceProvider] {
        [.openrouter, .deepseek, .yandex]
    }
}
