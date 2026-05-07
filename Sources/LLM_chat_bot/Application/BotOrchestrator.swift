import Foundation

final class BotOrchestrator: @unchecked Sendable {
    private let telegram: TelegramGatewayPort
    private let state: ChatContextStore
    private let persistence: StatePersistencePort?
    private let logger: LoggerPort
    private let callbackHandler: BotCallbackHandler
    private let commandHandler: BotCommandHandler
    private let generationCoordinator: GenerationCoordinator
    private let menuHandler: BotMenuHandler
    private let updateDispatcher = ChatUpdateDispatcher()
    private var photoAlbumBuffer = TelegramPhotoAlbumBuffer()
    private let modelPriceMonitor: ModelPriceMonitor?
    private let cryptoMonitor: CryptoPaymentMonitor?

    private static let backupIntervalSeconds: Int64 = 60

    init(
        telegram: TelegramGatewayPort,
        state: ChatContextStore,
        sessionRegistry: SessionRegistry,
        mediaResolver: MediaResolverPort,
        providers: [ServiceProvider: ProviderGatewayPort],
        persistence: StatePersistencePort?,
        logger: LoggerPort,
        botUsername: String,
        formatOptions: String,
        modelPriceMonitor: ModelPriceMonitor? = nil,
        cryptoService: CryptoPaymentService? = nil,
        cryptoMonitor: CryptoPaymentMonitor? = nil
    ) {
        self.telegram = telegram
        self.state = state
        self.persistence = persistence
        self.logger = logger
        self.modelPriceMonitor = modelPriceMonitor
        self.cryptoMonitor = cryptoMonitor

        let gatewayRegistry = ProviderGatewayRegistry(providers: providers)
        let menuHandler = BotMenuHandler(
            telegram: telegram,
            state: state,
            gateways: gatewayRegistry,
            logger: logger,
            formatOptions: formatOptions,
            modelPriceMonitor: modelPriceMonitor,
            cryptoService: cryptoService
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
            cryptoService: cryptoService
        )
        self.generationCoordinator = GenerationCoordinator(
            telegram: telegram,
            state: state,
            sessionRegistry: sessionRegistry,
            mediaResolver: mediaResolver,
            gateways: gatewayRegistry,
            logger: logger,
            botUsername: botUsername
        )
    }

