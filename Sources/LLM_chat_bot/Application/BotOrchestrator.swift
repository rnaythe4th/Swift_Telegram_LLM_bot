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

    private let backgroundTasks = LockedValue<[Task<Void, Never>]>([])
    private let shutdownStarted = LockedValue(false)

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
                    allowedUpdates: ["message", "callback_query", "pre_checkout_query", "my_chat_member"]
                )
                logger.info("webhook registered: \(url)")
                // Updates now arrive via AppHTTPServer → intake; park until drain.
                while !flags.draining.value {
                    try? await Task.sleep(for: .seconds(1))
                }
            } catch {
                logger.error("setWebhook failed, falling back to polling: \(error)")
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

        let deadline = ContinuousClock().now + .seconds(8)
        while await sessionRegistry.activeCount > 0, ContinuousClock().now < deadline {
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
        try? await telegram.answerCallback(callbackQueryID: callback.id, text: nil)

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

        let echo = try? await telegram.sendMessage(.init(
            chatID: chatKey.chatID,
            threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
            replyTo: nil,
            text: OnboardingPresenter.tapEcho(example: example),
            replyMarkup: nil
        ))

        let origin = GenerationOrigin(
            user: callback.from,
            isPrivate: message.chat.type == "private",
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
        do {
            let valid: Bool
            let payload = query.invoice_payload
            if payload.hasPrefix("credits_"),
               let cents = Int(payload.dropFirst("credits_".count)),
               CreditPack.isValid(cents: cents) {
                // Credit pack — Stars only for now; amount must match the live rate.
                let expected = await state.starsForCents(cents)
                valid = query.currency == "XTR" && query.total_amount == expected
            } else {
                // Subscription: accept the list price or this user's winback
                // price (roadmap step 8). The grace window honors an invoice
                // opened moments before the offer ran out.
                let pricing = await state.subscriptionPricing(
                    username: query.from.username,
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
        // Private-chat my_chat_member fires on block/unblock; DMs get the /start
        // greeting instead, so only groups receive this welcome.
        guard type == "group" || type == "supergroup" else { return }

        // Greet only on a real entry: previously out (left/kicked) → now in
        // (member/administrator). Skips promotions and permission tweaks so a
        // member→administrator change doesn't re-greet.
        let wasOut = update.oldStatus == "left" || update.oldStatus == "kicked"
        let isIn = update.newStatus == "member" || update.newStatus == "administrator"
        guard wasOut, isIn else { return }

        // Keep the chat identity fresh for admin tooling (mirrors route()).
        await state.recordChatMeta(
            chatID: update.chat.id,
            info: ChatMetaInfo(type: type, title: update.chat.title, username: nil, firstName: nil)
        )

        // Funnel: a real group entry is the viral-growth event (roadmap step 4).
        await state.bumpFunnel(.addedToGroup)

        var text = """
        <b>👋 Всем привет!</b> Я умный ИИ-ассистент. Отвечаю на @упоминание или реплай на моё сообщение.

        Понимаю текст, фото, голос и видео, помню разговор.

        Полный доступ — умные модели, без рекламы и лимитов — для этого чата откроет любой участник → /buy
        """
        var rows: [[InlineKeyboardButton]] = []

        // Onboarding (roadmap step 9): one tap shows the chat what the bot can
        // do — the fastest path from "added" to "activated".
        let onboarding = await state.onboardingConfig()
        if onboarding.showInGroups {
            let exampleRows = OnboardingPresenter.exampleRows(onboarding)
            if !exampleRows.isEmpty {
                text += "\n\n" + OnboardingPresenter.invitation
                rows.append(contentsOf: exampleRows)
                await state.bumpFunnel(.onboardingShown)
            }
        }

        rows.append([InlineKeyboardButton(text: "⚡ Премиум для чата", callback_data: BotCallbackAction.menu(action: "nav:pay").rawData)])
        let markup = InlineKeyboardMarkup(inline_keyboard: rows)
        _ = try? await telegram.sendMessage(.init(
            chatID: update.chat.id,
            threadID: nil,
            replyTo: nil,
            text: text,
            replyMarkup: markup
        ))
        logger.info("greeted new group \(update.chat.id) (added by @\(update.from.username ?? String(update.from.id)))")
    }

    private func route(message: TelegramMessage, chatKey: ChatKey) async throws {
        let senderUsername = message.from?.username
        let senderUserID = message.from?.id
        let isPrivate = message.chat.type == "private"

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

        // /buy and /start are allowed before the access gate
        if let text = message.text {
            let isBuyOrStart = text.hasPrefix("/buy") || text.hasPrefix("/start")
            if isBuyOrStart {
                _ = try? await commandHandler.handleIfCommand(text: text, chatKey: chatKey, fromUser: message.from, isPrivate: isPrivate)
                return
            }
        }

        // Auto-assign unowned private chat to sender's tenant if they own one
        await state.autoAssignIfNeeded(chatID: chatKey.chatID, senderUsername: senderUsername, senderUserID: senderUserID)

        if try await commandHandler.handleIfCommand(text: message.text, chatKey: chatKey, fromUser: message.from, isPrivate: isPrivate) {
            return
        }

        if let text = message.text, await menuHandler.processTextInput(text: text, chatKey: chatKey, username: message.from?.username) {
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

        guard let username = message.from?.username else {
            await state.markPaymentProcessed(chargeID: chargeID)
            await persistence?.flushNow()
            _ = try? await telegram.sendMessage(.init(
                chatID: message.chat.id,
                threadID: message.message_thread_id,
                replyTo: nil,
                text: "✅ Оплата получена! Но у вас не задан @username в Telegram, поэтому доступ пока не включён. Задайте его в настройках Telegram и напишите администратору бота.",
                replyMarkup: nil
            ))
            return
        }

        // Credit-pack top-up: add face value to the wallet, no subscription/tenant.
        let payload = payment.invoice_payload
        if payload.hasPrefix("credits_"),
           let cents = Int(payload.dropFirst("credits_".count)),
           CreditPack.isValid(cents: cents) {
            let wallet = await state.creditBalance(username: username, amountUsd: Double(cents) / 100.0)
            await state.markPaymentProcessed(chargeID: chargeID)
            await state.bumpFunnel(.creditTopup)
            await metrics.increment(MetricName.paymentsProcessed)
            await persistence?.flushNow()
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
            logger.info("credit top-up for @\(username): +\(cents)c (charge \(chargeID))")
            return
        }

        let activation = await state.activatePaidSubscription(username: username)
        await state.assignChat(chatID: message.chat.id, to: username)
        await state.markPaymentProcessed(chargeID: chargeID)
        // A winback offer is one-shot: consume it whether or not it was still
        // valid, and count the ones that actually brought the payment back.
        if await state.consumeWinbackDiscount(username: username) != nil {
            await state.bumpFunnel(.winbackRedeemed)
        }
        // Funnel: count the conversion before the flush so it persists with the
        // payment (not on the next debounce).
        switch activation {
        case .started: await state.bumpFunnel(.paid)
        case .extended: await state.bumpFunnel(.renewed)
        case .alreadyUnlimited: break
        }
        await metrics.increment(MetricName.paymentsProcessed)
        // Payments are the one thing that must never wait out the debounce.
        await persistence?.flushNow()

        let isPrivate = message.chat.type == "private"
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy"
        let text: String
        switch activation {
        case .started(let until):
            if isPrivate {
                text = """
                ✅ <b>Оплата получена!</b>

                Добро пожаловать, @\(username)!
                Премиум-доступ активирован — для вас и всех ваших чатов.
                Подписка действует до <b>\(formatter.string(from: until))</b>.

                Используйте /menu для настройки или просто начните общение.
                Продлить в любой момент — /buy.
                """
            } else {
                // Group: credit the sponsor publicly (hero status).
                text = "🎉 @\(username) открыл премиум-доступ для этого чата! Теперь всем доступны умные модели без рекламы."
            }
        case .extended(let until):
            if isPrivate {
                text = """
                ✅ <b>Подписка продлена!</b>

                Доступ активен до <b>\(formatter.string(from: until))</b>.
                """
            } else {
                text = "🎉 @\(username) продлил премиум-доступ для этого чата — умные модели снова доступны всем."
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
        logger.info("payment processed for @\(username): \(payment.total_amount) \(payment.currency) (\(activation))")
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
    }

    func metricsReport() async -> MetricsReport {
        let snapshot = await metrics.snapshot()
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
            funnel: await state.funnelReport().flat
        )
    }
}
