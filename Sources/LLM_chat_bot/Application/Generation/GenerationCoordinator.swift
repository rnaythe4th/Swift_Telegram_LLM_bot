import Foundation

private enum ReplyContentResolution {
    case none
    case unsupported(String)
    case content(UserInputContent)
}

/// Everything a turn needs to know about who asked and where. A real Telegram
/// message yields one; so does a synthetic turn started from a button (an
/// onboarding example, roadmap step 9), which has no message of its own.
struct GenerationOrigin: Sendable {
    let user: TelegramUser?
    let isPrivate: Bool
    /// Message the reply should quote; nil = plain reply.
    let replyToMessageID: Int?

    init(user: TelegramUser?, isPrivate: Bool, replyToMessageID: Int?) {
        self.user = user
        self.isPrivate = isPrivate
        self.replyToMessageID = replyToMessageID
    }

    init(message: TelegramMessage) {
        self.init(
            user: message.from,
            isPrivate: message.chat.type == "private",
            replyToMessageID: message.message_id
        )
    }
}

final class GenerationCoordinator: @unchecked Sendable {
    private let telegram: TelegramGatewayPort
    private let state: ChatContextStore
    private let sessionRegistry: SessionRegistry
    private let mediaResolver: MediaResolverPort
    private let gateways: ProviderGatewayRegistry
    private let logger: LoggerPort
    private let botUsername: String
    private let generationLimiter: GenerationLimiter
    private let metrics: RuntimeMetrics?

    init(
        telegram: TelegramGatewayPort,
        state: ChatContextStore,
        sessionRegistry: SessionRegistry,
        mediaResolver: MediaResolverPort,
        gateways: ProviderGatewayRegistry,
        logger: LoggerPort,
        botUsername: String,
        generationLimiter: GenerationLimiter,
        metrics: RuntimeMetrics? = nil
    ) {
        self.telegram = telegram
        self.state = state
        self.sessionRegistry = sessionRegistry
        self.mediaResolver = mediaResolver
        self.gateways = gateways
        self.logger = logger
        self.botUsername = botUsername
        self.generationLimiter = generationLimiter
        self.metrics = metrics
    }

    /// Releases the concurrency slot and closes the session. Every generation
    /// that passed `generationLimiter.acquire()` must end through here exactly
    /// once, whatever path it takes.
    private func finishGeneration(_ generationID: GenerationID) async {
        await generationLimiter.release()
        await sessionRegistry.finish(generationID: generationID)
    }

    /// Free-tier monetization: after a completed reply in a chat without an
    /// active paid licence, the store may pick an ad campaign to show
    /// (frequency + pacing rules live there). Failure to send is non-fatal.
    private func maybeServeAd(chatKey: ChatKey, isPrivate: Bool) async {
        guard let ad = await state.nextAdToShow(chatKey: chatKey) else { return }
        var markup: InlineKeyboardMarkup?
        let isSelfPromo = ad.id == AdCampaign.selfPromoID
        if isSelfPromo {
            // A pitch that ends in "type /buy" loses everyone who won't type.
            // The tap is tagged so the funnel can tell this slot apart from the
            // plain menu button (roadmap steps 5 and 7).
            var rows: [[InlineKeyboardButton]] = [[
                InlineKeyboardButton(
                    text: "⚡ Открыть премиум",
                    callback_data: BotCallbackAction.menu(action: "nav:pay:\(PurchaseSource.promo.rawValue)").rawData
                )
            ]]
            let referral = await state.referralConfig()
            if isPrivate, referral.enabled, referral.inviterRewardCents > 0 {
                rows.append([InlineKeyboardButton(
                    text: "🎁 Пригласить друга · +\(ReferralConfig.formatUsd(cents: referral.inviterRewardCents))",
                    callback_data: BotCallbackAction.menu(action: "nav:ref").rawData
                )])
            }
            markup = InlineKeyboardMarkup(inline_keyboard: rows)
        } else if let buttonText = ad.buttonText, let url = ad.buttonURL {
            markup = InlineKeyboardMarkup(inline_keyboard: [[
                InlineKeyboardButton(text: buttonText, url: url)
            ]])
        }
        // The built-in self-promo already reads as a pitch; the "Реклама"
        // label is only prepended to real super-admin banners.
        let body = isSelfPromo ? ad.text : "<i>📣 Реклама</i>\n\n" + ad.text
        _ = try? await telegram.sendMessage(.init(
            chatID: chatKey.chatID,
            threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
            replyTo: nil,
            text: body,
            replyMarkup: markup
        ))
    }

