import Foundation

enum AppBootstrapError: LocalizedError {
    case missingBotUsername
    
    var errorDescription: String? {
        switch self {
        case .missingBotUsername:
            return "Telegram getMe returned a bot without username"
        }
    }
}

@main
struct BlueprintBotApp {
    static let companyMembers = ""
    static let systemPrompt = "Ты физик, тебя зовут Анатолий."
    static let formatOptions = " Ты можешь форматировать свой текст в соответствии с HTML (по документации Telegram bot api). При упоминании или обращении к участникам никогда не ставь @ перед их именами, чтобы не тегать их."
    
    static func main() async throws {
        let config = try AppConfig.load()
        
        let logger = ConsoleLogger()
        let network = NetworkClient()
        let telegram = TelegramHTTPGateway(network: network, botToken: config.telegramToken)
        
        try? await telegram.deleteWebhook()
        
        let me = try await telegram.getMe()
        guard let botUsername = me.username else {
            throw AppBootstrapError.missingBotUsername
        }
        
        let state = ChatContextStore(
            model: "google/gemini-3-flash-preview",
            systemPrompt: systemPrompt,
            formatOptions: formatOptions,
            companyChatId: config.companyChatId,
            companyMembers: companyMembers,
            defaultHistoryLength: 11,
            defaultSuffix: botUsername == "SwiftPT_test_bot" ? 1 : nil
        )
        
        let sessionRegistry = SessionRegistry()
        let mediaResolver = TelegramMediaResolver(telegram: telegram)
        
        let openrouter = OpenRouterProviderAdapter(network: network, apiKey: config.routerApiKey)
        let deepseek = DeepSeekProviderAdapter(network: network, apiKey: config.deepseekKey)
        
        let orchestrator = BotOrchestrator(
            telegram: telegram,
            state: state,
            sessionRegistry: sessionRegistry,
            mediaResolver: mediaResolver,
            providers: [
                .openrouter: openrouter,
                .deepseek: deepseek,
                .yandex: openrouter
            ],
            logger: logger,
            botUsername: botUsername,
            formatOptions: formatOptions
        )
        
        logger.info("Bot started as @\(botUsername)")
        await orchestrator.run()
    }
}
