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
    
    private static func presets<T: CustomStringConvertible>(from values: [T]) -> [Preset] {
        values.map { Preset(display: String(describing: $0), value: String(describing: $0)) }
    }
    
    static func main() async throws {
        let config = try AppConfig.load()

        let logger = ConsoleLogger()
        let healthServer = HealthCheckServer(port: config.healthPort)
        try await healthServer.start()
        logger.info("Health check server started on port \(config.healthPort)")

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

        await state.setModelPresets([
            Preset(display: "Gemini 3 Flash preview", value: "google/gemini-3-flash-preview"),
            Preset(display: "Gemini Flash latest", value: "google/gemini-flash-latest"),
            Preset(display: "Gemini 3.1 Flash Lite", value: "google/gemini-3.1-flash-lite-preview"),
            Preset(display: "DeepSeek V4 Pro", value: "deepseek/deepseek-v4-pro"),
            Preset(display: "DeepSeek V4 Flash", value: "deepseek/deepseek-v4-flash"),
            Preset(display: "Grok 4.3", value: "x-ai/grok-4.3"),
        ])
        await state.setTempPresets(presets(from: [0.0, 0.5, 1.0, 1.5, 2.0]))
        await state.setHistoryLengthPresets(presets(from: [10, 15, 20, 30, 50]))
        await state.setRolePresets([
            Preset(display: "Физик Анатолий", value: "Ты физик, тебя зовут Анатолий."),
        ])

        let persistence: StatePersistencePort?
        if let supabaseURL = config.supabaseURL, let supabaseAnonKey = config.supabaseAnonKey {
            persistence = SupabaseStatePersistence(
                network: network,
                baseURL: supabaseURL,
                apiKey: supabaseAnonKey
            )
            logger.info("Supabase persistence enabled")
        } else {
            persistence = nil
            logger.info("Supabase persistence disabled (missing SUPABASE_URL or SUPABASE_ANON_KEY)")
        }

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
            persistence: persistence,
            logger: logger,
            botUsername: botUsername,
            formatOptions: formatOptions
        )
        
        logger.info("Bot started as @\(botUsername)")
        await orchestrator.run()
    }
}
