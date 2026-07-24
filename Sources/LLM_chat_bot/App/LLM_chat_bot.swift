import Foundation
import Dispatch

enum AppBootstrapError: LocalizedError {
    case missingBotUsername
    case webhookModeWithoutPublicURL

    var errorDescription: String? {
        switch self {
        case .missingBotUsername:
            return "Telegram getMe returned a bot without username"
        case .webhookModeWithoutPublicURL:
            return "UPDATE_MODE=webhook requires WEBHOOK_PUBLIC_URL (or RAILWAY_PUBLIC_DOMAIN)"
        }
    }
}

@main
struct BlueprintBotApp {
    static let ownerUsername = "maythe4th"
    static let companyMembers = ""
    static let systemPrompt = "Ты физик, тебя зовут Анатолий."
    static let formatOptions = " Ты можешь форматировать свой текст в соответствии с HTML (по документации Telegram bot api). При упоминании или обращении к участникам никогда не ставь @ перед их именами, чтобы не тегать их."

    // Keeps signal sources alive for the process lifetime.
    private static let signalSources = LockedValue<[DispatchSourceSignal]>([])

    private static func presets<T: CustomStringConvertible>(from values: [T]) -> [Preset] {
        values.map { Preset(display: String(describing: $0), value: String(describing: $0)) }
    }

