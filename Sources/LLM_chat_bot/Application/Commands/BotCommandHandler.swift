import Foundation

// Slash commands. Wiring, role gates and the shared send helper live here;
// the command bodies are split across BotCommandHandler+*.swift by area.

final class BotCommandHandler: Sendable {
    let telegram: TelegramGatewayPort
    let state: ChatContextStore
    let gateways: ProviderGatewayRegistry
    let botUsername: String
    let formatOptions: String
    let menuHandler: BotMenuHandler
    let modelPriceMonitor: ModelPriceMonitor?
    let cryptoService: CryptoPaymentService?
    let reminderService: SubscriptionReminderService?
    /// See `BotMenuHandler.durability` — the same gate, for `/buy`.
    let durability: LockedValue<StateDurability>
    /// Read-only here: `/balance` shows the last few movements, which is the
    /// whole point of keeping a journal — "почему у меня было $2, а стало
    /// $1.30" has to have an answer the person can see for themselves.
    let ledger: LedgerPort
    /// See `BotMenuHandler.subscriptions`.
    let subscriptions: SubscriptionWriter?

    init(
        telegram: TelegramGatewayPort,
        state: ChatContextStore,
        gateways: ProviderGatewayRegistry,
        botUsername: String,
        formatOptions: String,
        menuHandler: BotMenuHandler,
        modelPriceMonitor: ModelPriceMonitor? = nil,
        cryptoService: CryptoPaymentService? = nil,
        reminderService: SubscriptionReminderService? = nil,
        durability: LockedValue<StateDurability> = LockedValue(.durable),
        ledger: LedgerPort = InMemoryLedger(),
        subscriptions: SubscriptionWriter? = nil
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
        self.durability = durability
        self.ledger = ledger
        self.subscriptions = subscriptions
    }

    /// See `BotMenuHandler.wallets`: `/balance add|set` is a money write, so it
    /// goes through a ledger transaction rather than the store's cache.
    var wallets: WalletWriter {
        WalletWriter(state: state, ledger: ledger, logger: menuHandler.logger)
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
    /// no @key has nothing else to be recognised by; passing the raw handle
    /// silently fails every gate for them (CLAUDE.md §6). Store methods take a
    /// key through their `key:` parameter unchanged.
    /// Reply when the caller's storage key cannot be resolved at all (no user
    /// on the update). It used to read "У вас не задан @username", which is
    /// both wrong — identity is the userID (§6) — and a dead end.
    static let unknownAccountNotice =
        "Не удалось определить ваш аккаунт. Напишите боту любое сообщение в личке и повторите команду."

    func actorKey(_ user: TelegramUser?) async -> UserKey? {
        if let userID = user?.id { return state.userKey(userID: userID) }
        return await state.userKey(forHandle: user?.username)
    }

    /// Alias used where the caller means "which tenant owns this" rather than
    /// "who is asking" — same key, clearer at the call site.
    func ownerKey(for user: TelegramUser?) async -> UserKey? {
        await actorKey(user)
    }

    func isSuperAdmin(_ user: TelegramUser?) async -> Bool {
        await state.isSuperAdmin(actorKey(user))
    }

    func isAdmin(_ user: TelegramUser?, chatID: ChatID) async -> Bool {
        await state.isAdmin(actorKey(user), chatID: chatID)
    }

    func requireAdmin(_ user: TelegramUser?, chatKey: ChatKey) async throws -> Bool {
        guard await isAdmin(user, chatID: chatKey.chatID) else {
            try await sendUserFeedback(chatKey: chatKey, text: Texts.adminOnlyCommand)
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

// Subscription dates and winback offers are not write-behind state: they live
// in columns only the money transaction writes (§10.2). These four go through
// `SubscriptionWriter` so a super-admin's change is still there after a
// restart; without one wired (tests, a bot with no database) they fall back to
// the in-memory path, which is all there is to change anyway.
extension BotCommandHandler {
    func extendSubscription(key: UserKey, days: Int) async -> Date? {
        if let subscriptions { return await subscriptions.extend(key: key, days: days) }
        return await state.extendTenantSubscription(key, days: days)
    }

    func setSubscriptionUnlimited(key: UserKey) async -> Bool {
        if let subscriptions { return await subscriptions.setUnlimited(key: key) }
        return await state.setTenantUnlimited(key)
    }

    func expireSubscription(key: UserKey) async -> Bool {
        if let subscriptions { return await subscriptions.expire(key: key) }
        return await state.expireTenantSubscription(key)
    }

    func clearWinbackDiscounts() async -> Int {
        if let subscriptions { return await subscriptions.clearAllWinback() }
        return await state.clearAllWinbackDiscounts()
    }
}
