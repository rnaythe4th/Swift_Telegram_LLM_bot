import Foundation

// Composition root. Every dependency is built here, by hand, in one pass —
// `main` is then just the startup sequence (serve → restore → run → drain).

/// The assembled object graph, plus the two secrets the HTTP surface checks.
struct AppAssembly {
    static let ownerUsername = "maythe4th"
    static let companyMembers = ""
    static let systemPrompt = "Ты — полезный ИИ-ассистент в Telegram. Отвечай по делу, кратко и понятно, без воды и канцелярита. Если вопрос неясен — уточни."
    static let formatOptions = " Ты можешь форматировать свой текст в соответствии с HTML (по документации Telegram bot api). При упоминании или обращении к участникам никогда не ставь @ перед их именами, чтобы не тегать их."

    let logger: LoggerPort
    let flags: RuntimeFlags
    let telegram: TelegramHTTPGateway
    let botUsername: String
    let rawPersistence: StatePersistencePort?
    let orchestrator: BotOrchestrator
    let intake: UpdateIntake
    let mode: IntakeRunMode
    let webhookSecret: String
    let metricsToken: String

    /// Redacts every secret before the first log line: a leaked bot token is a
    /// complete takeover, and transport errors quote the URL they failed on —
    /// which for every Telegram call embeds the token.
    static func registerSecrets(_ config: AppConfig) {
        SecretRedactor.shared.register([
            config.telegramToken,
            config.deepseekKey,
            config.routerApiKey,
            config.supabaseServiceKey,
            config.supabaseAnonKey,
            config.webhookSecret,
            config.metricsToken,
            config.tonapiKey,
            config.etherscanApiKey,
            config.bscscanApiKey,
            config.trongridApiKey
        ])
    }

    static func build(config: AppConfig, logger: LoggerPort) async throws -> AppAssembly {
        let metrics = RuntimeMetrics()
        let flags = RuntimeFlags()

        let network = NetworkClient()
        let telegram = makeTelegram(config: config, network: network, metrics: metrics)

        let me = try await telegram.getMe()
        guard let botUsername = me.username else {
            throw AppBootstrapError.missingBotUsername
        }

        if config.ownerUserID == nil {
            logger.warning("OWNER_USER_ID is not set — the owner is recognised by @\(ownerUsername) alone; set it so root cannot follow the username to somebody else")
        }

        let state = await makeStore(config: config, botUsername: botUsername)
        let (rawPersistence, persistenceCoordinator) = makePersistence(
            config: config,
            state: state,
            network: network,
            logger: logger,
            metrics: metrics
        )

        let orchestrator = makeOrchestrator(
            config: config,
            state: state,
            telegram: telegram,
            network: network,
            persistence: persistenceCoordinator,
            botUsername: botUsername,
            logger: logger,
            metrics: metrics,
            flags: flags
        )

        let intake = UpdateIntake(metrics: metrics) { [orchestrator] update in
            await orchestrator.dispatch(update: update)
        }

        let webhookSecret = config.webhookSecret ?? UUID().uuidString + UUID().uuidString
        return AppAssembly(
            logger: logger,
            flags: flags,
            telegram: telegram,
            botUsername: botUsername,
            rawPersistence: rawPersistence,
            orchestrator: orchestrator,
            intake: intake,
            mode: try resolveMode(config: config, webhookSecret: webhookSecret),
            webhookSecret: webhookSecret,
            // `/metrics` reports revenue, funnel counts and subscriber tallies on
            // the same public domain the webhook uses. Falling back to the webhook
            // secret means it is never open by accident — that value is either
            // operator-set or the random one generated above, which nobody can guess.
            metricsToken: config.metricsToken ?? webhookSecret
        )
    }

    // MARK: - Factories

    static func makeTelegram(
        config: AppConfig,
        network: NetworkClient,
        metrics: RuntimeMetrics
    ) -> TelegramHTTPGateway {
        TelegramHTTPGateway(
            network: network,
            botToken: config.telegramToken,
            apiBase: config.telegramAPIBase,
            rateLimiter: TelegramRateLimiter(),
            metrics: metrics
        )
    }