    static func main() async throws {
        let config = try AppConfig.load()
        let logger = ConsoleLogger.fromEnvironment()
        let metrics = RuntimeMetrics()
        let flags = RuntimeFlags()

        let network = NetworkClient()
        let rateLimiter = TelegramRateLimiter()
        let telegram = TelegramHTTPGateway(
            network: network,
            botToken: config.telegramToken,
            rateLimiter: rateLimiter,
            metrics: metrics
        )

        let me = try await telegram.getMe()
        guard let botUsername = me.username else {
            throw AppBootstrapError.missingBotUsername
        }

        let state = ChatContextStore(
            ownerUsername: ownerUsername,
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

        let rawPersistence: StatePersistencePort?
        let persistenceCoordinator: PersistenceCoordinator?
        if let supabaseURL = config.supabaseURL, let supabaseKey = config.supabaseKey {
            if config.usesAnonSupabaseKey {
                logger.warning("using SUPABASE_ANON_KEY — create SUPABASE_SERVICE_KEY and enable RLS (see DEPLOY.md)")
            }
            let supabase = SupabaseStatePersistence(
                network: network,
                baseURL: supabaseURL,
                apiKey: supabaseKey
            )
            rawPersistence = supabase
            persistenceCoordinator = PersistenceCoordinator(
                store: state,
                persistence: supabase,
                logger: logger,
                metrics: metrics
            )
            logger.info("Supabase persistence enabled (row schema, write-behind)")
        } else {
            rawPersistence = nil
            persistenceCoordinator = nil
            logger.info("Supabase persistence disabled (missing SUPABASE_URL or key)")
        }

        let sessionRegistry = SessionRegistry()
        let mediaResolver = TelegramMediaResolver(telegram: telegram)
        let generationLimiter = GenerationLimiter(maxConcurrent: config.maxConcurrentGenerations)

        let openrouter = OpenRouterProviderAdapter(network: network, apiKey: config.routerApiKey)
        let deepseek = DeepSeekProviderAdapter(network: network, apiKey: config.deepseekKey)

        let modelPriceMonitor = ModelPriceMonitor(
            network: network,
            apiKey: config.routerApiKey,
            state: state,
            telegram: telegram,
            logger: logger
        )

        let cryptoService = CryptoPaymentService(
            state: state,
            network: network,
            telegram: telegram,
            logger: logger
        )

        let tonExplorer = TonExplorer(network: network, apiKey: config.tonapiKey)
        // Etherscan V2 is multichain: one etherscan.io key serves both ETH and
        // BSC. A legacy BSCSCAN_API_KEY still works as a fallback for BSC.
        let bscExplorer = (config.bscscanApiKey ?? config.etherscanApiKey).map {
            EvmExplorer(network: network, chainID: 56, apiKey: $0)
        }
        let ethExplorer = config.etherscanApiKey.map {
            EvmExplorer(network: network, chainID: 1, apiKey: $0)
        }
        let tronExplorer = TronExplorer(network: network, apiKey: config.trongridApiKey)

        let cryptoMonitor = CryptoPaymentMonitor(
            state: state,
            service: cryptoService,
            logger: logger,
            tonExplorer: tonExplorer,
            bscExplorer: bscExplorer,
            ethExplorer: ethExplorer,
            tronExplorer: tronExplorer
        )

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
            persistence: persistenceCoordinator,
            logger: logger,
            metrics: metrics,
            flags: flags,
            generationLimiter: generationLimiter,
            botUsername: botUsername,
            formatOptions: formatOptions,
            modelPriceMonitor: modelPriceMonitor,
            cryptoService: cryptoService,
            cryptoMonitor: cryptoMonitor
        )

        let intake = UpdateIntake(metrics: metrics) { [orchestrator] update in
            await orchestrator.dispatch(update: update)
        }

        // Intake mode: webhook in production (Railway provides the domain),
        // polling for local development.
        let mode: IntakeRunMode
        let webhookSecret = config.webhookSecret ?? UUID().uuidString + UUID().uuidString
        switch config.updateMode {
        case .webhook:
            guard let base = config.webhookPublicURL else {
                throw AppBootstrapError.webhookModeWithoutPublicURL
            }
            mode = .webhook(publicBaseURL: base, secret: webhookSecret)
        case .polling:
            mode = .polling
        case .auto:
            if let base = config.webhookPublicURL {
                mode = .webhook(publicBaseURL: base, secret: webhookSecret)
            } else {
                mode = .polling
            }
        }

        let server = AppHTTPServer(port: config.healthPort) { [orchestrator, intake, telegram, flags] head, body in
            let path = head.uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
            switch (head.method, path) {
            case (.GET, "/health"), (.HEAD, "/health"):
                return .ok("OK")

            case (.GET, "/ready"):
                return flags.ready.value
                    ? .ok("ready")
                    : AppHTTPResponse(status: .serviceUnavailable, body: "starting")

            case (.GET, "/metrics"):
                let report = await orchestrator.metricsReport()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let json = (try? encoder.encode(report)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                return .json(json)

            case (.POST, WebhookEndpoint.path):
                guard head.headers.first(name: WebhookEndpoint.secretHeader) == webhookSecret else {
                    return AppHTTPResponse(status: .unauthorized, body: "bad secret")
                }
                // 503 before restore completes and while draining — Telegram
                // holds the update and redelivers once we answer 200 again.
                guard flags.ready.value, !flags.draining.value else {
                    return AppHTTPResponse(status: .serviceUnavailable, body: "not accepting updates")
                }
                guard let update = try? telegram.decodeIncomingUpdate(body) else {
                    // 200 for unparseable payloads so Telegram doesn't retry
                    // the same poison update forever.
                    return .ok("ignored")
                }
                await intake.enqueue([update])
                return .ok("")

            default:
                return AppHTTPResponse(status: .notFound, body: "not found")
            }
        }

        try await server.start()
        logger.info("HTTP server started on port \(config.healthPort) (/health, /ready, /metrics, webhook)")

        let persistenceHealthy = await orchestrator.bootstrapState(rawPersistence: rawPersistence)

        installShutdownHandlers(orchestrator: orchestrator, logger: logger)

        logger.info("Bot started as @\(botUsername)")
        await orchestrator.run(mode: mode, intake: intake, persistenceHealthy: persistenceHealthy)

        // run() returns only when draining began; the signal task finishes the
        // flush and exits the process.
        while true {
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    /// Railway sends SIGTERM before stopping a deployment; flushing state in
    /// that grace window is what makes redeploys lossless.
    private static func installShutdownHandlers(orchestrator: BotOrchestrator, logger: LoggerPort) {
        var sources: [DispatchSourceSignal] = []
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                Task {
                    await orchestrator.shutdown()
                    exit(0)
                }
            }
            source.resume()
            sources.append(source)
        }
        signalSources.value = sources
    }
}