    /// Sent when a free-tier chat/user spends its daily premium allowance: the
    /// paid model has fallen back to free and an upgrade is pitched at the pain
    /// point (roadmap step 5 buttons, both opening the unified purchase page).
    /// Group copy stresses the shared cap ("для всех"); private copy is personal.
    /// With the taste switched off (limit 0) nothing "ran out" — say what is
    /// actually true instead of "0 из 0".
    private func sendDailyLimitOffer(chatKey: ChatKey, isGroup: Bool, limit: Int, freeModel: String) async throws {
        let payAction = BotCallbackAction.menu(action: "nav:pay:\(PurchaseSource.cap.rawValue)").rawData
        let spent = limit > 0
            ? "🚦 Ответы умных моделей на сегодня закончились (\(limit) из \(limit)). Завтра будут снова — счётчик обнуляется каждый день."
            : "🚦 Эта модель — из умных, они доступны с премиумом."
        let text: String
        let markup: InlineKeyboardMarkup
        if isGroup {
            text = "\(spent)\n\nПока отвечаю на бесплатной модели — <code>\(freeModel)</code>. Умные модели сразу для всех участников чата:"
            markup = InlineKeyboardMarkup(inline_keyboard: [[
                InlineKeyboardButton(text: "⚡ Премиум для чата", callback_data: payAction)
            ]])
        } else {
            text = "\(spent)\n\nПока отвечаю на бесплатной модели — <code>\(freeModel)</code>. Как получить умные без лимита:"
            var rows: [[InlineKeyboardButton]] = [[
                InlineKeyboardButton(text: "⚡ Премиум на месяц", callback_data: payAction),
                InlineKeyboardButton(text: "💰 Пополнить баланс", callback_data: payAction)
            ]]
            // Free way out of the cap right at the pain point: bring a friend
            // and both wallets grow (roadmap step 10).
            let referral = await state.referralConfig()
            if referral.enabled, referral.inviterRewardCents > 0 {
                rows.append([InlineKeyboardButton(
                    text: "🎁 Пригласить друга · +\(ReferralConfig.formatUsd(cents: referral.inviterRewardCents))",
                    callback_data: BotCallbackAction.menu(action: "nav:ref").rawData
                )])
            }
            markup = InlineKeyboardMarkup(inline_keyboard: rows)
        }
        _ = try await telegram.sendMessage(.init(
            chatID: chatKey.chatID,
            threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
            replyTo: nil,
            text: text,
            replyMarkup: markup
        ))
    }

    /// Fired once, on the turn that spends the *last* daily premium answer. The
    /// wall itself arrives one message later; saying so now turns a silent
    /// countdown into a visible one — and the offer lands while the person is
    /// still getting the good answer, not after it was taken away.
    private func sendLastPremiumCallNotice(chatKey: ChatKey, isGroup: Bool, limit: Int) async {
        let payAction = BotCallbackAction.menu(action: "nav:pay:\(PurchaseSource.cap.rawValue)").rawData
        let text = isGroup
            ? "⏳ Это был последний умный ответ для этого чата на сегодня (\(limit) из \(limit)). Дальше отвечаю на бесплатной модели — до завтра. Снять лимит для всех:"
            : "⏳ Это был ваш последний умный ответ на сегодня (\(limit) из \(limit)). Дальше отвечаю на бесплатной модели — до завтра. Снять лимит:"
        _ = try? await telegram.sendMessage(.init(
            chatID: chatKey.chatID,
            threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
            replyTo: nil,
            text: text,
            replyMarkup: InlineKeyboardMarkup(inline_keyboard: [[
                InlineKeyboardButton(text: isGroup ? "⚡ Премиум для чата" : "⚡ Премиум на месяц", callback_data: payAction),
                InlineKeyboardButton(text: "💰 Баланс", callback_data: payAction)
            ]])
        ))
        await state.bumpFunnel(.capWarned)
    }

    /// Fired on the answer whose charge emptied a pay-as-you-go wallet. The
    /// next turn silently drops to the free tier, so without this the user only
    /// finds out by noticing worse answers (roadmap step 5: sell at the pain
    /// point, and only there — `chargeBalance` reports the crossing once).
    private func sendBalanceEmptyNotice(chatKey: ChatKey) async {
        let payAction = BotCallbackAction.menu(action: "nav:pay:\(PurchaseSource.balance.rawValue)").rawData
        _ = try? await telegram.sendMessage(.init(
            chatID: chatKey.chatID,
            threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
            replyTo: nil,
            text: "💸 <b>Баланс закончился</b> — этот ответ был последним оплаченным.\n\nДальше отвечаю на бесплатной модели. Чтобы вернуть умные: пополните баланс (платите только за ответы, обычно доли цента) или возьмите премиум на месяц — он без лимитов и работает во всех ваших чатах.",
            replyMarkup: InlineKeyboardMarkup(inline_keyboard: [[
                InlineKeyboardButton(text: "💰 Пополнить баланс", callback_data: payAction),
                InlineKeyboardButton(text: "⚡ Премиум на месяц", callback_data: payAction)
            ]])
        ))
    }

    /// Identifies the daily-premium counter this turn consumed, so a turn that
    /// ends without an answer can hand the unit back.
    private struct DailyPremiumTicket: Sendable {
        let chatID: Int
        let userID: Int?
        let isGroup: Bool
    }

    /// A free user's daily allowance is tiny — a provider error, a stop or an
    /// empty reply must not eat one of it.
    private func refundPremium(_ ticket: DailyPremiumTicket?) async {
        guard let ticket else { return }
        await state.refundDailyPremium(chatID: ticket.chatID, userID: ticket.userID, isGroup: ticket.isGroup)
    }