    func run() async {
        let restored = await restoreState()
        var currentOffset = restored.offset
        let lastBackupOffset = LockedValue(currentOffset ?? 0)
        let backupsEnabled = restored.canBackup

        await modelPriceMonitor?.performInitialFetch()

        let priceMonitorTask = Task { [weak self] in
            await self?.modelPriceMonitor?.run()
        }

        let cryptoMonitorTask = Task { [weak self] in
            await self?.cryptoMonitor?.run()
        }

        let backupTask = Task { [weak self] in
            guard let self, let persistence = self.persistence, backupsEnabled else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.backupIntervalSeconds) * 1_000_000_000)
                let offset = lastBackupOffset.value
                let dateFormatter = ISO8601DateFormatter()
                dateFormatter.timeZone = TimeZone(abbreviation: "UTC")
                let timeString = dateFormatter.string(from: Date())
                let success: String
                do {
                    let snapshot = await self.state.exportSnapshot(telegramUpdateOffset: offset)
                    try await persistence.saveState(snapshot)
                    success = "✓ Успешно"
                } catch {
                    self.logger.error("state backup failed: \(error)")
                    success = "✗ " + UserFacingError.message(error)
                }
                let chatKeys = await self.state.chatsWithBackupNotify()
                for chatKey in chatKeys {
                    _ = try? await self.telegram.sendMessage(
                        .init(
                            chatID: chatKey.chatID,
                            threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                            replyTo: nil,
                            text: "💾 <b>Бэкап</b> · \(success)\n<i>\(timeString) · offset \(offset)</i>",
                            replyMarkup: nil
                        )
                    )
                }
            }
        }

        while true {
            do {
                let updates = try await telegram.getUpdates(offset: currentOffset)
                if let maxUpdateID = updates.map(\.update_id).max() {
                    currentOffset = maxUpdateID + 1
                    lastBackupOffset.value = currentOffset!
                }

                for update in photoAlbumBuffer.ingest(updates) {
                    await self.dispatch(update: update)
                }
            } catch {
                logger.error("getUpdates error: \(error)")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }

        priceMonitorTask.cancel()
        cryptoMonitorTask.cancel()
        backupTask.cancel()
    }

    private struct RestoreResult {
        let offset: Int?
        let canBackup: Bool
    }

    private func restoreState() async -> RestoreResult {
        guard let persistence else { return RestoreResult(offset: nil, canBackup: true) }
        do {
            guard let snapshot = try await persistence.loadState() else {
                logger.info("no saved state found, starting fresh")
                return RestoreResult(offset: nil, canBackup: true)
            }
            await state.restoreFromSnapshot(snapshot)
            logger.info("state restored (offset: \(snapshot.telegramUpdateOffset), chats: \(snapshot.contexts.count))")
            return RestoreResult(offset: snapshot.telegramUpdateOffset, canBackup: true)
        } catch {
            logger.error("state restore failed; backups disabled to avoid overwriting saved state: \(error)")
            return RestoreResult(offset: nil, canBackup: false)
        }
    }

    private func dispatch(update: TelegramUpdate) async {
        if let callback = update.callback_query {
            Task {
                await self.callbackHandler.handleIfSupported(callback)
            }
            return
        }

        if let preCheckout = update.pre_checkout_query {
            Task {
                await self.handlePreCheckoutQuery(preCheckout)
            }
            return
        }

        guard let message = update.message else { return }
        let chatKey = ChatKey(chatID: message.chat.id, threadID: message.message_thread_id ?? 0)

        await updateDispatcher.submit(chatKey: chatKey) { [self] in
            do {
                try await route(message: message, chatKey: chatKey)
            } catch {
                logger.error("routeMessage failed: \(error)")
                if !(error is CancellationError) {
                    let text = "⚠️ " + UserFacingError.message(error)
                    _ = try? await telegram.sendMessage(
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
        }
    }

    private func handlePreCheckoutQuery(_ query: TelegramPreCheckoutQuery) async {
        do {
            let price = await state.starsPrice()
            if let price, query.total_amount == price {
                try await telegram.answerPreCheckoutQuery(queryID: query.id, ok: true, errorMessage: nil)
            } else {
                try await telegram.answerPreCheckoutQuery(queryID: query.id, ok: false, errorMessage: "Цена изменилась. Попробуйте снова с командой /buy.")
            }
        } catch {
            logger.error("answerPreCheckoutQuery failed: \(error)")
            try? await telegram.answerPreCheckoutQuery(queryID: query.id, ok: false, errorMessage: "Внутренняя ошибка. Попробуйте позже.")
        }
    }

    private func route(message: TelegramMessage, chatKey: ChatKey) async throws {
        let senderUsername = message.from?.username
        let senderUserID = message.from?.id

        // Successful payment — handle before access gate since payer isn't a tenant yet
        if let payment = message.successful_payment {
            await handleSuccessfulPayment(message: message, payment: payment)
            return
        }

        // /buy and /start are allowed before the access gate
        if let text = message.text {
            let isBuyOrStart = text.hasPrefix("/buy") || text.hasPrefix("/start")
            if isBuyOrStart {
                _ = try? await commandHandler.handleIfCommand(text: text, chatKey: chatKey, fromUser: message.from)
                return
            }
        }

        // Auto-assign unowned private chat to sender's tenant if they own one
        await state.autoAssignIfNeeded(chatID: chatKey.chatID, senderUsername: senderUsername, senderUserID: senderUserID)

        if try await commandHandler.handleIfCommand(text: message.text, chatKey: chatKey, fromUser: message.from) {
            return
        }

        if let text = message.text, await menuHandler.processTextInput(text: text, chatKey: chatKey, username: message.from?.username) {
            return
        }

        try await generationCoordinator.handleIfNeeded(message: message, chatKey: chatKey)
    }

    private func handleSuccessfulPayment(message: TelegramMessage, payment: TelegramSuccessfulPayment) async {
        guard let username = message.from?.username else {
            _ = try? await telegram.sendMessage(.init(
                chatID: message.chat.id,
                threadID: message.message_thread_id,
                replyTo: nil,
                text: "✅ Оплата получена! Но у вас нет @username в Telegram — обратитесь к администратору для активации доступа.",
                replyMarkup: nil
            ))
            return
        }
        await state.registerTenant(username: username)
        _ = try? await telegram.sendMessage(.init(
            chatID: message.chat.id,
            threadID: message.message_thread_id,
            replyTo: nil,
            text: """
            ✅ <b>Оплата получена!</b>

            Добро пожаловать, @\(username)!
            Ваша персональная копия бота активирована.

            Используйте /menu для настройки или просто начните общение.
            """,
            replyMarkup: nil
        ))
        logger.info("new tenant registered via Stars payment: @\(username), amount: \(payment.total_amount) XTR")
    }
}

private final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private var _value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self._value = value
    }

    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
