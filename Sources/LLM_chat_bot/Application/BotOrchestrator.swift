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
    private let telegram: TelegramGatewayPort
    private let state: ChatContextStore
    private let sessionRegistry: SessionRegistry
    private let persistence: PersistenceCoordinator?
    private let logger: LoggerPort
    private let metrics: RuntimeMetrics
    private let flags: RuntimeFlags
    private let callbackHandler: BotCallbackHandler
    private let commandHandler: BotCommandHandler
    private let generationCoordinator: GenerationCoordinator
    private let menuHandler: BotMenuHandler
    private let updateDispatcher = ChatUpdateDispatcher()
    private let modelPriceMonitor: ModelPriceMonitor?
    private let cryptoMonitor: CryptoPaymentMonitor?
    private let reminderService: SubscriptionReminderService
    private let botUsername: String

    private let backgroundTasks = LockedValue<[Task<Void, Never>]>([])
    private let shutdownStarted = LockedValue(false)
    /// Set once `run` starts, so shutdown can drain the intake it feeds.
    private let activeIntake = LockedValue<UpdateIntake?>(nil)

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

    // MARK: - Boot: restore state (with one-time legacy migration)

    /// Loads state from the row-based schema; if those tables are empty and a
    /// legacy blob exists, imports it once and flushes everything as rows.
    /// On load failure the bot runs memory-only (persistence loop stays off)
    /// rather than risking partial overwrites of good data.
    func bootstrapState(rawPersistence: StatePersistencePort?) async -> Bool {
        guard let rawPersistence, let persistence else {
            logger.warning("persistence disabled (missing Supabase credentials) — state is in-memory only")
            return false
        }
        do {
            let stored = try await rawPersistence.loadEverything()
            if stored.isEmpty {
                if let legacy = try await rawPersistence.loadLegacySnapshot() {
                    await state.restoreFromSnapshot(legacy)
                    await state.markAllDirty()
                    await persistence.flushNow()
                    logger.info("migrated legacy snapshot to row schema (chats: \(legacy.contexts.count))")
                } else {
                    logger.info("no saved state found, starting fresh")
                }
            } else {
                await state.restore(from: stored)
                logger.info("state restored (chats: \(stored.contexts.count), tenants: \(stored.tenants.count))")
            }
            return true
        } catch {
            logger.error("state restore failed — running memory-only, writes disabled to protect stored data: \(error)")
            return false
        }
    }

    // MARK: - Run

    func run(mode: IntakeRunMode, intake: UpdateIntake, persistenceHealthy: Bool) async {
        activeIntake.value = intake
        if persistenceHealthy {
            await persistence?.start()
        }

        await modelPriceMonitor?.performInitialFetch()

        var tasks: [Task<Void, Never>] = []
        tasks.append(Task { [weak self] in
            await self?.modelPriceMonitor?.run()
        })
        tasks.append(Task { [weak self] in
            await self?.cryptoMonitor?.run()
        })
        if persistenceHealthy {
            tasks.append(Task { [weak self] in
                await self?.runPersistenceNotifyLoop()
            })
        }
        // Renewal reminders / winback (roadmap step 8). Runs regardless of the
        // storage state: notices are deduplicated in memory too, and a
        // memory-only bot still shouldn't let subscriptions lapse silently.
        tasks.append(Task { [weak self] in
            await self?.reminderService.run()
        })
        backgroundTasks.value = tasks

        flags.ready.value = true

        switch mode {
        case .webhook(let publicBaseURL, let secret):
            do {
                let url = publicBaseURL + WebhookEndpoint.path
                try await telegram.setWebhook(
                    url: url,
                    secretToken: secret,
                    allowedUpdates: TelegramUpdateSubscription.allowedUpdates
                )
                logger.info("webhook registered: \(url)")
                // Updates now arrive via AppHTTPServer → intake; park until drain.
                while !flags.draining.value {
                    try? await Task.sleep(for: .seconds(1))
                }
            } catch {
                logger.error("setWebhook failed, falling back to polling: \(error)")
                // A half-registered webhook (or one left by a previous deploy)
                // makes every getUpdates fail with "webhook is active" — the
                // fallback would spin on errors instead of serving anyone.
                try? await telegram.deleteWebhook()
                await runPollingLoop(intake: intake)
            }
        case .polling:
            try? await telegram.deleteWebhook()
            logger.info("long polling started")
            await runPollingLoop(intake: intake)
        }
    }

    private func runPollingLoop(intake: UpdateIntake) async {
        var offset = await state.pollingOffset()
        while !flags.draining.value {
            do {
                let updates = try await telegram.getUpdates(offset: offset)
                if let maxUpdateID = updates.map(\.update_id).max() {
                    let next = maxUpdateID + 1
                    offset = next
                    await state.setPollingOffset(next)
                }
                await intake.enqueue(updates)
            } catch {
                logger.error("getUpdates error: \(error)")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    /// Periodic persistence status for chats that opted into backup
    /// notifications (the write-behind replacement for the old 60s backup
    /// report).
    private func runPersistenceNotifyLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            guard let persistence else { return }
            let chatKeys = await state.chatsWithBackupNotify()
            guard !chatKeys.isEmpty else { continue }
            let line = await persistence.statusLine()
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = TimeZone(abbreviation: "UTC")
            let timeString = formatter.string(from: Date())
            for chatKey in chatKeys {
                _ = try? await telegram.sendMessage(
                    .init(
                        chatID: chatKey.chatID,
                        threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                        replyTo: nil,
                        text: "💾 <b>Хранилище</b> · \(line)\n<i>\(timeString)</i>",
                        replyMarkup: nil
                    )
                )
            }
        }
    }

    // MARK: - Graceful shutdown

    /// SIGTERM path: stop taking updates (webhook answers 503 → Telegram
    /// redelivers after restart), let in-flight generations finish briefly,
    /// then flush all dirty state.
    func shutdown() async {
        let alreadyStarted = shutdownStarted.withLock { started -> Bool in
            let was = started
            started = true
            return was
        }
        guard !alreadyStarted else { return }

        logger.info("shutdown: draining…")
        flags.draining.value = true
        flags.ready.value = false

        // Everything the webhook answered 200 for is ours to finish: Telegram
        // will not redeliver it. Release the album buffer first, then wait for
        // the per-chat queues as well as the in-flight streams — an update
        // sitting in a queue is a message the user sent and never got an answer
        // to, and it leaves no trace anywhere.
        if let intake = activeIntake.value { await intake.shutdown() }

        let deadline = ContinuousClock().now + .seconds(8)
        while ContinuousClock().now < deadline {
            let queued = await updateDispatcher.totalQueuedOperations
            let streaming = await sessionRegistry.activeCount
            if queued == 0, streaming == 0 { break }
            try? await Task.sleep(for: .milliseconds(250))
        }

        for task in backgroundTasks.value {
            task.cancel()
        }

        await persistence?.stop()
        logger.info("shutdown: state flushed, exiting")
    }

    // MARK: - Dispatch

    func dispatch(update: TelegramUpdate) async {
        if let callback = update.callback_query {
            // Every path that carries a user refreshes the identity directory,
            // so a rename can never orphan a wallet or a subscription. Awaited
            // rather than detached: the handler below resolves keys, and it
            // must not race the sighting that produces them.
            let from = callback.from
            await state.identifyUser(userID: from.id, username: from.username, firstName: from.first_name)
            // An onboarding example (roadmap step 9) starts a generation, so it
            // belongs on the message path — same per-chat ordering as if the
            // user had typed the prompt.
            if let data = callback.data,
               case .example(let exampleID)? = BotCallbackAction(rawData: data) {
                Task {
                    await self.handleOnboardingExample(id: exampleID, callback: callback)
                }
                return
            }
            // Other callbacks bypass the per-chat queue on purpose: the stop
            // button must cancel the generation that is blocking that queue.
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

        if let memberUpdate = update.my_chat_member {
            Task {
                await self.handleMyChatMemberUpdate(memberUpdate)
            }
            return
        }

        guard let message = update.message else { return }
        let chatKey = ChatKey(chatID: message.chat.id, threadID: message.message_thread_id ?? 0)

        let result = await updateDispatcher.submit(chatKey: chatKey) { [self] in
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

        if case .rejected(let shouldNotify) = result {
            await metrics.increment(MetricName.updatesDropped)
            logger.warning("chat \(chatKey.chatID) queue full, update dropped")
            if shouldNotify {
                // Fire-and-forget: dispatch() runs on the intake path and must
                // not wait for a rate-limiter slot.
                Task { [telegram] in
                    _ = try? await telegram.sendMessage(
                        .init(
                            chatID: chatKey.chatID,
                            threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                            replyTo: nil,
                            text: "⏳ Слишком много сообщений подряд — часть я пропустил. Дождитесь ответа на предыдущие.",
                            replyMarkup: nil
                        )
                    )
                }
            }
        }
    }

    /// An onboarding example button was tapped (roadmap step 9): echo the prompt
    /// into the chat (Telegram cannot post it as the user) and answer it as a
    /// normal turn — free-tier gate, billing and history all apply.
    private func handleOnboardingExample(id: String, callback: CallbackQuery) async {
        guard let message = callback.message else {
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Кнопка устарела — откройте меню заново: /menu")
            return
        }
        let chatKey = ChatKey(chatID: message.chat.id, threadID: message.message_thread_id ?? 0)

        // Counts the tap (per-example stat + funnel) and resolves the prompt.
        guard let example = await state.recordOnboardingTap(id: id) else {
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Этого примера больше нет — просто напишите свой вопрос")
            return
        }
        // Answer with a word, not silence: the answer itself takes seconds to
        // start, and a button that visibly does nothing gets tapped again.
        try? await telegram.answerCallback(callbackQueryID: callback.id, text: "💡 Отправил запрос — сейчас отвечу")

        // Mirrors route(): keep chat identity fresh and let the sender's licence
        // claim an unowned chat before the access gate runs.
        await state.recordChatMeta(
            chatID: message.chat.id,
            info: ChatMetaInfo(
                type: message.chat.type,
                title: message.chat.title,
                username: message.chat.type == "private" ? (message.chat.username ?? callback.from.username) : nil,
                firstName: message.chat.type == "private" ? (message.chat.first_name ?? callback.from.first_name) : nil
            )
        )
        await state.autoAssignIfNeeded(
            chatID: chatKey.chatID,
            senderUsername: callback.from.username,
            senderUserID: callback.from.id
        )

        // In a group the echo has to name who tapped: several people share the
        // chat, and an unattributed question followed by an answer reads as the
        // bot talking to itself.
        let isPrivate = message.chat.type == "private"
        // The name goes into an HTML message, so it takes the same escaping as
        // every other stored label (`UserIdentity.displayLabel`) — a display
        // name is arbitrary text the person picked for themselves.
        let asker = isPrivate
            ? nil
            : await state.displayLabel(forKey: state.userKey(userID: callback.from.id))
        let echo = try? await telegram.sendMessage(.init(
            chatID: chatKey.chatID,
            threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
            replyTo: nil,
            text: OnboardingPresenter.tapEcho(example: example, asker: asker),
            replyMarkup: nil
        ))

        let origin = GenerationOrigin(
            user: callback.from,
            isPrivate: isPrivate,
            replyToMessageID: echo?.message_id
        )

        let result = await updateDispatcher.submit(chatKey: chatKey) { [self] in
            do {
                try await generationCoordinator.runReadyPrompt(
                    text: example.prompt,
                    chatKey: chatKey,
                    origin: origin
                )
            } catch {
                logger.error("onboarding example failed: \(error)")
                if !(error is CancellationError) {
                    _ = try? await telegram.sendMessage(.init(
                        chatID: chatKey.chatID,
                        threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                        replyTo: nil,
                        text: "⚠️ " + UserFacingError.message(error),
                        replyMarkup: nil
                    ))
                }
            }
        }

        if case .rejected = result {
            await metrics.increment(MetricName.updatesDropped)
            _ = try? await telegram.sendMessage(.init(
                chatID: chatKey.chatID,
                threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                replyTo: nil,
                text: "⏳ Слишком много запросов подряд. Дождитесь ответа и попробуйте снова.",
                replyMarkup: nil
            ))
        }
    }

    private func handlePreCheckoutQuery(_ query: TelegramPreCheckoutQuery) async {
        await state.identifyUser(userID: query.from.id, username: query.from.username, firstName: query.from.first_name)
        do {
            let valid: Bool
            let payload = query.invoice_payload
            if payload.hasPrefix("credits_"),
               let cents = Int(payload.dropFirst("credits_".count)),
               CreditPack.isValid(cents: cents) {
                // Credit pack: Stars at the live rate, or the card at the live
                // FX rate. Either way the charged amount must still match what
                // the invoice quoted — a rate change between the two invalidates
                // the invoice rather than charging a stale price.
                if query.currency == "XTR" {
                    let starsEnabled = await state.starsCreditsEnabled()
                    let expected = await state.starsForCents(cents)
                    valid = starsEnabled && query.total_amount == expected
                } else {
                    let card = await state.cardConfig()
                    valid = card.creditsEnabled
                        && query.currency == card.currency.rawValue
                        && query.total_amount == card.creditMinorUnits(cents: cents)
                }
            } else {
                // Subscription: accept the list price or this user's winback
                // price (roadmap step 8). The grace window honors an invoice
                // opened moments before the offer ran out.
                let pricing = await state.subscriptionPricing(
                    username: state.userKey(userID: query.from.id),
                    grace: ChatContextStore.checkoutDiscountGrace
                )
                if query.currency == "XTR" {
                    let accepted = Set([pricing.starsFull, pricing.stars].compactMap { $0 })
                    valid = !accepted.isEmpty && accepted.contains(query.total_amount)
                } else {
                    // Card payment: currency and amount must match the config.
                    let card = await state.cardConfig()
                    let accepted = Set([pricing.cardMinorUnitsFull, pricing.cardMinorUnits].compactMap { $0 })
                    valid = card.isEnabled
                        && query.currency == card.currency.rawValue
                        && accepted.contains(query.total_amount)
                }
            }
            if valid {
                try await telegram.answerPreCheckoutQuery(queryID: query.id, ok: true, errorMessage: nil)
            } else {
                try await telegram.answerPreCheckoutQuery(queryID: query.id, ok: false, errorMessage: "Цена изменилась — начните покупку заново: /buy")
            }
        } catch {
            logger.error("answerPreCheckoutQuery failed: \(error)")
            try? await telegram.answerPreCheckoutQuery(queryID: query.id, ok: false, errorMessage: "Что-то пошло не так. Попробуйте позже.")
        }
    }

    /// The bot's membership in a chat changed. Greet once on a genuine join to
    /// a group so the person who added it sees what it does and how to unlock
    /// premium for everyone (roadmap step 4). The intake dedups by update_id,
    /// so Telegram redelivery won't double-greet.
    private func handleMyChatMemberUpdate(_ update: ChatMemberUpdate) async {
        let type = update.chat.type
        let wasOut = update.oldStatus == "left" || update.oldStatus == "kicked"
        let isIn = update.newStatus == "member" || update.newStatus == "administrator"

        // Private chats: `my_chat_member` is the only signal that someone
        // blocked the bot. Telegram forbids bot-initiated conversations, so a
        // blocked DM is a dead delivery address — renewal notices, winback and
        // referral payouts must stop aiming at it instead of collecting 403s
        // every sweep. Unblocking (kicked → member) revives it.
        if type == "private" {
            let isBlocked = update.newStatus == "kicked" || update.newStatus == "left"
            if isBlocked || isIn {
                await state.identifyUser(userID: update.from.id, username: update.from.username, firstName: update.from.first_name)
                await state.setBotPresence(chatID: update.chat.id, isMember: !isBlocked, type: "private")
                logger.info("private chat \(update.chat.id) \(isBlocked ? "blocked" : "unblocked") the bot")
            }
            // The DM greeting is the job of /start, not of this event.
            return
        }
        guard type == "group" || type == "supergroup" else { return }

        // Removal: the licence and the history stay (re-adding restores them),
        // but the chat stops being a delivery channel — renewal notices and
        // sponsor congratulations skip it instead of failing one by one. Only
        // an explicit exit counts; "restricted" is still a member (muted, not
        // gone) and must not silence the chat's notices.
        let isOut = update.newStatus == "left" || update.newStatus == "kicked"
        if !wasOut, isOut {
            await state.setBotPresence(chatID: update.chat.id, isMember: false, type: type, title: update.chat.title)
            logger.info("removed from group \(update.chat.id) (by @\(update.from.username ?? String(update.from.id)))")
            return
        }

        // Greet only on a real entry: previously out (left/kicked) → now in
        // (member/administrator). Skips promotions and permission tweaks so a
        // member→administrator change doesn't re-greet.
        guard wasOut, isIn else { return }

        // Keep the chat identity fresh for admin tooling (mirrors route()) and
        // clear any "removed" mark from an earlier exit.
        await state.setBotPresence(chatID: update.chat.id, isMember: true, type: type, title: update.chat.title)
        await state.identifyUser(userID: update.from.id, username: update.from.username, firstName: update.from.first_name)

        // Funnel: a real group entry is the viral-growth event (roadmap step 4).
        await state.bumpFunnel(.addedToGroup)

        // The person who added the bot may already be paying. Claiming the chat
        // for their licence here (instead of waiting for their first message)
        // means the group is premium from its very first answer — and lets the
        // welcome credit them rather than pitch them something they own.
        await state.autoAssignIfNeeded(
            chatID: update.chat.id,
            senderUsername: update.from.username,
            senderUserID: update.from.id
        )

        await sendGroupWelcome(chatID: update.chat.id)
        logger.info("greeted new group \(update.chat.id) (added by @\(update.from.username ?? String(update.from.id)))")
    }

    /// Sends the group welcome unless this chat was greeted moments ago — the
    /// `?startgroup=` link makes Telegram deliver a join twice (as
    /// `my_chat_member` and as a `/start <payload>` message), and the two race
    /// on different paths.
    private func sendGroupWelcome(chatID: Int) async {
        guard await state.claimGroupGreeting(chatID: chatID) else { return }
        let sponsor = await state.chatSponsor(chatID: chatID, askerUsername: nil)
        let welcome = GroupWelcomePresenter.welcome(
            sponsor: sponsor,
            onboarding: await state.onboardingConfig()
        )
        if welcome.showsExamples {
            await state.bumpFunnel(.onboardingShown)
        }
        _ = try? await telegram.sendMessage(.init(
            chatID: chatID,
            threadID: nil,
            replyTo: nil,
            text: welcome.text,
            replyMarkup: welcome.markup
        ))
    }

    private func route(message: TelegramMessage, chatKey: ChatKey) async throws {
        let senderUsername = message.from?.username
        let senderUserID = message.from?.id
        let isPrivate = message.chat.type == "private"

        // Identity first: this is what keeps a wallet, a subscription and a
        // licence attached to the person rather than to a rentable @username.
        if let from = message.from {
            await state.identifyUser(userID: from.id, username: from.username, firstName: from.first_name)
        }

        // Keep the human-readable chat identity fresh so admin tooling can
        // show titles/usernames instead of bare IDs.
        await state.recordChatMeta(
            chatID: message.chat.id,
            info: ChatMetaInfo(
                type: message.chat.type,
                title: message.chat.title,
                username: isPrivate ? (message.chat.username ?? message.from?.username) : nil,
                firstName: isPrivate ? (message.chat.first_name ?? message.from?.first_name) : nil
            )
        )

        // Successful payment — handle before the access gate since the payer
        // isn't a tenant yet
        if let payment = message.successful_payment {
            await handleSuccessfulPayment(message: message, payment: payment)
            return
        }

        // /buy and /start are allowed before the access gate. Parsed, not
        // prefix-matched: `hasPrefix("/buy")` also let `/buying` (and any
        // `/start…`) skip the gate, while the parser is the thing that knows
        // about `/buy@botname` and the test-mode suffix.
        if let text = message.text {
            let suffix = isPrivate ? nil : await state.suffix(chatKey: chatKey)
            let parsed = ParsedBotCommand.parse(from: text, botUsername: botUsername, suffix: suffix)
            if parsed.name == .buy || parsed.name == .start {
                _ = try? await commandHandler.handleIfCommand(text: text, chatKey: chatKey, fromUser: message.from, isPrivate: isPrivate)
                return
            }
        }

        // Auto-assign unowned private chat to sender's tenant if they own one
        await state.autoAssignIfNeeded(chatID: chatKey.chatID, senderUsername: senderUsername, senderUserID: senderUserID)

        if try await commandHandler.handleIfCommand(text: message.text, chatKey: chatKey, fromUser: message.from, isPrivate: isPrivate) {
            return
        }

        if let text = message.text, await menuHandler.processTextInput(text: text, chatKey: chatKey, userID: message.from?.id, username: message.from?.username) {
            return
        }

        try await generationCoordinator.handleIfNeeded(message: message, chatKey: chatKey)
    }

    private func handleSuccessfulPayment(message: TelegramMessage, payment: TelegramSuccessfulPayment) async {
        // Telegram redelivers updates after webhook timeouts and restarts;
        // the charge ID makes activation idempotent.
        let chargeID = payment.telegram_payment_charge_id
        if await state.isPaymentProcessed(chargeID: chargeID) {
            await metrics.increment(MetricName.paymentsDeduplicated)
            logger.info("duplicate successful_payment ignored (charge \(chargeID))")
            return
        }

        // The payer is identified by userID, so a missing @username is no
        // longer a dead end — the money lands on their account either way.
        guard let payer = message.from else {
            await state.markPaymentProcessed(chargeID: chargeID)
            await persistence?.flushNow()
            logger.error("successful_payment without a sender (charge \(chargeID))")
            return
        }
        let payerKey = state.userKey(userID: payer.id)
        let payerLabel = await state.displayLabel(forKey: payerKey)

        // Credit-pack top-up: add face value to the wallet, no subscription/tenant.
        let payload = payment.invoice_payload
        if payload.hasPrefix("credits_"),
           let cents = Int(payload.dropFirst("credits_".count)),
           CreditPack.isValid(cents: cents) {
            let wallet = await state.creditPurchasedBalance(key: payerKey, amountUsd: Double(cents) / 100.0)
            await state.markPaymentProcessed(chargeID: chargeID)
            await state.bumpFunnel(.creditTopup)
            // Referral (step 10): a friend who pays is what the program is
            // actually for — credit the inviter before the payment flush, so
            // the bonus is as durable as the payment that earned it.
            let topupBonus = await state.redeemReferralPaymentBonus(payerUserID: payer.id)
            await metrics.increment(MetricName.paymentsProcessed)
            await persistence?.flushNow()
            await announceReferralBonus(topupBonus)
            _ = try? await telegram.sendMessage(.init(
                chatID: message.chat.id,
                threadID: message.message_thread_id,
                replyTo: nil,
                text: String(
                    format: "✅ <b>Баланс пополнен на %@.</b>\n\nТекущий баланс: <b>$%.2f</b>. Теперь вам доступны любые модели: с баланса списывается стоимость каждого ответа, обычно доли цента. Сколько списалось и сколько осталось — видно под самим ответом (включите показ: /show_cost).",
                    CreditPack.label(cents: cents), wallet.balanceUsd
                ),
                replyMarkup: nil
            ))
            logger.info("credit top-up for \(payerLabel): +\(cents)c (charge \(chargeID))")
            return
        }

        let activation = await state.activatePaidSubscription(username: payerKey)
        // Never move a group away from a sponsor who is still paying for it.
        let claim = await state.claimChatForPayment(chatID: message.chat.id, payerKey: payerKey)
        await state.markPaymentProcessed(chargeID: chargeID)
        // A winback offer is one-shot: consume it whether or not it was still
        // valid, and count the ones that actually brought the payment back.
        if await state.consumeWinbackDiscount(username: payerKey) != nil {
            await state.bumpFunnel(.winbackRedeemed)
        }
        // Funnel: count the conversion before the flush so it persists with the
        // payment (not on the next debounce).
        switch activation {
        case .started: await state.bumpFunnel(.paid)
        case .extended: await state.bumpFunnel(.renewed)
        case .alreadyUnlimited: break
        }
        let referralBonus = await state.redeemReferralPaymentBonus(payerUserID: payer.id)
        await metrics.increment(MetricName.paymentsProcessed)
        // Payments are the one thing that must never wait out the debounce.
        await persistence?.flushNow()
        await announceReferralBonus(referralBonus)

        let isPrivate = message.chat.type == "private"
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy"
        // Someone else's subscription still covers this group: congratulating
        // the payer on "opening premium here" would be a lie, and the sponsor
        // keeps the chat.
        if case .keptSponsor(let sponsor) = claim {
            _ = try? await telegram.sendMessage(.init(
                chatID: message.chat.id,
                threadID: message.message_thread_id,
                replyTo: nil,
                text: """
                ✅ <b>Оплата получена!</b>

                \(payerLabel), премиум-доступ активирован для вас — в личке с ботом и в ваших чатах.

                Здесь премиум уже открыл \(sponsor) — этот чат остаётся за ним.
                """,
                replyMarkup: nil
            ))
            logger.info("payment processed for \(payerLabel): chat \(message.chat.id) kept by sponsor \(sponsor)")
            return
        }
        let text: String
        switch activation {
        case .started(let until):
            if isPrivate {
                text = """
                ✅ <b>Оплата получена!</b>

                Добро пожаловать, \(payerLabel)!
                Премиум-доступ активирован — для вас и всех ваших чатов.
                Подписка действует до <b>\(formatter.string(from: until))</b>.

                Используйте /menu для настройки или просто начните общение.
                Продлить в любой момент — /buy.
                """
            } else {
                // Group: credit the sponsor publicly (hero status).
                text = "🎉 \(payerLabel) открыл премиум-доступ для этого чата! Теперь всем доступны умные модели без рекламы."
            }
        case .extended(let until):
            if isPrivate {
                text = """
                ✅ <b>Подписка продлена!</b>

                Доступ активен до <b>\(formatter.string(from: until))</b>.
                """
            } else {
                text = "🎉 \(payerLabel) продлил премиум-доступ для этого чата — умные модели снова доступны всем."
            }
        case .alreadyUnlimited:
            text = "✅ Оплата получена. У вас бессрочный доступ — ничего не изменилось."
        }
        _ = try? await telegram.sendMessage(.init(
            chatID: message.chat.id,
            threadID: message.message_thread_id,
            replyTo: nil,
            text: text,
            replyMarkup: nil
        ))
        logger.info("payment processed for \(payerLabel): \(payment.total_amount) \(payment.currency) (\(activation))")
    }

    /// Tells an inviter their friend converted. The money is already on their
    /// balance, so a failed DM (blocked bot, never wrote to it) costs nothing
    /// but the good news.
    private func announceReferralBonus(_ bonus: ReferralPaymentBonus?) async {
        guard let bonus else { return }
        let delivered = (try? await telegram.sendMessage(.init(
            chatID: bonus.inviterUserID,
            threadID: nil,
            replyTo: nil,
            text: ReferralPresenter.paymentBonusText(bonus),
            replyMarkup: ReferralPresenter.paymentBonusMarkup()
        ))) != nil
        if !delivered {
            logger.warning("referral: could not notify \(bonus.inviterLabel) about the conversion bonus")
        }
        logger.info("referral conversion bonus: \(bonus.inviterLabel) +$\(bonus.amountUsd) (friend \(bonus.friendLabel))")
    }

    // MARK: - Metrics report (GET /metrics)

    struct MetricsReport: Codable, Sendable {
        let uptimeSeconds: Int
        let activeGenerations: Int
        let queuedChatOperations: Int
        let dirtyEntities: Int
        let persistence: String
        let counters: [String: Int]
        /// Conversion-funnel event counts + live sponsor tallies (roadmap step 7).
        let funnel: [String: Int]
        /// The same events over the last day / 7 days: a total says how big,
        /// a window says whether it is moving.
        let funnelToday: [String: Int]
        let funnelWeek: [String: Int]
    }

    func metricsReport() async -> MetricsReport {
        let snapshot = await metrics.snapshot()
        let funnel = await state.funnelReport()
        let persistenceLine: String
        if let persistence {
            let status = await persistence.status()
            if let error = status.lastErrorMessage {
                persistenceLine = "error: \(error) (retry pending: \(status.pendingRetryEntities))"
            } else {
                persistenceLine = "ok (flushes: \(status.totalFlushes), entities: \(status.totalEntitiesFlushed))"
            }
        } else {
            persistenceLine = "disabled"
        }
        return MetricsReport(
            uptimeSeconds: snapshot.uptimeSeconds,
            activeGenerations: await sessionRegistry.activeCount,
            queuedChatOperations: await updateDispatcher.totalQueuedOperations,
            dirtyEntities: await state.dirtyEntityCount,
            persistence: persistenceLine,
            counters: snapshot.counters,
            funnel: funnel.flat,
            funnelToday: funnel.todayCounters,
            funnelWeek: funnel.weekCounters
        )
    }
}