    /// Credits a resolved referral pair and tells both sides (roadmap step 10).
    /// The store resolves the record and both wallets in one actor step, so a
    /// redelivered update or a retried turn can never pay twice; failing to
    /// deliver a notification is non-fatal — the money is already there.
    ///
    /// Both notices go to DMs, never into the room the friend happened to write
    /// in: the reward is personal, and announcing "вас пригласил @X" in a group
    /// tells everyone something the friend did not choose to share. The friend
    /// always has a DM — the attribution came from `/start` in one.
    private func payReferralIfDue(userID: Int, username: String?) async {
        guard let payout = await state.redeemReferralIfDue(userID: userID, username: username) else { return }
        let refButton = InlineKeyboardButton(
            text: "🎁 Пригласить друга",
            callback_data: BotCallbackAction.menu(action: "nav:ref").rawData
        )

        if payout.inviteeRewardUsd > 0 {
            _ = try? await telegram.sendMessage(.init(
                chatID: userID,
                threadID: nil,
                replyTo: nil,
                text: String(
                    format: "🎁 <b>Бонус за приглашение: $%.2f на баланс</b> — спасибо %@!\n\nПока баланс не пуст, вам доступны любые модели: с него списывается стоимость каждого ответа, обычно доли цента. Сколько списалось — видно под самим ответом (включите показ: /show_cost).\n\nВаша ссылка для друзей — /ref.",
                    payout.inviteeRewardUsd, payout.inviterUsername
                ),
                replyMarkup: InlineKeyboardMarkup(inline_keyboard: [[refButton]])
            ))
        }

        if payout.inviterRewardUsd > 0 {
            // The label works without a @username (the migration to userID keys
            // made nicks optional), so a friend without one is still named.
            let notified = (try? await telegram.sendMessage(.init(
                chatID: payout.inviterUserID,
                threadID: nil,
                replyTo: nil,
                text: String(
                    format: "🎉 <b>Ваше приглашение сработало: %@ уже пишет боту.</b>\n\nВам начислено <b>$%.2f</b> на баланс · приглашений с наградой: <b>%d</b>.",
                    payout.invitedLabel, payout.inviterRewardUsd, payout.inviterRewardedTotal
                ),
                replyMarkup: InlineKeyboardMarkup(inline_keyboard: [[refButton]])
            ))) != nil
            if !notified {
                // Money is already on their balance; only the good news failed
                // to land (blocked DM, never wrote to the bot).
                logger.warning("referral: could not notify inviter \(payout.inviterUsername) about +$\(payout.inviterRewardUsd)")
            }
        }

        logger.info("referral payout: \(payout.inviterUsername) +$\(payout.inviterRewardUsd), \(payout.invitedLabel) +$\(payout.inviteeRewardUsd)")
    }

    /// Customer-facing footer: costs go through the markup multiplier; for
    /// balance-billed users the projected post-charge balance is appended
    /// (the actual deduction in appendAssistant uses the same formula).
    private func makeFooter(
        streamMeta: StreamMeta?,
        fallbackModel: String,
        options: GenerationOptions,
        billedTo: String?,
        hasContent: Bool,
        sponsorLine: String?
    ) async -> String {
        let multiplier = await state.priceMultiplier()
        var balanceAfter: Double?
        if let billedTo, hasContent {
            let realCost = streamMeta?.usage?.cost ?? 0
            balanceAfter = await state.projectedBalanceAfterCharge(username: billedTo, realCost: realCost)
        }
        return ResponseFooterFormatter.formatFooter(
            meta: streamMeta,
            fallbackModel: fallbackModel,
            showTokens: options.showStats,
            showCost: options.showCost,
            showModel: options.showModel,
            costMultiplier: multiplier,
            balanceAfter: balanceAfter,
            sponsorLine: sponsorLine
        ) ?? ""
    }

    /// Hero credit shown under answers in a group whose paid access comes from
    /// another member's active subscription. Suppressed in private chats and
    /// when the asker is the sponsor themselves. Repeats at most once an hour
    /// per chat (the store owns that timer) — under every single answer the
    /// credit stops reading as status and starts reading as clutter.
    private func sponsorCreditLine(chatID: Int, askerUsername: String?, isPrivate: Bool) async -> String? {
        guard !isPrivate else { return nil }
        guard let sponsor = await state.chatSponsorForCredit(chatID: chatID, askerUsername: askerUsername) else {
            return nil
        }
        return "⚡ премиум для чата открыл \(sponsor)"
    }

    func handleIfNeeded(message: TelegramMessage, chatKey: ChatKey) async throws {
        switch try await resolveProcessableContent(message: message, chatKey: chatKey) {
        case .content(let content):
            try await processContent(origin: GenerationOrigin(message: message), content: content, chatKey: chatKey)
        case .unsupported(let feedback):
            try await sendUserFeedback(chatKey: chatKey, text: feedback)
        case .none:
            break
        }
    }

