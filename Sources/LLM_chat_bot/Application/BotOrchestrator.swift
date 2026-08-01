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

final class BotOrchestrator: Sendable {
    let telegram: TelegramGatewayPort
    let state: ChatContextStore
    let sessionRegistry: SessionRegistry
    let persistence: PersistenceCoordinator?
    let logger: LoggerPort
    let metrics: RuntimeMetrics
    let flags: RuntimeFlags
    let alerter: OwnerAlerter
    /// Held for the process lifetime once acquired, released on shutdown so the
    /// next instance can start writing immediately (§3.1).
    let writerLock = LockedValue<WriterLock?>(nil)
    /// The loader, kept so a replica waiting for the handover can restore state
    /// the moment it becomes the writer.
    let storedState = LockedValue<PostgresStatePersistence?>(nil)
    /// Where money is written — also the only thing that can check its own
    /// books (`reconcile`).
    let ledger: LedgerPort
    let callbackHandler: BotCallbackHandler
    let commandHandler: BotCommandHandler
    let generationCoordinator: GenerationCoordinator
    let menuHandler: BotMenuHandler
    let updateDispatcher = ChatUpdateDispatcher()
    let modelPriceMonitor: ModelPriceMonitor?
    let cryptoMonitor: CryptoPaymentMonitor?
    let reminderService: SubscriptionReminderService
    /// What every payment path does after the money lands (§17).
    let fulfillment: PaymentFulfillmentService
    let externalPayments: ExternalPaymentService?
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
        /// Where money is written. Defaults to the in-memory ledger so tests
        /// (and a bot with no database) keep the same shape without one.
        ledger: LedgerPort = InMemoryLedger(),
        /// Shared with the crypto and hosted-checkout services by the
        /// composition root. It holds no state of its own (everything lives in
        /// the store), so tests may let it be built here.
        fulfillment: PaymentFulfillmentService? = nil,
        modelPriceMonitor: ModelPriceMonitor? = nil,
        cryptoService: CryptoPaymentService? = nil,
        cryptoMonitor: CryptoPaymentMonitor? = nil,
        externalPayments: ExternalPaymentService? = nil
    ) {
        self.telegram = telegram
        self.state = state
        self.sessionRegistry = sessionRegistry
        self.persistence = persistence
        self.logger = logger
        self.metrics = metrics
        self.flags = flags
        self.alerter = OwnerAlerter(telegram: telegram, state: state, logger: logger)
        self.ledger = ledger
        self.modelPriceMonitor = modelPriceMonitor
        self.cryptoMonitor = cryptoMonitor
        self.fulfillment = fulfillment ?? PaymentFulfillmentService(
            state: state,
            telegram: telegram,
            ledger: ledger,
            persistence: persistence,
            metrics: metrics,
            logger: logger
        )
        self.externalPayments = externalPayments
        self.botUsername = botUsername

        let gatewayRegistry = ProviderGatewayRegistry(providers: providers)
        // Subscription dates and winback offers live in columns the write-behind
        // flush never touches, so every path that changes one goes through this
        // (§10.2) — otherwise the change is correct until the next restart.
        let subscriptions = SubscriptionWriter(
            state: state,
            ledger: ledger,
            logger: logger,
            alerter: self.alerter
        )
        let reminderService = SubscriptionReminderService(
            telegram: telegram,
            state: state,
            subscriptions: subscriptions,
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
            reminderService: reminderService,
            externalPayments: externalPayments,
            durability: flags.durability,
            subscriptions: subscriptions
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
            reminderService: reminderService,
            durability: flags.durability,
            ledger: ledger,
            subscriptions: subscriptions
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
            ledger: ledger,
            alerter: alerter,
            metrics: metrics
        )
    }
}
