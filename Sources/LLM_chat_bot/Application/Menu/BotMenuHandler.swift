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

    private static let modelPresets: [[String]] = [
        ["google/gemini-3-flash-preview", "google/gemini-2.5-pro-preview"],
        ["anthropic/claude-sonnet-4.5", "openai/o4-mini"],
        ["openai/gpt-4.1", "deepseek/deepseek-chat-v3-0324"],
        ["deepseek/deepseek-r1-0528"],
    ]

    private static let tempPresets: [Float] = [0.0, 0.5, 1.0, 1.5, 2.0]

    private static let historyLengthPresets: [Int] = [10, 15, 20, 30, 50]

    init(
        telegram: TelegramGatewayPort,
        state: ChatContextStore,
        gateways: ProviderGatewayRegistry,
        logger: LoggerPort
    ) {
        self.telegram = telegram
        self.state = state
        self.gateways = gateways
        self.logger = logger
    }

    func handle(action rawAction: String, callback: CallbackQuery) async {
        guard let message = callback.message else {
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Сообщение недоступно")
            return
        }

        let chatKey = ChatKey(chatID: message.chat.id, threadID: 0)
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
                    await state.setReasoning(chatKey: chatKey, enabled: false)
                    try? await telegram.answerCallback(
                        callbackQueryID: callback.id,
                        text: "Reasoning отключен: провайдер не поддерживает"
                    )
                }
            }
            try await showPage(.provider, chatKey: chatKey, callback: callback, message: message)

        case "reasoning":
            guard parts.count >= 2, parts[1] == "toggle" else { return }
            let provider = await state.provider(chatKey: chatKey)
            let gateway = try gateways.gateway(for: provider)
            if gateway.capabilities.supportsReasoning {
                _ = await state.toggleReasoning(chatKey: chatKey)
            } else {
                try? await telegram.answerCallback(
                    callbackQueryID: callback.id,
                    text: "Провайдер \(provider.commandValue) не поддерживает reasoning"
                )
            }
            try await showPage(.reasoning, chatKey: chatKey, callback: callback, message: message)

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
                    threadID: nil,
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
        let reasoningLabel = help.reasoning ? "ВКЛ" : "ВЫКЛ"
        let rows: [[InlineKeyboardButton]] = [
            [menuButton("🎭 Роль", action: "nav:role"), menuButton("🔧 Модель", action: "nav:model")],
            [menuButton("🌡️ Температура", action: "nav:temp"), menuButton("📊 Статистика", action: "nav:stats")],
            [menuButton("📝 История", action: "nav:history"), menuButton("🔌 Провайдер", action: "nav:provider")],
            [menuButton("📋 Помощь", action: "nav:help")],
            [menuButton("❌ Закрыть", action: "close")],
        ]
        let text = "📋 Меню настроек\n\n🔌 \(help.provider.commandValue) | 🔧 \(help.model)\n🌡️ temp: \(help.temp) | 🧠 reasoning: \(reasoningLabel)"
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderRole(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let help = await state.fetchHelp(chatKey: chatKey)
        let rows: [[InlineKeyboardButton]] = [
            [menuButton("🔄 По умолчанию", action: "role:default")],
            navButtons(page: .role),
        ]
        let text = "🎭 Текущая роль:\n\n<blockquote>\(help.role)</blockquote>\n\nИспользуйте /setrole для произвольной роли."
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderModel(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let help = await state.fetchHelp(chatKey: chatKey)
        var rows: [[InlineKeyboardButton]] = Self.modelPresets.map { row in
            row.map { menuButton(shortModelName($0), action: "model:select:\($0)") }
        }
        rows.append(navButtons(page: .model))
        let text = "🔧 Текущая модель: \(help.model)\n\nВыберите модель (история будет очищена):"
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderTemp(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let help = await state.fetchHelp(chatKey: chatKey)
        let buttons = Self.tempPresets.map { temp in
            menuButton(String(format: "%.1f", temp), action: "temp:\(temp)")
        }

        var rows: [[InlineKeyboardButton]] = []
        for i in stride(from: 0, to: buttons.count, by: 2) {
            if i + 1 < buttons.count {
                rows.append([buttons[i], buttons[i + 1]])
            } else {
                rows.append([buttons[i]])
            }
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
        let rows: [[InlineKeyboardButton]] = [
            [menuButton(tokensLabel, action: "stats:toggle:tokens"), menuButton(costLabel, action: "stats:toggle:cost")],
            [menuButton(modelLabel, action: "stats:toggle:model")],
            navButtons(page: .stats),
        ]
        let text = "📊 Показывать в ответах:"
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderHistory(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let help = await state.fetchHelp(chatKey: chatKey)
        var rows: [[InlineKeyboardButton]] = []
        let lengthButtons = Self.historyLengthPresets.map { len in
            menuButton("\(len)", action: "history:length:\(len)")
        }
        for i in stride(from: 0, to: lengthButtons.count, by: 2) {
            if i + 1 < lengthButtons.count {
                rows.append([lengthButtons[i], lengthButtons[i + 1]])
            } else {
                rows.append([lengthButtons[i]])
            }
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
        let rows: [[InlineKeyboardButton]] = [
            [menuButton("🧠 ВКЛ", action: "reasoning:toggle"), menuButton("🧠 ВЫКЛ", action: "reasoning:toggle")],
            navButtons(page: .reasoning),
        ]
        let text = "🧠 Reasoning: \(help.reasoning ? "ВКЛ" : "ВЫКЛ")"
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderHelp(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let help = await state.fetchHelp(chatKey: chatKey)
        let navMarkup = InlineKeyboardMarkup(inline_keyboard: [navButtons(page: .helpPage)])
        return (formatHelpText(help), navMarkup)
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

    private func shortModelName(_ model: String) -> String {
        let parts = model.split(separator: "/")
        return parts.count == 2 ? String(parts[1]) : model
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
        • Reasoning: \(help.reasoning)
        • Роль: <blockquote>\(help.role)</blockquote>
        • TestMode Suffix: \(help.testModeSuffix, default: "disabled")
        -------------------
        Команды:
        -------------------                
        /setrole #Новая_роль# - установить новую роль боту и очистить историю сообщений
        /clear_history - очистить историю сообщений, сохранив роль
        /settemp #число# - задать креативность бота. 2.0 - максимальная креативность, 0.0 - максимальна точность и стабильность ответов. (По умолчанию = 1.5)
        /show_tokens - вкл/выкл показ расхода токенов, использованных для генерации сообщения. (По умолчанию = выкл)
        /default_role - вернуть стандартную роль
        /historylength #число# - задать количество последних сообщений, которые будет помнить бот. (По умолчанию = 11)
        /model #новая_модель# - задать новую модель ИИ для ответов
        /show_model - вкл/выкл показ использованной модели (По умолчанию = вкл)
        /show_cost - вкл/выкл показ стоимости сгенерированного сообщения в $ (По умолчанию = выкл)
        /provider #deepseek|openrouter|yandex# - сменить провайдер
        /testmode - включить/выключить суффикс команд
        /reasoning - включить/выключить reasoning
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
