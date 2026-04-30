import Foundation

final class BotCommandHandler: @unchecked Sendable {
    private let telegram: TelegramGatewayPort
    private let state: ChatContextStore
    private let gateways: ProviderGatewayRegistry
    private let botUsername: String
    private let formatOptions: String
    private let menuHandler: BotMenuHandler
    
    init(
        telegram: TelegramGatewayPort,
        state: ChatContextStore,
        gateways: ProviderGatewayRegistry,
        botUsername: String,
        formatOptions: String,
        menuHandler: BotMenuHandler
    ) {
        self.telegram = telegram
        self.state = state
        self.gateways = gateways
        self.botUsername = botUsername
        self.formatOptions = formatOptions
        self.menuHandler = menuHandler
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
    
    private func isAdmin(_ user: TelegramUser?) async -> Bool {
        await state.isAdmin(username: user?.username)
    }
    
    private func requireAdmin(_ user: TelegramUser?, chatKey: ChatKey) async throws -> Bool {
        guard await isAdmin(user) else {
            try await sendUserFeedback(chatKey: chatKey, text: "Эта команда доступна только администратору.")
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
            try await handleChats(chatKey: chatKey)
            
        case .users:
            guard try await requireAdmin(fromUser, chatKey: chatKey) else { return }
            try await handleUsers(chatKey: chatKey)
            
        case .setRole:
            _ = await state.setRoleAndResetHistory(chatKey: chatKey, role: parsed.argument + formatOptions)
            try await sendUserFeedback(chatKey: chatKey, text: "Роль изменена + история очищена")
            
        case .clearHistory:
            await state.clearHistory(chatKey: chatKey)
            try await sendUserFeedback(chatKey: chatKey, text: "История очищена")
            
        case .setTemp:
            guard let temp = Float(parsed.argument), (0.0...2.0).contains(temp) else {
                let err = Float(parsed.argument) == nil
                ? "Ошибка: укажите ЧИСЛО от 0 до 2"
                : "Ошибка: укажите число от 0 до 2. Вы указали: \(Float(parsed.argument)!)"
                try await sendUserFeedback(chatKey: chatKey, text: err)
                return
            }
            await state.setTemperature(chatKey: chatKey, value: temp)
            try await sendUserFeedback(chatKey: chatKey, text: "Temperature: \(await state.temperature(chatKey: chatKey))")
            
        case .model:
            let changed = await state.setModelAndResetHistory(chatKey: chatKey, newModel: parsed.argument)
            try await sendUserFeedback(chatKey: chatKey, text: """
                Модель изменена:
                \(changed.old) ----> \(changed.new).
                История очищена.
                """)
            
        case .showTokens:
            let new = await state.toggleShowStats(chatKey: chatKey)
            try await sendUserFeedback(chatKey: chatKey, text: "Показывать расход токенов: \(new)")
            
        case .showCost:
            let new = await state.toggleShowCost(chatKey: chatKey)
            try await sendUserFeedback(chatKey: chatKey, text: "Показывать стоимость сообщений: \(new)")
            
        case .showModel:
            let new = await state.toggleShowModel(chatKey: chatKey)
            try await sendUserFeedback(chatKey: chatKey, text: "Показывать использованную модель: \(new)")
            
        case .help:
            let help = await state.fetchHelp(chatKey: chatKey)
            let adminInfo = await isAdmin(fromUser) ? "\n\nВы — администратор. Доступны: /whitelist, /defaults, /chats, /users" : ""
            try await sendUserFeedback(chatKey: chatKey, text: """
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
                \(adminInfo)
                -------------------
                Дефолтная роль:
                -------------------
                <blockquote>\(help.defaultRole)</blockquote>
                """)
            
        case .defaultRole:
            let defaultRole = await state.defaultRole(chatID: chatKey.chatID)
            _ = await state.setRoleAndResetHistory(chatKey: chatKey, role: defaultRole)
            try await sendUserFeedback(chatKey: chatKey, text: "Роль изменена на стандартную + история очищена")
            
        case .historyLength:
            guard let newMax = Int(parsed.argument), (1...50).contains(newMax) else {
                let err = Int(parsed.argument) == nil
                ? "Ошибка: укажите ЧИСЛО от 1 до 50"
                : "Ошибка: укажите число от 1 до 50. Вы указали: \(Int(parsed.argument)!)"
                try await sendUserFeedback(chatKey: chatKey, text: err)
                return
            }
            await state.setMaxHistory(chatKey: chatKey, newMax: newMax)
            try await sendUserFeedback(chatKey: chatKey, text: "Длина истории: \(newMax) сообщений")
            
        case .provider:
            let feedback: String
            if let provider = ServiceProvider.parse(parsed.argument) {
                let old = await state.changeProvider(chatKey: chatKey, newProvider: provider)
                var lines = ["\(old.commandValue) ----> \(provider.commandValue)"]
                
                let gateway = try gateways.gateway(for: provider)
                let reasoningEnabled = await state.reasoningEnabled(chatKey: chatKey)
                if reasoningEnabled, !gateway.capabilities.supportsReasoning {
                    await state.setReasoning(chatKey: chatKey, enabled: false)
                    lines.append("Reasoning автоматически отключен: провайдер не поддерживает reasoning.")
                }
                
                feedback = lines.joined(separator: "\n")
            } else {
                feedback = "Неверный провайдер. Доступны: deepseek, openrouter, yandex."
            }
            try await sendUserFeedback(chatKey: chatKey, text: feedback)
            
        case .testMode:
            let suffix = await state.toggleTestMode(chatKey: chatKey)
            if let suffix {
                try await sendUserFeedback(chatKey: chatKey, text: """
                    Test mode ENABLED.
                    
                    New suffix = \(suffix)
                    
                    Use it with bot commands, for example:
                    /help\(suffix)
                    /setrole\(suffix) You are Donald Trump.
                    """)
            } else {
                try await sendUserFeedback(chatKey: chatKey, text: "Test mode DISABLED")
            }
            
        case .reasoning:
            let provider = await state.provider(chatKey: chatKey)
            let gateway = try gateways.gateway(for: provider)
            
            guard gateway.capabilities.supportsReasoning else {
                try await sendUserFeedback(
                    chatKey: chatKey,
                    text: "Провайдер \(provider.commandValue) не поддерживает reasoning."
                )
                return
            }
            
            let enabled = await state.toggleReasoning(chatKey: chatKey)
            try await sendUserFeedback(chatKey: chatKey, text: "Reasoning: \(enabled)")
            
        case .menu:
            await menuHandler.sendMenu(chatKey: chatKey)
            
        case .reset:
            await state.resetChat(chatKey: chatKey)
            try await sendUserFeedback(chatKey: chatKey, text: "Настройки сброшены к дефолтным.")
            
        case .mention, .unknown:
            return
        }
    }
    
    private func handleWhitelist(chatKey: ChatKey, argument: String) async throws {
        let parts = argument.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        let subcommand = parts.first ?? ""
        let value = parts.count > 1 ? parts[1] : ""
        
        switch subcommand.lowercased() {
        case "add":
            guard let userID = Int(value) else {
                try await sendUserFeedback(chatKey: chatKey, text: "Укажите ID пользователя: /whitelist add 123456789")
                return
            }
            await state.addToWhitelist(userID: userID)
            try await sendUserFeedback(chatKey: chatKey, text: "Пользователь \(userID) добавлен в белый список.")
            
        case "remove":
            guard let userID = Int(value) else {
                try await sendUserFeedback(chatKey: chatKey, text: "Укажите ID пользователя: /whitelist remove 123456789")
                return
            }
            await state.removeFromWhitelist(userID: userID)
            try await sendUserFeedback(chatKey: chatKey, text: "Пользователь \(userID) удалён из белого списка.")
            
        case "list":
            let ids = await state.listWhitelisted()
            if ids.isEmpty {
                try await sendUserFeedback(chatKey: chatKey, text: "Белый список пуст.")
            } else {
                let sorted = ids.sorted()
                let list = sorted.map { "• \($0)" }.joined(separator: "\n")
                try await sendUserFeedback(chatKey: chatKey, text: "Белый список (\(sorted.count)):\n\(list)")
            }
            
        default:
            try await sendUserFeedback(chatKey: chatKey, text: """
                Использование:
                /whitelist add <ID> - добавить пользователя
                /whitelist remove <ID> - удалить пользователя
                /whitelist list - показать список
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
                let defs = await state.getDefaults()
                try await sendUserFeedback(chatKey: chatKey, text: "Дефолтная модель: \(defs.model)")
                return
            }
            let new = await state.setDefaultModel(value)
            try await sendUserFeedback(chatKey: chatKey, text: "Дефолтная модель изменена на: \(new)")
            
        case "role":
            guard !value.isEmpty else {
                let defs = await state.getDefaults()
                try await sendUserFeedback(chatKey: chatKey, text: "Дефолтная роль: \(defs.role)")
                return
            }
            let new = await state.setDefaultRole(value)
            try await sendUserFeedback(chatKey: chatKey, text: "Дефолтная роль изменена на:\n<blockquote>\(new)</blockquote>")
            
        case "historylength":
            guard !value.isEmpty, let length = Int(value), (1...50).contains(length) else {
                if value.isEmpty {
                    let defs = await state.getDefaults()
                    try await sendUserFeedback(chatKey: chatKey, text: "Дефолтная длина истории: \(defs.historyLength)")
                } else {
                    try await sendUserFeedback(chatKey: chatKey, text: "Укажите число от 1 до 50: /defaults historylength 11")
                }
                return
            }
            let new = await state.setDefaultHistoryLength(length)
            try await sendUserFeedback(chatKey: chatKey, text: "Дефолтная длина истории изменена на: \(new)")
            
        default:
            let defs = await state.getDefaults()
            try await sendUserFeedback(chatKey: chatKey, text: """
                Дефолтные настройки:
                -------------------
                • Модель: \(defs.model)
                • Длина истории: \(defs.historyLength)
                • Роль: <blockquote>\(defs.role)</blockquote>
                -------------------
                Команды:
                /defaults model <модель> - изменить дефолтную модель
                /defaults role <роль> - изменить дефолтную роль
                /defaults historylength <число> - изменить дефолтную длину истории
                """)
        }
    }
    
    private func handleChats(chatKey: ChatKey) async throws {
        let groups = await state.groupChats()
        let privates = await state.privateChats()
        
        var lines: [String] = []
        
        if !groups.isEmpty {
            lines.append("Групповые чаты (\(groups.count)):")
            for (chatID, threadID) in groups.sorted(by: { $0.chatID < $1.chatID }) {
                let threadInfo = threadID != 0 ? " (thread: \(threadID))" : ""
                lines.append("• \(chatID)\(threadInfo)")
            }
        } else {
            lines.append("Групповые чаты: нет")
        }
        
        lines.append("")
        
        if !privates.isEmpty {
            lines.append("Личные чаты (\(privates.count)):")
            for (chatID, threadID) in privates.sorted(by: { $0.chatID < $1.chatID }) {
                let threadInfo = threadID != 0 ? " (thread: \(threadID))" : ""
                lines.append("• \(chatID)\(threadInfo)")
            }
        } else {
            lines.append("Личные чаты: нет")
        }
        
        try await sendUserFeedback(chatKey: chatKey, text: lines.joined(separator: "\n"))
    }
    
    private func handleUsers(chatKey: ChatKey) async throws {
        let privates = await state.privateChats()
        
        if privates.isEmpty {
            try await sendUserFeedback(chatKey: chatKey, text: "Никто не общается с ботом в личке.")
            return
        }
        
        let sorted = privates.sorted(by: { $0.chatID < $1.chatID })
        let list = sorted.map { "• ID: \($0.chatID)" }.joined(separator: "\n")
        try await sendUserFeedback(chatKey: chatKey, text: "Пользователи в личке (\(sorted.count)):\n\(list)\n\nДля добавления: /whitelist add <ID>")
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
