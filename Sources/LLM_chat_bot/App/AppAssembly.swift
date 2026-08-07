import Foundation
import Logging
import PostgresNIO

// Composition root. Every dependency is built here, by hand, in one pass —
// `main` is then just the startup sequence (serve → restore → run → drain).

/// The assembled object graph, plus the two secrets the HTTP surface checks.
struct AppAssembly {
    static let companyMembers = ""
    static let systemPrompt = "Ты — полезный ИИ-ассистент в Telegram. Отвечай по делу, кратко и понятно, без воды и канцелярита. Если вопрос неясен — уточни."
    static let formatOptions = " Ты можешь форматировать свой текст в соответствии с HTML (по документации Telegram bot api). При упоминании или обращении к участникам никогда не ставь @ перед их именами, чтобы не тегать их."

    let logger: LoggerPort
    let flags: RuntimeFlags
    let telegram: TelegramHTTPGateway
    let botUsername: String
    let storage: Storage
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
            config.stateEncryptionKey,
            config.deepseekKey,
            config.routerApiKey,
            config.databaseURL,
            // …and the password on its own: a driver error quotes the
            // credential, not the whole URL the credential came from.
            config.databaseURL.flatMap { DatabaseEndpoint(urlString: $0)?.password },
            config.webhookSecret,
            config.metricsToken,
            config.tonapiKey,
            config.etherscanApiKey,
            config.bscscanApiKey,
            config.trongridApiKey
        ])
    }

    static func build(config: AppConfig, logger: LoggerPort) async throws -> AppAssembly {
        // Before anything reads a stored secret: the key that opens them.
        guard SecretBox.configure(base64Key: config.stateEncryptionKey) else {
            throw AppConfigError.badEncryptionKey
        }
        if config.stateEncryptionKey == nil {
            logger.warning("\(EnvironmentKey.stateEncryptionKey.rawValue) is not set — payment credentials are stored unencrypted; set it before connecting a card provider or a checkout")
        }

        let metrics = RuntimeMetrics()
        let flags = RuntimeFlags()

        let network = NetworkClient()
        let telegram = makeTelegram(config: config, network: network, metrics: metrics)

        let me = try await telegram.getMe()
        guard let botUsername = me.username else {
            throw AppBootstrapError.missingBotUsername
        }

        if config.ownerUserID == nil {
            logger.warning("OWNER_USER_ID is not set — the owner is recognised by @\(config.ownerUsername) alone; set it so root cannot follow the username to somebody else")
        }

        let state = await makeStore(config: config, botUsername: botUsername)
        let storage = makeStorage(config: config, state: state, logger: logger, metrics: metrics)

        let orchestrator = makeOrchestrator(
            config: config,
            state: state,
            telegram: telegram,
            network: network,
            storage: storage,
            botUsername: botUsername,
            // Privacy mode off = Telegram delivers every group message. Listen
            // mode (§5.7) is useless without it and says so on its own page,
            // rather than recording nothing and reading as a bug.
            canReadAllGroupMessages: me.can_read_all_group_messages ?? false,
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
            storage: storage,
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
            ownerUsername: config.ownerUsername,
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

        await state.setPresets(.model, [
            Preset(display: "Gemini 3 Flash preview", value: "google/gemini-3-flash-preview"),
            Preset(display: "Gemini Flash latest", value: "google/gemini-flash-latest"),
            Preset(display: "Gemini 3.1 Flash Lite", value: "google/gemini-3.1-flash-lite-preview"),
            Preset(display: "DeepSeek V4 Pro", value: "deepseek/deepseek-v4-pro"),
            Preset(display: "DeepSeek V4 Flash", value: "deepseek/deepseek-v4-flash"),
            Preset(display: "Grok 4.3", value: "x-ai/grok-4.3"),
        ])
        await state.setPresets(.temp, presets(from: [0.0, 0.5, 1.0, 1.5, 2.0]))
        await state.setPresets(.history, presets(from: [10, 15, 20, 30, 50]))
        await state.setPresets(.role, [
            Preset(display: "Физик Анатолий", value: "Ты физик, тебя зовут Анатолий."),
        ])
        return state
    }

    /// Everything that talks to the database, or the memory-only stand-ins when
    /// there is no `DATABASE_URL`. Memory-only is a supported mode (local
    /// development, a first run) — it just refuses to sell anything (§4.3).
    struct Storage {
        let client: PostgresClient?
        let persistence: PostgresStatePersistence?
        let coordinator: PersistenceCoordinator?
        let ledger: LedgerPort
        let writerLock: WriterLock?

        /// `PostgresClient` is a `Service`: without an active `run()` its pool
        /// never opens a connection and every query waits forever. Starting it
        /// is not optional, and it has to happen before the first query — which
        /// is the schema migration, one line into boot.
        func startPool() -> Task<Void, Never>? {
            guard let client else { return nil }
            return Task { await client.run() }
        }
    }

    static func makeStorage(
        config: AppConfig,
        state: ChatContextStore,
        logger: LoggerPort,
        metrics: RuntimeMetrics
    ) -> Storage {
        guard let urlString = config.databaseURL else {
            logger.warning("DATABASE_URL is not set — state is in-memory only and nothing will be sold")
            return Storage(client: nil, persistence: nil, coordinator: nil, ledger: InMemoryLedger(), writerLock: nil)
        }
        guard let endpoint = DatabaseEndpoint(urlString: urlString) else {
            logger.error("DATABASE_URL is not a usable postgres:// URL — state is in-memory only")
            return Storage(client: nil, persistence: nil, coordinator: nil, ledger: InMemoryLedger(), writerLock: nil)
        }
        if endpoint.looksLikeTransactionPooler {
            // Worth a loud line: in transaction mode the advisory lock returns
            // true and is dropped with the connection, so the single-writer
            // guarantee disappears without a single error anywhere.
            logger.error("DATABASE_URL points at port 6543 (transaction pooler) — use the session pooler on 5432, or the writer lock will not hold (see DEPLOY.md)")
        }

        do {
            let client = PostgresClient(
                configuration: try endpoint.clientConfiguration(maximumConnections: 8),
                backgroundLogger: Logger(label: "postgres") { _ in PostgresLogHandler(sink: logger) }
            )
            let persistence = PostgresStatePersistence(client: client, logger: logger)
            let ledger = PostgresLedger(client: client, logger: logger)
            let coordinator = PersistenceCoordinator(
                store: state,
                persistence: persistence,
                ledger: ledger,
                logger: logger,
                metrics: metrics
            )
            logger.info("postgres persistence enabled at \(endpoint.displayName)")
            return Storage(
                client: client,
                persistence: persistence,
                coordinator: coordinator,
                ledger: ledger,
                writerLock: WriterLock(client: client, logger: logger)
            )
        } catch {
            logger.error("could not configure the database connection — state is in-memory only: \(error)")
            return Storage(client: nil, persistence: nil, coordinator: nil, ledger: InMemoryLedger(), writerLock: nil)
        }
    }

    static func makeOrchestrator(
        config: AppConfig,
        state: ChatContextStore,
        telegram: TelegramHTTPGateway,
        network: NetworkClient,
        storage: Storage,
        botUsername: String,
        canReadAllGroupMessages: Bool = true,
        logger: LoggerPort,
        metrics: RuntimeMetrics,
        flags: RuntimeFlags
    ) -> BotOrchestrator {
        let persistence = storage.coordinator
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

        // One post-payment routine for every method (§17): Stars and card go
        // through it from the orchestrator, crypto from its monitor, the hosted
        // checkout from its callback endpoint.
        let fulfillment = PaymentFulfillmentService(
            state: state,
            telegram: telegram,
            ledger: storage.ledger,
            persistence: persistence,
            metrics: metrics,
            logger: logger,
            durability: flags.durability
        )

        let cryptoService = CryptoPaymentService(
            state: state,
            network: network,
            telegram: telegram,
            logger: logger,
            fulfillment: fulfillment,
            persistence: persistence
        )

        let externalPayments = ExternalPaymentService(
            state: state,
            resolver: ExternalCheckoutRegistry(),
            fulfillment: fulfillment,
            telegram: telegram,
            logger: logger,
            metrics: metrics,
            // The vendor answers over the public internet, so without a public
            // address there is nothing to configure — the settings page says so
            // rather than printing a URL that resolves to a laptop.
            publicBaseURL: config.webhookPublicURL,
            durability: flags.durability
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
            canReadAllGroupMessages: canReadAllGroupMessages,
            formatOptions: formatOptions,
            ledger: storage.ledger,
            fulfillment: fulfillment,
            modelPriceMonitor: modelPriceMonitor,
            cryptoService: cryptoService,
            cryptoMonitor: makeCryptoMonitor(
                config: config,
                state: state,
                service: cryptoService,
                network: network,
                logger: logger
            ),
            externalPayments: externalPayments
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
                // A scraper asks for text; a person (or the old tooling) gets
                // JSON. Same numbers, same token, no second endpoint.
                let accept = head.headers.first(name: "Accept") ?? ""
                if accept.contains("text/plain") {
                    return AppHTTPResponse(
                        status: .ok,
                        contentType: "text/plain; version=0.0.4; charset=utf-8",
                        body: await orchestrator.prometheusReport()
                    )
                }
                let report = await orchestrator.metricsReport()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let json = (try? encoder.encode(report)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                return .json(json)

            // Hosted-checkout notification (§7). Authenticated by the vendor's
            // signature inside the service — there is no shared secret header
            // to check here, and the aggregator posts a form, not JSON.
            case (.POST, let path) where ExternalPaymentEndpoint.vendor(forPath: path) != nil,
                 (.GET, let path) where ExternalPaymentEndpoint.vendor(forPath: path) != nil:
                guard let vendor = ExternalPaymentEndpoint.vendor(forPath: path) else {
                    return AppHTTPResponse(status: .notFound, body: "not found")
                }
                guard let service = orchestrator.externalPayments else {
                    return AppHTTPResponse(status: .serviceUnavailable, body: "not configured")
                }
                // Some cabinets are configured to notify over GET, so both the
                // query string and the body are read; the body wins on conflict.
                var parameters = URLForm.parse(
                    head.uri.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
                )
                for (name, value) in URLForm.parse(String(data: body, encoding: .utf8) ?? "") {
                    parameters[name] = value
                }
                switch await service.handleCallback(vendor: vendor, parameters: parameters) {
                case .acknowledged(let ack):
                    return .ok(ack)
                case .rejected(let reason):
                    return AppHTTPResponse(status: .badRequest, body: reason)
                }

            case (.POST, WebhookEndpoint.path):
                guard SecretGuard.constantTimeEquals(
                    head.headers.first(name: WebhookEndpoint.secretHeader),
                    webhookSecret
                ) else {
                    return AppHTTPResponse(status: .unauthorized, body: "bad secret")
                }
                // 503 before restore completes, while draining, and while
                // another instance is still the writer — Telegram holds the
                // update and redelivers once we answer 200 again. That is what
                // makes the handover between two deploys lossless instead of
                // making one of them answer from state it cannot save.
                guard flags.ready.value,
                      !flags.draining.value,
                      flags.durability.value.acceptsUpdates else {
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