    /// Runs a ready-made prompt as a normal turn — the onboarding example
    /// buttons (roadmap step 9). Skips only the routing policy (the tap *is* the
    /// explicit address to the bot); the free-tier gate, billing, ads and
    /// history all behave exactly as for a typed message.
    func runReadyPrompt(text: String, chatKey: ChatKey, origin: GenerationOrigin) async throws {
        try await processContent(
            origin: origin,
            content: UserInputContent(text: text, attachments: []),
            chatKey: chatKey
        )
    }
    
    private func resolveProcessableContent(message: TelegramMessage, chatKey: ChatKey) async throws -> ReplyContentResolution {
        let routing = MessageRoutingPolicy.evaluate(message: message, botUsername: botUsername)
        let refs = extractMediaRefs(from: message)
        
        guard routing.shouldHandle else {
            return .none
        }
        
        let normalizedText = routing.normalizedText
        guard normalizedText != nil || !refs.isEmpty else {
            return .none
        }
        
        if !refs.isEmpty {
            let provider = await state.provider(chatKey: chatKey)
            let adapter = try gateways.gateway(for: provider)
            
            let unsupportedKinds = unsupportedMediaKinds(in: refs, capabilities: adapter.capabilities)
            if !unsupportedKinds.isEmpty {
                let kinds = unsupportedKinds.map(\.displayName).joined(separator: ", ")
                return .unsupported(
                    "⚠️ Этот сервис ИИ не понимает: \(kinds).\nВыберите другой в /menu → 🔌 Сервис ИИ или отправьте только текст."
                )
            }
        }
        
        let resolved = refs.isEmpty ? [] : try await mediaResolver.resolveMedia(refs)
        return .content(.init(text: normalizedText, attachments: resolved))
    }
    
