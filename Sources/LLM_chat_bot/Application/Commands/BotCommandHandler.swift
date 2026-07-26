import Foundation

// Slash commands. Wiring, role gates and the shared send helper live here;
// the command bodies are split across BotCommandHandler+*.swift by area.

final class BotCommandHandler: @unchecked Sendable {
    let telegram: TelegramGatewayPort
    let state: ChatContextStore
    let gateways: ProviderGatewayRegistry
    let botUsername: String
    let formatOptions: String
    let menuHandler: BotMenuHandler
    let modelPriceMonitor: ModelPriceMonitor?
    let cryptoService: CryptoPaymentService?
    let reminderService: SubscriptionReminderService?

    init(
        telegram: TelegramGatewayPort,
        state: ChatContextStore,
        gateways: ProviderGatewayRegistry,
        botUsername: String,
        formatOptions: String,
        menuHandler: BotMenuHandler,
        modelPriceMonitor: ModelPriceMonitor? = nil,
        cryptoService: CryptoPaymentService? = nil,
        reminderService: SubscriptionReminderService? = nil
    ) {
        self.telegram = telegram
        self.state = state
        self.gateways = gateways
        self.botUsername = botUsername
        self.formatOptions = formatOptions
        self.menuHandler = menuHandler
        self.modelPriceMonitor = modelPriceMonitor
        self.cryptoService = cryptoService
        self.reminderService = reminderService
    }

    func handleIfCommand(text: String?, chatKey: ChatKey, fromUser: TelegramUser?, isPrivate: Bool) async throws -> Bool {
        guard let text else {
            return false
        }

        // The test-mode suffix disambiguates multiple bot copies inside one group.
        // Private chats only ever talk to a single copy, so commands must work
        // bare (`/menu`) regardless of any inherited default suffix.
        let suffix = isPrivate ? nil : await state.suffix(chatKey: chatKey)

        let parsed = ParsedBotCommand.parse(
            from: text,
            botUsername: botUsername,
            suffix: suffix
        )

        guard parsed.name != .unknown, parsed.name != .mention else {
            return false
        }

        try await handle(parsed, chatKey: chatKey, fromUser: fromUser)
        return true
    }

    /// Storage key of whoever is issuing the command, userID first. Every stored
    /// record — roles, ownership, wallets — is keyed this way, and someone with
    /// no @username has nothing else to be recognised by; passing the raw handle
    /// silently fails every gate for them (CLAUDE.md §6). Store methods take a
    /// key through their `username:` parameter unchanged.
    /// Reply when the caller's storage key cannot be resolved at all (no user
    /// on the update). It used to read "У вас не задан @username", which is
    /// both wrong — identity is the userID (§6) — and a dead end.
    static let unknownAccountNotice =
        "Не удалось определить ваш аккаунт. Напишите боту любое сообщение в личке и повторите команду."

    func actorKey(_ user: TelegramUser?) async -> String? {
        if let userID = user?.id { return state.userKey(userID: userID) }
        return await state.userKey(username: user?.username)
    }

    /// Alias used where the caller means "which tenant owns this" rather than
    /// "who is asking" — same key, clearer at the call site.
    func ownerKey(for user: TelegramUser?) async -> String? {
        await actorKey(user)
    }

    func isSuperAdmin(_ user: TelegramUser?) async -> Bool {
        await state.isSuperAdmin(username: actorKey(user))
    }

    func isAdmin(_ user: TelegramUser?, chatID: Int) async -> Bool {
        await state.isAdmin(username: actorKey(user), chatID: chatID)
    }

    func requireAdmin(_ user: TelegramUser?, chatKey: ChatKey) async throws -> Bool {
        guard await isAdmin(user, chatID: chatKey.chatID) else {
            try await sendUserFeedback(chatKey: chatKey, text: "🔒 Команда только для администратора.")
            return false
        }
        return true
    }

    func sendUserFeedback(chatKey: ChatKey, text: String) async throws {
        _ = try await telegram.sendMessage(
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