    static func makeStore(config: AppConfig, botUsername: String) async -> ChatContextStore {
        let state = ChatContextStore(
            ownerUsername: ownerUsername,
            ownerUserID: config.ownerUserID,
            model: "google/gemini-3-flash-preview",
            systemPrompt: systemPrompt,
            formatOptions: formatOptions,
            companyChatId: config.companyChatId,
            companyMembers: companyMembers,
            // 20 messages: enough for the bot to follow a real conversation.
            // The value is the owner's lever (it re-sends every remembered
            // message on every turn), so users no longer set it themselves.
            defaultHistoryLength: 20,
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
        return state
    }

    /// Without Supabase the bot runs memory-only; that is a supported mode, not
    /// a failure, so it only logs.
    static func makePersistence(
        config: AppConfig,
        state: ChatContextStore,
        network: NetworkClient,
        logger: LoggerPort,
        metrics: RuntimeMetrics
    ) -> (StatePersistencePort?, PersistenceCoordinator?) {
        guard let supabaseURL = config.supabaseURL, let supabaseKey = config.supabaseKey else {
            logger.info("Supabase persistence disabled (missing SUPABASE_URL or key)")
            return (nil, nil)
        }
        if config.usesAnonSupabaseKey {
            logger.warning("using SUPABASE_ANON_KEY — create SUPABASE_SERVICE_KEY and enable RLS (see DEPLOY.md)")
        }
        let supabase = SupabaseStatePersistence(
            network: network,
            baseURL: supabaseURL,
            apiKey: supabaseKey
        )
        let coordinator = PersistenceCoordinator(
            store: state,
            persistence: supabase,
            logger: logger,
            metrics: metrics
        )
        logger.info("Supabase persistence enabled (row schema, write-behind)")
        return (supabase, coordinator)
    }

    static func makeOrchestrator(
        config: AppConfig,
        state: ChatContextStore,
        telegram: TelegramHTTPGateway,
        network: NetworkClient,
        persistence: PersistenceCoordinator?,
        botUsername: String,
        logger: LoggerPort,
        metrics: RuntimeMetrics,
        flags: RuntimeFlags
    ) -> BotOrchestrator {
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
            logger: logger,
            persistence: persistence
        )

        return BotOrchestrator(
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
            metrics: metrics,
            flags: flags,
            generationLimiter: generationLimiter,
            botUsername: botUsername,
            formatOptions: formatOptions,
            modelPriceMonitor: modelPriceMonitor,
            cryptoService: cryptoService,
            cryptoMonitor: makeCryptoMonitor(
                config: config,
                state: state,
                service: cryptoService,
                network: network,
                logger: logger
            )
        )
    }

    static func makeCryptoMonitor(
        config: AppConfig,
        state: ChatContextStore,
        service: CryptoPaymentService,
        network: NetworkClient,
        logger: LoggerPort
    ) -> CryptoPaymentMonitor {
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

        return CryptoPaymentMonitor(
            state: state,
            service: service,
            logger: logger,
            tonExplorer: tonExplorer,
            bscExplorer: bscExplorer,
            ethExplorer: ethExplorer,
            tronExplorer: tronExplorer
        )
    }

    /// Intake mode: webhook in production (Railway provides the domain),
    /// polling for local development.
    static func resolveMode(config: AppConfig, webhookSecret: String) throws -> IntakeRunMode {
        switch config.updateMode {
        case .webhook:
            guard let base = config.webhookPublicURL else {
                throw AppBootstrapError.webhookModeWithoutPublicURL
            }
            return .webhook(publicBaseURL: base, secret: webhookSecret)
        case .polling:
            return .polling
        case .auto:
            if let base = config.webhookPublicURL {
                return .webhook(publicBaseURL: base, secret: webhookSecret)
            }
            return .polling
        }
    }

    /// `/health`, `/ready`, token-guarded `/metrics` and the webhook endpoint.
    func makeHTTPServer(port: Int) -> AppHTTPServer {
        AppHTTPServer(port: port) { [orchestrator, intake, telegram, flags, webhookSecret, metricsToken] head, body in
            let path = head.uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
            switch (head.method, path) {
            case (.GET, "/health"), (.HEAD, "/health"):
                return .ok("OK")

            case (.GET, "/ready"):
                return flags.ready.value
                    ? .ok("ready")
                    : AppHTTPResponse(status: .serviceUnavailable, body: "starting")

            case (.GET, "/metrics"):
                let presented = head.headers.first(name: "Authorization")
                    .map { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : $0 }
                    ?? head.headers.first(name: "X-Metrics-Token")
                guard SecretGuard.constantTimeEquals(presented, metricsToken) else {
                    return AppHTTPResponse(status: .unauthorized, body: "unauthorized")
                }
                let report = await orchestrator.metricsReport()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let json = (try? encoder.encode(report)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                return .json(json)

            case (.POST, WebhookEndpoint.path):
                guard SecretGuard.constantTimeEquals(
                    head.headers.first(name: WebhookEndpoint.secretHeader),
                    webhookSecret
                ) else {
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
    }

    private static func presets<T: CustomStringConvertible>(from values: [T]) -> [Preset] {
        values.map { Preset(display: String(describing: $0), value: String(describing: $0)) }
    }
}