    private func processContent(origin: GenerationOrigin, content: UserInputContent, chatKey: ChatKey) async throws {
        let username = origin.user?.username

        // Funnel: count this chat's first real message (activation, once per chat).
        await state.markFirstMessageIfNeeded(chatKey: chatKey)

        // Referral (roadmap step 10): the invited friend's first real turn is
        // what releases the two-sided reward — in a DM or in a group, since a
        // friend who goes straight to a group chat did exactly what we wanted.
        // Attribution alone pays nothing, so a farm of idle accounts earns
        // nothing; both notices are delivered to DMs (see the method).
        if let userID = origin.user?.id {
            await payReferralIfDue(userID: userID, username: username)
        }

        // Free-tier gate with a daily premium "taste": a sender without full
        // access who selected a paid model gets N smart-model answers per day
        // (group = shared per chat, private = per user). Once the daily
        // allowance is spent, the chat falls back to the first free model and an
        // upgrade is pitched at the pain point. Free models are unlimited
        // (retention); sponsored chats never reach here (hasFullModelAccess).
        let hasAccess = await state.hasFullModelAccess(
            username: username,
            userID: origin.user?.id,
            chatID: chatKey.chatID
        )
        /// Set when this turn spent a daily-premium unit — refunded if the turn
        /// produces no answer; `lastPremiumCall` carries the limit when this was
        /// the last unit of the day (scarcity notice after the answer lands).
        var premiumTicket: DailyPremiumTicket?
        var lastPremiumCall: Int?
        if hasAccess {
            // Access is back (subscription, sponsor, referral or a top-up): give
            // back the paid model the cap had parked, otherwise the purchase
            // silently changes nothing and the chat keeps answering on the
            // fallback (roadmap steps 2 and 6).
            if let restored = await state.restoreDowngradedModel(chatKey: chatKey) {
                try? await sendUserFeedback(
                    chatKey: chatKey,
                    text: "⚡ Дневной лимит вам больше не мешает — вернул умную модель <code>\(restored)</code>. Сменить: /menu → 🤖 Модель"
                )
            }
        } else if let effectiveFree = await state.effectiveFreeModelIDs() {
            // A fresh daily allowance gives the parked paid model back — quietly.
            // The gate below only fires while the chat model *is* paid, so a chat
            // sitting on the cap fallback would never reach `consumeDailyPremium`
            // again and the whole daily taste would die after its first day. The
            // purchase path above announces the restore; a new day is routine.
            if await state.remainingDailyPremium(
                chatID: chatKey.chatID,
                userID: origin.user?.id,
                isGroup: !origin.isPrivate
            ).remaining > 0 {
                await state.restoreDowngradedModel(chatKey: chatKey)
            }
            let currentModel = await state.model(chatKey: chatKey)
            if !effectiveFree.contains(currentModel) {
                guard let firstFree = await state.firstFreeModel() else {
                    try await sendUserFeedback(chatKey: chatKey, text: "ℹ️ Бесплатные модели сейчас недоступны. Напишите администратору бота.")
                    return
                }
                let isGroup = !origin.isPrivate
                let decision = await state.consumeDailyPremium(
                    chatID: chatKey.chatID,
                    userID: origin.user?.id,
                    isGroup: isGroup
                )
                switch decision {
                case .allowed(let remaining, let limit):
                    // Daily premium taste: let the paid model answer this turn.
                    // The unit is booked now and given back if the turn ends
                    // without an answer (see `refundPremium`).
                    premiumTicket = DailyPremiumTicket(
                        chatID: chatKey.chatID,
                        userID: origin.user?.id,
                        isGroup: isGroup
                    )
                    lastPremiumCall = remaining == 0 ? limit : nil
                case .exhausted(let limit):
                    await state.bumpFunnel(.capHit)
                    await state.downgradeModelToFree(chatKey: chatKey, freeModel: firstFree)
                    try? await sendDailyLimitOffer(chatKey: chatKey, isGroup: isGroup, limit: limit, freeModel: firstFree)
                }
            }
        }

        // Billing: a chat covered by a tenant subscription costs the sender
        // nothing; otherwise a sender with a positive balance pays per message
        // (marked-up). Everyone else is free-tier → sees ads.
        let covered = await state.hasSubscriptionCoverage(
            username: username,
            userID: origin.user?.id,
            chatID: chatKey.chatID
        )
        // Wallet key, not a handle: charges follow the person through a rename
        // and work for someone who never set a @username.
        var billedTo: String? = nil
        if !covered {
            billedTo = await state.billingKey(username: username, userID: origin.user?.id)
        }
        let adEligible = !covered && billedTo == nil

        let generationID = await sessionRegistry.register(chatKey: chatKey)

        let typingTask = Task {
            while !Task.isCancelled {
                try? await self.telegram.sendChatAction(
                    chatID: chatKey.chatID,
                    threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                    action: "typing"
                )
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
        defer { typingTask.cancel() }

        // Global concurrency cap: with hundreds of chats firing at once the
        // excess waits here (typing indicator already running) instead of
        // exhausting sockets/memory.
        await generationLimiter.acquire()
        await metrics?.increment(MetricName.generationsStarted)
        
        var processedContent = content
        if let username, let text = processedContent.text, !text.isEmpty {
            processedContent.text = "Тебе пишет @\(username): \(text)"
        }
        
        let hasAttachments = !processedContent.attachments.isEmpty
        
        let historyContent = hasAttachments
            ? UserInputContent(text: processedContent.text, attachments: [])
            : processedContent
        
        let snapshot = await state.snapshotAndAppend(
            chatKey: chatKey,
            generationID: generationID,
            content: historyContent,
            username: username
        )
        
        let messages: [ChatMessage] = hasAttachments
            ? Array(snapshot.messages.dropLast()) + [ChatMessage.userContent(processedContent, username: username)]
            : snapshot.messages
        
        let provider = snapshot.provider
        
        do {
            let gateway = try gateways.gateway(for: provider)
            
            let plan = ProviderGenerationPlan(
                model: snapshot.model,
                messages: messages,
                temperature: snapshot.temperature,
                includeUsage: snapshot.options.showStats || snapshot.options.showCost,
                reasoningEffort: snapshot.options.reasoningEffort,
                providerRouting: snapshot.providerRouting
            )
            
            let request = gateway.makeRequest(plan)
            let fallbackModel = gateway.fallbackModel(for: plan)

            let sponsorLine = await sponsorCreditLine(
                chatID: chatKey.chatID,
                askerUsername: origin.user?.username,
                isPrivate: origin.isPrivate
            )

            try await streamReply(
                gateway: gateway,
                request: request,
                fallbackModel: fallbackModel,
                options: snapshot.options,
                chatKey: chatKey,
                replyToMessageID: origin.replyToMessageID,
                generationID: generationID,
                isPrivateChat: origin.isPrivate,
                adEligible: adEligible,
                billedTo: billedTo,
                sponsorLine: sponsorLine,
                premiumTicket: premiumTicket,
                lastPremiumCall: lastPremiumCall
            )
        } catch {
            await state.cancelPendingTurn(chatKey: chatKey, generationID: generationID)
            await refundPremium(premiumTicket)
            await finishGeneration(generationID)
            throw error
        }
    }

    private func streamReply(
        gateway: ProviderGatewayPort,
        request: ProviderGatewayRequest,
        fallbackModel: String,
        options: GenerationOptions,
        chatKey: ChatKey,
        replyToMessageID: Int?,
        generationID: GenerationID,
        isPrivateChat: Bool,
        adEligible: Bool,
        billedTo: String?,
        sponsorLine: String?,
        premiumTicket: DailyPremiumTicket?,
        lastPremiumCall: Int?
    ) async throws {
        let stopMarkup = InlineKeyboardMarkup(inline_keyboard: [[
            .init(text: "⏹ Остановить", callback_data: BotCallbackAction.stop(generationID).rawData)
        ]])

        // On failure just rethrow: processContent's catch owns the cleanup
        // (cancelPendingTurn + finishGeneration) — doing it here too would
        // release the generation slot twice.
        let placeholder = try await telegram.sendMessage(
            .init(
                chatID: chatKey.chatID,
                threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                replyTo: replyToMessageID,
                text: "💭 <i>Думаю…</i>",
                replyMarkup: stopMarkup
            )
        )

        // Drafts work only in private chats; begin() returns nil when the Bot API
        // server has no sendMessageDraft (then we fall back to edit-based streaming).
        var draft: DraftStreamer?
        if isPrivateChat {
            draft = await DraftStreamer.begin(
                telegram: telegram,
                chatID: chatKey.chatID,
                threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                logger: logger
            )
        }

        let streamTask: Task<Void, Never>
        if let draft {
            streamTask = Task<Void, Never> {
                await self.runDraftStreaming(
                    draft: draft,
                    gateway: gateway,
                    request: request,
                    fallbackModel: fallbackModel,
                    options: options,
                    chatKey: chatKey,
                    replyToMessageID: replyToMessageID,
                    generationID: generationID,
                    controlMessage: placeholder,
                    adEligible: adEligible,
                    billedTo: billedTo,
                    sponsorLine: sponsorLine,
                    premiumTicket: premiumTicket,
                    lastPremiumCall: lastPremiumCall
                )
            }
        } else {
            streamTask = Task<Void, Never> {
                await self.runEditStreaming(
                    gateway: gateway,
                    request: request,
                    fallbackModel: fallbackModel,
                    options: options,
                    chatKey: chatKey,
                    generationID: generationID,
                    placeholder: placeholder,
                    stopMarkup: stopMarkup,
                    adEligible: adEligible,
                    billedTo: billedTo,
                    sponsorLine: sponsorLine,
                    premiumTicket: premiumTicket,
                    lastPremiumCall: lastPremiumCall
                )
            }
        }

        await sessionRegistry.attach(generationID: generationID, task: streamTask)
    }

    /// Streams the reply into a native animated draft (private chats, Bot API 9.3+).
    /// The draft is an ephemeral preview, so every finished part — overflow chunks,
    /// the final text, errors, cancellation notices — is persisted via sendMessage.
    /// The "💭 Думаю…" control message only carries the stop button and is deleted
    /// once the reply is persisted.
    private func runDraftStreaming(
        draft: DraftStreamer,
        gateway: ProviderGatewayPort,
        request: ProviderGatewayRequest,
        fallbackModel: String,
        options: GenerationOptions,
        chatKey: ChatKey,
        replyToMessageID: Int?,
        generationID: GenerationID,
        controlMessage: TelegramMessage,
        adEligible: Bool,
        billedTo: String?,
        sponsorLine: String?,
        premiumTicket: DailyPremiumTicket?,
        lastPremiumCall: Int?
    ) async {
        var fullAccumulator = ""
        var messageAccumulator = ""
        var streamMeta: StreamMeta?
        var isCancelled = false
        var isFirstMessage = true
        let threadID: Int64? = chatKey.threadID == 0 ? nil : chatKey.threadID

        // Persists a finished part; Telegram animates the draft into the stored
        // message. Retries rate limits — losing the send here loses the reply,
        // because the draft itself expires.
        func persist(_ text: String) async -> Bool {
            let replyTo = isFirstMessage ? replyToMessageID : nil
            for attempt in 0..<3 {
                do {
                    _ = try await telegram.sendMessage(
                        .init(
                            chatID: chatKey.chatID,
                            threadID: threadID,
                            replyTo: replyTo,
                            text: text,
                            replyMarkup: nil
                        )
                    )
                    isFirstMessage = false
                    return true
                } catch {
                    if let telegramError = error as? TelegramAPIError,
                       let retryAfter = telegramError.retryAfter, attempt < 2 {
                        try? await Task.sleep(nanoseconds: UInt64(retryAfter) * 1_000_000_000)
                    } else {
                        logger.error("draft persist failed: \(error)")
                        return false
                    }
                }
            }
            return false
        }

        func removeControlMessage() async {
            try? await telegram.deleteMessage(chatID: chatKey.chatID, messageID: controlMessage.message_id)
        }

        do {
            try Task.checkCancellation()
            let stream = gateway.stream(request)

            for try await event in stream {
                if Task.isCancelled {
                    isCancelled = true
                    break
                }

                switch event {
                case .text(let chunk):
                    fullAccumulator += chunk
                    messageAccumulator += chunk

                    // Budget in *rendered* characters: escaping (`&` → `&amp;`)
                    // is what actually counts against Telegram's 4096.
                    if MessageSplitter.renderedLength(messageAccumulator) >= MessageSplitter.charLimit {
                        let (done, remaining) = MessageSplitter.splitRendered(messageAccumulator)
                        let prefix = isFirstMessage ? "" : "<i>↑ продолжение</i>\n\n"
                        _ = await persist(prefix + done + "\n\n<i>↓ продолжение ниже</i>")
                        messageAccumulator = remaining
                        await draft.rotate(initialText: remaining)
                        continue
                    }

                    await draft.update(text: messageAccumulator)

                case .meta(let meta):
                    streamMeta = meta
                }
            }
        } catch is CancellationError {
            isCancelled = true
        } catch {
            logger.error("stream failed: \(error)")
            await draft.finish()
            _ = await persist("⚠️ <b>Не получилось ответить</b>\n" + UserFacingError.message(error))
            await removeControlMessage()
            await state.cancelPendingTurn(chatKey: chatKey, generationID: generationID)
            await refundPremium(premiumTicket)
            await finishGeneration(generationID)
            return
        }

        if Task.isCancelled {
            isCancelled = true
        }
        if !isCancelled {
            // Let the typewriter catch up so the final message doesn't jump.
            await draft.awaitReveal()
        }
        await draft.finish()

        let finalText: String
        if isCancelled {
            let stopNotice = await cancellationNotice(for: generationID)
            finalText = messageAccumulator.isEmpty
                ? stopNotice
                : (isFirstMessage ? "" : "<i>↑ продолжение</i>\n\n") + messageAccumulator + "\n\n" + stopNotice
        } else {
            let footer = await makeFooter(
                streamMeta: streamMeta,
                fallbackModel: fallbackModel,
                options: options,
                billedTo: billedTo,
                hasContent: !fullAccumulator.isEmpty,
                sponsorLine: sponsorLine
            )

            let prefix = isFirstMessage ? "" : "<i>↑ продолжение</i>\n\n"
            finalText = messageAccumulator.isEmpty
                ? "<i>Пустой ответ.</i>\(footer)"
                : prefix + messageAccumulator + footer
        }

        if await persist(finalText) {
            await removeControlMessage()
        } else {
            // Last resort: park the text in the control message instead of
            // losing the reply with the expiring draft.
            try? await telegram.editMessage(
                .init(
                    chatID: chatKey.chatID,
                    messageID: controlMessage.message_id,
                    text: finalText,
                    replyMarkup: InlineKeyboardMarkup(inline_keyboard: [])
                )
            )
        }

        if isCancelled {
            await state.cancelPendingTurn(chatKey: chatKey, generationID: generationID)
            await refundPremium(premiumTicket)
        } else if !fullAccumulator.isEmpty {
            let walletEmptied = await state.appendAssistant(chatKey: chatKey, generationID: generationID, content: fullAccumulator, usage: streamMeta?.usage, billedTo: billedTo)
            if walletEmptied {
                await sendBalanceEmptyNotice(chatKey: chatKey)
            }
            if let limit = lastPremiumCall {
                await sendLastPremiumCallNotice(chatKey: chatKey, isGroup: false, limit: limit)
            }
            if adEligible {
                await maybeServeAd(chatKey: chatKey, isPrivate: true)
            }
        } else {
            await state.cancelPendingTurn(chatKey: chatKey, generationID: generationID)
            await refundPremium(premiumTicket)
        }
        await finishGeneration(generationID)
    }

    /// Legacy streaming for group chats and Bot API servers without drafts:
    /// the placeholder message is edited in place as chunks arrive.
    private func runEditStreaming(
        gateway: ProviderGatewayPort,
        request: ProviderGatewayRequest,
        fallbackModel: String,
        options: GenerationOptions,
        chatKey: ChatKey,
        generationID: GenerationID,
        placeholder: TelegramMessage,
        stopMarkup: InlineKeyboardMarkup,
        adEligible: Bool,
        billedTo: String?,
        sponsorLine: String?,
        premiumTicket: DailyPremiumTicket?,
        lastPremiumCall: Int?
    ) async {
        let emptyMarkup = InlineKeyboardMarkup(inline_keyboard: [])
        let logger = self.logger
        var fullAccumulator = ""
        var messageAccumulator = ""
        var currentPlaceholder = placeholder
        var streamMeta: StreamMeta?
        var lastLength = 0
        let clock = ContinuousClock()
        var lastEdit = clock.now
        var isCancelled = false
        var isFirstMessage = true

        func sendContinuationPlaceholder() async -> TelegramMessage? {
            try? await telegram.sendMessage(
                .init(
                    chatID: chatKey.chatID,
                    threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                    replyTo: nil,
                    text: "💭 <i>Продолжаю…</i>",
                    replyMarkup: stopMarkup
                )
            )
        }

        func splitAndContinue() async throws {
            let (done, remaining) = MessageSplitter.splitRendered(messageAccumulator)
            try? await telegram.editMessage(
                .init(
                    chatID: chatKey.chatID,
                    messageID: currentPlaceholder.message_id,
                    text: done + "\n\n<i>↓ продолжение ниже</i>",
                    replyMarkup: stopMarkup
                )
            )
            guard let next = await sendContinuationPlaceholder() else {
                throw CancellationError()
            }
            currentPlaceholder = next
            messageAccumulator = remaining
            lastLength = 0
            lastEdit = clock.now
            isFirstMessage = false
        }

        do {
            try Task.checkCancellation()
            let stream = gateway.stream(request)

            for try await event in stream {
                if Task.isCancelled {
                    isCancelled = true
                    break
                }

                switch event {
                case .text(let chunk):
                    fullAccumulator += chunk
                    messageAccumulator += chunk

                    // Rendered length, not raw: the escaped text is what
                    // Telegram measures (see `MessageSplitter.splitRendered`).
                    if MessageSplitter.renderedLength(messageAccumulator) >= MessageSplitter.charLimit {
                        try await splitAndContinue()
                        continue
                    }

                    if clock.now - lastEdit > .seconds(3) || (messageAccumulator.count - lastLength) > 300 {
                        do {
                            try await self.telegram.editMessage(
                                .init(
                                    chatID: chatKey.chatID,
                                    messageID: currentPlaceholder.message_id,
                                    text: messageAccumulator,
                                    replyMarkup: stopMarkup
                                )
                            )
                            lastEdit = clock.now
                            lastLength = messageAccumulator.count
                        } catch {
                            if let telegramError = error as? TelegramAPIError,
                               let retryAfter = telegramError.retryAfter {
                                try? await Task.sleep(nanoseconds: UInt64(retryAfter) * 1_000_000_000)
                            } else {
                                throw error
                            }
                        }
                    }

                case .meta(let meta):
                    streamMeta = meta
                }
            }
        } catch is CancellationError {
            isCancelled = true
        } catch {
            logger.error("stream failed: \(error)")
            let userText = "⚠️ <b>Не получилось ответить</b>\n" + UserFacingError.message(error)
            try? await self.telegram.editMessage(
                .init(
                    chatID: chatKey.chatID,
                    messageID: currentPlaceholder.message_id,
                    text: userText,
                    replyMarkup: emptyMarkup
                )
            )
            await self.state.cancelPendingTurn(chatKey: chatKey, generationID: generationID)
            await self.refundPremium(premiumTicket)
            await self.finishGeneration(generationID)
            return
        }

        if Task.isCancelled {
            isCancelled = true
        }

        let finalText: String
        if isCancelled {
            let stopNotice = await self.cancellationNotice(for: generationID)
            finalText = messageAccumulator.isEmpty
                ? stopNotice
                : (isFirstMessage ? "" : "<i>↑ продолжение</i>\n\n") + messageAccumulator + "\n\n" + stopNotice
        } else {
            let footer = await makeFooter(
                streamMeta: streamMeta,
                fallbackModel: fallbackModel,
                options: options,
                billedTo: billedTo,
                hasContent: !fullAccumulator.isEmpty,
                sponsorLine: sponsorLine
            )

            let prefix = isFirstMessage ? "" : "<i>↑ продолжение</i>\n\n"
            finalText = messageAccumulator.isEmpty
                ? "<i>Пустой ответ.</i>\(footer)"
                : prefix + messageAccumulator + footer
        }

        try? await self.telegram.editMessage(
            .init(
                chatID: chatKey.chatID,
                messageID: currentPlaceholder.message_id,
                text: finalText,
                replyMarkup: emptyMarkup
            )
        )

        // Edit streaming serves groups *and* private chats on Bot API servers
        // without drafts, so the copy has to be chosen per chat, not per mode.
        let isGroup = chatKey.chatID < 0
        if isCancelled {
            await self.state.cancelPendingTurn(chatKey: chatKey, generationID: generationID)
            await self.refundPremium(premiumTicket)
        } else if !fullAccumulator.isEmpty {
            let walletEmptied = await self.state.appendAssistant(chatKey: chatKey, generationID: generationID, content: fullAccumulator, usage: streamMeta?.usage, billedTo: billedTo)
            if walletEmptied {
                await self.sendBalanceEmptyNotice(chatKey: chatKey)
            }
            if let limit = lastPremiumCall {
                await self.sendLastPremiumCallNotice(chatKey: chatKey, isGroup: isGroup, limit: limit)
            }
            if adEligible {
                await self.maybeServeAd(chatKey: chatKey, isPrivate: !isGroup)
            }
        } else {
            await self.state.cancelPendingTurn(chatKey: chatKey, generationID: generationID)
            await self.refundPremium(premiumTicket)
        }
        await self.finishGeneration(generationID)
    }

    private func sendUserFeedback(chatKey: ChatKey, text: String) async throws {
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
    
    private func unsupportedMediaKinds(
        in refs: [InboundMediaRef],
        capabilities: ProviderCapabilities
    ) -> [InboundMediaKind] {
        var unsupportedKinds: [InboundMediaKind] = []
        
        for kind in refs.map(\.kind) where !capabilities.supports(kind) && !unsupportedKinds.contains(kind) {
            unsupportedKinds.append(kind)
        }
        
        return unsupportedKinds
    }
    
    private func extractMediaRefs(from message: TelegramMessage) -> [InboundMediaRef] {
        var refs: [InboundMediaRef] = []
        
        // Synthetic merged albums expose one already-selected photo per album item here.
        if let albumPhotos = message.album_photos, !albumPhotos.isEmpty {
            refs.append(contentsOf: albumPhotos.map { .photo(fileID: $0.file_id) })
        } else if let photos = message.photo, let bestPhoto = TelegramPhotoAlbumBuffer.selectPrimaryPhoto(from: photos) {
            refs.append(.photo(fileID: bestPhoto.file_id))
        }
        if let voice = message.voice {
            refs.append(.voice(fileID: voice.file_id, mimeType: voice.mime_type))
        }
        if let video = message.video {
            refs.append(.video(fileID: video.file_id, mimeType: video.mime_type))
        }
        
        return refs
    }
    
    private func cancellationNotice(for generationID: GenerationID) async -> String {
        let reason = await sessionRegistry.cancellationReason(for: generationID) ?? .userRequested
        
        switch reason {
        case .userRequested:
            return "⏹ <i>Остановлено</i>"
        }
    }
}
