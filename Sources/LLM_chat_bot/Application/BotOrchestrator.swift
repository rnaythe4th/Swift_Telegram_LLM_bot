import Foundation

final class BotOrchestrator: @unchecked Sendable {
    private let telegram: TelegramGatewayPort
    private let state: ChatContextStore
    private let logger: LoggerPort
    private let callbackHandler: BotCallbackHandler
    private let commandHandler: BotCommandHandler
    private let generationCoordinator: GenerationCoordinator
    private let updateDispatcher = ChatUpdateDispatcher()
    private var photoAlbumBuffer = TelegramPhotoAlbumBuffer()
    
    init(
        telegram: TelegramGatewayPort,
        state: ChatContextStore,
        sessionRegistry: SessionRegistry,
        mediaResolver: MediaResolverPort,
        providers: [ServiceProvider: ProviderGatewayPort],
        logger: LoggerPort,
        botUsername: String,
        formatOptions: String
    ) {
        self.telegram = telegram
        self.state = state
        self.logger = logger
        
        let gatewayRegistry = ProviderGatewayRegistry(providers: providers)
        let menuHandler = BotMenuHandler(
            telegram: telegram,
            state: state,
            gateways: gatewayRegistry,
            logger: logger
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
        var currentOffset: Int? = nil
        
        while true {
            do {
                let updates = try await telegram.getUpdates(offset: currentOffset)
                if let maxUpdateID = updates.map(\.update_id).max() {
                    currentOffset = maxUpdateID + 1
                }
                
                for update in photoAlbumBuffer.ingest(updates) {
                    await self.dispatch(update: update)
                }
            } catch {
                logger.error("getUpdates error: \(error)")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
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
                        text: "Доступ запрещён. Ваш ID: \(userID)\nОбратитесь к администратору @maythe4th для добавления в белый список.",
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
