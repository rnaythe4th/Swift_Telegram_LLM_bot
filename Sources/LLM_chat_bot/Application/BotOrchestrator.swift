import Foundation

final class BotOrchestrator: @unchecked Sendable {
    private let telegram: TelegramGatewayPort
    private let state: ChatContextStore
    private let persistence: StatePersistencePort?
    private let logger: LoggerPort
    private let callbackHandler: BotCallbackHandler
    private let commandHandler: BotCommandHandler
    private let generationCoordinator: GenerationCoordinator
    private let updateDispatcher = ChatUpdateDispatcher()
    private var photoAlbumBuffer = TelegramPhotoAlbumBuffer()

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
        formatOptions: String
    ) {
        self.telegram = telegram
        self.state = state
        self.persistence = persistence
        self.logger = logger

        let gatewayRegistry = ProviderGatewayRegistry(providers: providers)
        let menuHandler = BotMenuHandler(
            telegram: telegram,
            state: state,
            gateways: gatewayRegistry,
            logger: logger,
            formatOptions: formatOptions
        )

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
            menuHandler: menuHandler
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

    private func route(message: TelegramMessage, chatKey: ChatKey) async throws {
        if message.chat.type == "private" {
            let userID = message.from?.id ?? 0
            let username = message.from?.username
            let isAdmin = await state.isAdmin(username: username)
            let isWhitelisted = await state.isWhitelisted(userID: userID)

            guard isAdmin || isWhitelisted else {
                _ = try? await telegram.sendMessage(
                    .init(
                        chatID: chatKey.chatID,
                        threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                        replyTo: nil,
                        text: """
                        🔒 <b>Доступ закрыт</b>

                        Ваш ID · <code>\(userID)</code>

                        Чтобы получить доступ, отправьте этот ID администратору · @maythe4th
                        """,
                        replyMarkup: nil
                    )
                )
                return
            }
        }

        if try await commandHandler.handleIfCommand(text: message.text, chatKey: chatKey, fromUser: message.from) {
            return
        }

        try await generationCoordinator.handleIfNeeded(message: message, chatKey: chatKey)
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
