import Foundation

// What a turn costs and what it sells: ads, the daily-limit and empty-wallet
// offers, the referral payout and the footer under the answer.

extension GenerationCoordinator {
    /// Free-tier monetization: after a completed reply in a chat without an
    /// active paid licence, the store may pick an ad campaign to show
    /// (frequency + pacing rules live there). Failure to send is non-fatal.
    func maybeServeAd(chatKey: ChatKey, isPrivate: Bool) async {
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
                    callback_data: BotCallbackAction.menu(action: MenuRoute.purchase(from: .promo)).rawData
                )
            ]]
            let referral = await state.referralConfig()
            if isPrivate, referral.enabled, referral.inviterRewardCents > 0 {
                rows.append([InlineKeyboardButton(
                    text: "🎁 Пригласить друга · +\(ReferralConfig.formatUsd(cents: referral.inviterRewardCents))",
                    callback_data: BotCallbackAction.menu(action: MenuRoute.navigation(to: .referral)).rawData
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
    func sendDailyLimitOffer(chatKey: ChatKey, isGroup: Bool, limit: Int, freeModel: String) async throws {
        let payAction = BotCallbackAction.menu(action: MenuRoute.purchase(from: .cap)).rawData
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
                    callback_data: BotCallbackAction.menu(action: MenuRoute.navigation(to: .referral)).rawData
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
    func sendLastPremiumCallNotice(chatKey: ChatKey, isGroup: Bool, limit: Int) async {
        let payAction = BotCallbackAction.menu(action: MenuRoute.purchase(from: .cap)).rawData
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
    func sendBalanceEmptyNotice(chatKey: ChatKey) async {
        let payAction = BotCallbackAction.menu(action: MenuRoute.purchase(from: .balance)).rawData
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
    struct DailyPremiumTicket: Sendable {
        let chatID: ChatID
        let userID: UserID?
        let isGroup: Bool
    }

    /// What the free-tier gate decided for this turn: the booked daily-premium
    /// unit (if any) and, when it was the last unit of the day, the limit to
    /// say out loud once the answer has landed.
    struct DailyPremiumVerdict: Sendable {
        let ticket: DailyPremiumTicket?
        let lastCall: Int?
    }

    /// Free-tier gate with a daily premium "taste": a sender without full
    /// access who selected a paid model gets N smart-model answers per day
    /// (group = shared per chat, private = per user). Once the daily
    /// allowance is spent, the chat falls back to the first free model and an
    /// upgrade is pitched at the pain point. Free models are unlimited
    /// (retention); sponsored chats never reach here (hasFullModelAccess).
    ///
    /// Returns nil when the turn must be abandoned — the user has been told why.
    func resolveDailyPremium(origin: GenerationOrigin, chatKey: ChatKey) async throws -> DailyPremiumVerdict? {
        // Spending ceilings come first, because they are the only gate that
        // applies to people who *have* paid (§4.1). A subscription is a fixed
        // price and cannot buy unbounded consumption; without this the first
        // sign of a heavy group on an expensive model is the provider's
        // invoice, weeks later.
        if try await applySpendCap(chatKey: chatKey) == false { return nil }

        let hasAccess = await state.hasFullModelAccess(
            key: origin.userKey,
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
        } else {
            // What a free-tier chat may run comes from OpenRouter's catalogue,
            // the super-admin's pins and the models behind 🆓 modes. When none
            // of them is available the set is unknown — and an unknown set must
            // not mean "everything is free": that is the one failure mode that
            // hands every paid model to every user at the owner's expense,
            // silently, for as long as the catalogue is unreachable. Unknown is
            // therefore treated as "assume paid": the daily allowance still
            // applies, and only the fallback is missing.
            let effectiveFree = await state.allowedFreeModelIDs()
            if effectiveFree == nil {
                logger.warning("free-model set unknown (OpenRouter catalogue unavailable) — treating paid models as capped", context: LogContext(chat: chatKey))
            }
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
            if !(effectiveFree?.contains(currentModel) ?? false) {
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
                    // The fallback is resolved here rather than before the
                    // allowance is spent: a turn that stays inside the daily
                    // quota needs no fallback at all, so an unreachable
                    // catalogue must not cost the user a unit for nothing.
                    guard let firstFree = await state.fallbackFreeModel() else {
                        // Nothing free to fall back to. Refusing is the only
                        // honest option — the alternative is answering on a paid
                        // model, for free, to someone who has spent their quota.
                        try await sendUserFeedback(
                            chatKey: chatKey,
                            text: "ℹ️ Умные ответы на сегодня закончились, а бесплатные модели сейчас недоступны. Попробуйте позже или откройте премиум: /buy"
                        )
                        return nil
                    }
                    await state.downgradeModelToFree(chatKey: chatKey, freeModel: firstFree)
                    try? await sendDailyLimitOffer(chatKey: chatKey, isGroup: isGroup, limit: limit, freeModel: firstFree)
                }
            }
        }
        return DailyPremiumVerdict(ticket: premiumTicket, lastCall: lastPremiumCall)
    }

    /// Applies the daily spending ceilings. Returns false when the turn must be
    /// abandoned; the user has been told why.
    ///
    /// Free models cost nothing and are never gated: a ceiling that switches
    /// the bot off entirely would turn an accounting limit into an outage.
    private func applySpendCap(chatKey: ChatKey) async throws -> Bool {
        guard let verdict = await state.spendVerdict(chatID: chatKey.chatID) else { return true }
        let currentModel = await state.model(chatKey: chatKey)
        guard await state.allowedFreeModelIDs()?.contains(currentModel) != true else { return true }

        switch verdict {
        case .global(let spent, let cap):
            // Everything the bot spends today is gone. Falling back to a free
            // model keeps the bot answering; refusing outright would punish
            // every user for one heavy chat.
            logger.error("daily global spend cap reached: \(spent) of \(cap)")
            await alerter?.report(
                .spendCapReached, active: true,
                detail: "потрачено \(spent.formatted(fractionDigits: 2)) из \(cap.formatted(fractionDigits: 2))"
            )
            guard let free = await state.fallbackFreeModel() else {
                try await sendUserFeedback(
                    chatKey: chatKey,
                    text: "⏸ Умные модели на сегодня недоступны — дневной лимит расходов исчерпан. Завтра всё вернётся."
                )
                return false
            }
            await state.downgradeModelToFree(chatKey: chatKey, freeModel: free)
            try? await sendUserFeedback(
                chatKey: chatKey,
                text: "⏸ Дневной лимит расходов исчерпан — отвечаю на бесплатной модели <code>\(free)</code> до завтра."
            )
            return true

        case .tenant(let spent, let cap, let response):
            logger.warning("tenant spend cap reached: \(spent) of \(cap)", context: LogContext(chat: chatKey))
            switch response {
            case .refuse:
                try await sendUserFeedback(
                    chatKey: chatKey,
                    text: "⏸ Дневной лимит расходов этой подписки исчерпан (\(cap.formatted(fractionDigits: 2))). Ответы вернутся завтра."
                )
                return false
            case .downgradeToFree:
                guard let free = await state.fallbackFreeModel() else { return true }
                await state.downgradeModelToFree(chatKey: chatKey, freeModel: free)
                try? await sendUserFeedback(
                    chatKey: chatKey,
                    text: "⏸ Дневной лимит расходов исчерпан (\(cap.formatted(fractionDigits: 2))) — отвечаю на бесплатной модели <code>\(free)</code> до завтра."
                )
                return true
            }
        }
    }

    /// Billing: a chat covered by a tenant subscription costs the sender
    /// nothing; otherwise a sender with a positive balance pays per message
    /// (marked-up). Everyone else is free-tier → sees ads.
    func resolveBillingMode(
        origin: GenerationOrigin,
        chatKey: ChatKey
    ) async -> (billedTo: UserKey?, adEligible: Bool) {
        let covered = await state.hasSubscriptionCoverage(
            key: origin.userKey,
            userID: origin.user?.id,
            chatID: chatKey.chatID
        )
        // Wallet key, not a handle: charges follow the person through a rename
        // and work for someone who never set a @username.
        var billedTo: UserKey? = nil
        if !covered {
            billedTo = await state.billingKey(key: origin.userKey, userID: origin.user?.id)
        }
        return (billedTo, !covered && billedTo == nil)
    }

    /// Charges the answer to the payer's wallet, in a transaction, and mirrors
    /// the result into the store's cache. Returns true when this charge is the
    /// one that emptied the wallet — the pitch moment (roadmap step 5).
    ///
    /// A database that will not take the write means the answer is not billed.
    /// That costs the owner fractions of a cent; charging without a durable
    /// record would cost a customer their balance with nothing to show for it,
    /// and there is no version of that trade worth making.
    func chargeForAnswer(billedTo: UserKey?, cost: (real: Money, billed: Money), generationID: GenerationID) async -> Bool {
        guard let billedTo, cost.billed.isPositive else { return false }
        do {
            let debit = try await ledger.inTransaction { transaction in
                try await transaction.debit(
                    billedTo,
                    upTo: cost.billed,
                    real: cost.real,
                    ref: generationID.raw.uuidString
                )
            }
            await state.applyCommittedCharge(key: billedTo, debit: debit, real: cost.real)
            await noteBillingShortfall(billed: cost.billed, charged: debit.charged)
            return debit.depleted
        } catch {
            logger.error("could not charge \(cost.billed) to \(billedTo): \(error)", context: LogContext(generation: generationID))
            await metrics?.increment(MetricName.persistenceErrors)
            return false
        }
    }

    /// An answer whose price outran the wallet is a gift the owner paid for.
    /// It is bounded (one turn, from a wallet already below
    /// `minimumBillableBalance`) but it must not be invisible: a counter that
    /// climbs says the billable floor is set too low.
    func noteBillingShortfall(billed: Money, charged: Money) async {
        let shortfall = billed - charged
        guard shortfall.isPositive else { return }
        await metrics?.increment(MetricName.billingShortfallNanos, by: Int(shortfall.nanoValue))
    }

    /// A free user's daily allowance is tiny — a provider error, a stop or an
    /// empty reply must not eat one of it.
    func refundPremium(_ ticket: DailyPremiumTicket?) async {
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
    func payReferralIfDue(userID: UserID, username: String?) async {
        guard let payout = await state.redeemReferralIfDue(userID: userID, username: username) else { return }
        // The store decided the pair is due and stamped it; the money moves
        // here, once, guarded by its own claim (§10.2). A failure leaves the
        // stamp without the credit — visible in `reconcile()` and in the log,
        // and far better than a second payout.
        do {
            try await ledger.inTransaction { transaction in
                guard try await transaction.claim("refsignup:\(userID)") else { return }
                if payout.inviterReward.isPositive {
                    try await transaction.credit(
                        UserKey.identified(payout.inviterUserID), payout.inviterReward,
                        kind: .referral, purchased: false, ref: "refsignup:\(userID)"
                    )
                }
                if payout.inviteeReward.isPositive {
                    try await transaction.credit(
                        UserKey.identified(userID), payout.inviteeReward,
                        kind: .referral, purchased: false, ref: "refsignup:\(userID):friend"
                    )
                }
            }
            await state.applyCommittedCredit(key: UserKey.identified(payout.inviterUserID), amount: payout.inviterReward)
            await state.applyCommittedCredit(key: UserKey.identified(userID), amount: payout.inviteeReward)
        } catch {
            logger.error("referral payout not credited: \(error)", context: LogContext(user: userID))
            return
        }
        let refButton = InlineKeyboardButton(
            text: "🎁 Пригласить друга",
            callback_data: BotCallbackAction.menu(action: MenuRoute.navigation(to: .referral)).rawData
        )

        if payout.inviteeReward.isPositive {
            _ = try? await telegram.sendMessage(.init(
                chatID: userID.privateChat,
                threadID: nil,
                replyTo: nil,
                text: "🎁 <b>Бонус за приглашение: \(payout.inviteeReward.formatted(fractionDigits: 2)) на баланс</b> — спасибо \(payout.inviterUsername)!"
                    + "\n\nПока баланс не пуст, вам доступны любые модели: с него списывается стоимость каждого ответа, обычно доли цента."
                    + " Сколько списалось — видно под самим ответом (включите показ: /show_cost).\n\nВаша ссылка для друзей — /ref.",
                replyMarkup: InlineKeyboardMarkup(inline_keyboard: [[refButton]])
            ))
        }

        if payout.inviterReward.isPositive {
            // The label works without a @username (the migration to userID keys
            // made nicks optional), so a friend without one is still named.
            let notified = (try? await telegram.sendMessage(.init(
                chatID: payout.inviterUserID.privateChat,
                threadID: nil,
                replyTo: nil,
                text: "🎉 <b>Ваше приглашение сработало: \(payout.invitedLabel) уже пишет боту.</b>"
                    + "\n\nВам начислено <b>\(payout.inviterReward.formatted(fractionDigits: 2))</b> на баланс"
                    + " · приглашений с наградой: <b>\(payout.inviterRewardedTotal)</b>.",
                replyMarkup: InlineKeyboardMarkup(inline_keyboard: [[refButton]])
            ))) != nil
            if !notified {
                // Money is already on their balance; only the good news failed
                // to land (blocked DM, never wrote to the bot).
                logger.warning("referral: could not notify the inviter about +\(payout.inviterReward)", context: LogContext(user: payout.inviterUserID))
            }
        }

        logger.info("referral payout: inviter +\(payout.inviterReward), friend +\(payout.inviteeReward)", context: LogContext(user: userID))
    }

    /// Customer-facing footer: costs go through the markup multiplier; for
    /// balance-billed users the projected post-charge balance is appended
    /// (the actual deduction in appendAssistant uses the same formula).
    func makeFooter(
        streamMeta: StreamMeta?,
        fallbackModel: String,
        options: GenerationOptions,
        billedTo: UserKey?,
        hasContent: Bool,
        sponsorLine: String?
    ) async -> String {
        let multiplier = await state.priceMultiplier()
        var balanceAfter: Money?
        if let billedTo, hasContent {
            let realCost = Money.usd(streamMeta?.usage?.cost ?? 0)
            balanceAfter = await state.projectedBalanceAfterCharge(key: billedTo, realCost: realCost)
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
    func sponsorCreditLine(chatID: ChatID, asker: UserKey?, isPrivate: Bool) async -> String? {
        guard !isPrivate else { return nil }
        guard let sponsor = await state.chatSponsorForCredit(chatID: chatID, asker: asker) else {
            return nil
        }
        return "⚡ премиум для чата открыл \(sponsor)"
    }
}
