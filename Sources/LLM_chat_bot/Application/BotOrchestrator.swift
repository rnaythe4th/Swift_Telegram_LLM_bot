import Foundation

/// How the orchestrator receives updates.
enum IntakeRunMode: Sendable {
    /// Production: Telegram pushes updates to our public URL. Undelivered
    /// updates are queued by Telegram for 24h, so deploys lose nothing.
    case webhook(publicBaseURL: String, secret: String)
    /// Development fallback: long polling with the offset persisted in
    /// `bot_config`.
    case polling
}

final class BotOrchestrator: @unchecked Sendable {
    let telegram: TelegramGatewayPort
    let state: ChatContextStore
    let sessionRegistry: SessionRegistry
    let persistence: PersistenceCoordinator?
    let logger: LoggerPort
    let metrics: RuntimeMetrics
    let flags: RuntimeFlags
    let callbackHandler: BotCallbackHandler
    let commandHandler: BotCommandHandler
    let generationCoordinator: GenerationCoordinator
    let menuHandler: BotMenuHandler
    let updateDispatcher = ChatUpdateDispatcher()
    let modelPriceMonitor: ModelPriceMonitor?
    let cryptoMonitor: CryptoPaymentMonitor?
    let reminderService: SubscriptionReminderService
    let botUsername: String

    let backgroundTasks = LockedValue<[Task<Void, Never>]>([])
    let shutdownStarted = LockedValue(false)
    /// Set once `run` starts, so shutdown can drain the intake it feeds.
    let activeIntake = LockedValue<UpdateIntake?>(nil)

    init(
        telegram: TelegramGatewayPort,
        state: ChatContextStore,
        sessionRegistry: SessionRegistry,
        mediaResolver: MediaResolverPort,
        providers: [ServiceProvider: ProviderGatewayPort],
        persistence: PersistenceCoordinator?,
        logger: LoggerPort,
        metrics: RuntimeMetrics,
        flags: RuntimeFlags,
        generationLimiter: GenerationLimiter,
        botUsername: String,
        formatOptions: String,
        modelPriceMonitor: ModelPriceMonitor? = nil,
        cryptoService: CryptoPaymentService? = nil,
        cryptoMonitor: CryptoPaymentMonitor? = nil
    ) {
        self.telegram = telegram
        self.state = state
        self.sessionRegistry = sessionRegistry
        self.persistence = persistence
        self.logger = logger
        self.metrics = metrics
        self.flags = flags
        self.modelPriceMonitor = modelPriceMonitor
        self.cryptoMonitor = cryptoMonitor
        self.botUsername = botUsername

        let gatewayRegistry = ProviderGatewayRegistry(providers: providers)
        let reminderService = SubscriptionReminderService(
            telegram: telegram,
            state: state,
            logger: logger,
            metrics: metrics
        )
        self.reminderService = reminderService

        let menuHandler = BotMenuHandler(
            telegram: telegram,
            state: state,
            gateways: gatewayRegistry,
            logger: logger,
            formatOptions: formatOptions,
            botUsername: botUsername,
            modelPriceMonitor: modelPriceMonitor,
            cryptoService: cryptoService,
            reminderService: reminderService
        )

        self.menuHandler = menuHandler

        self.callbackHandler = BotCallbackHandler(
            telegram: telegram,
            state: state,
            sessionRegistry: sessionRegistry,
            logger: logger,
            menuHandler: menuHandler
        )

        self.commandHandler = BotCommandHandler(
            telegram: telegram,
            state: state,
            gateways: gatewayRegistry,
            botUsername: botUsername,
            formatOptions: formatOptions,
            menuHandler: menuHandler,
            modelPriceMonitor: modelPriceMonitor,
            cryptoService: cryptoService,
            reminderService: reminderService
        )
        self.generationCoordinator = GenerationCoordinator(
            telegram: telegram,
            state: state,
            sessionRegistry: sessionRegistry,
            mediaResolver: mediaResolver,
            gateways: gatewayRegistry,
            logger: logger,
            botUsername: botUsername,
            generationLimiter: generationLimiter,
            metrics: metrics
        )
    }
}
