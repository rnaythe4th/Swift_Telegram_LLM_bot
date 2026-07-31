import Foundation

// Money. Pre-checkout validation, the successful-payment handler (both
// branches: subscription and credit pack) and the referral conversion bonus
// that rides along with it.
//
// Every path here is idempotent by charge id and flushes state before it
// reports success: Telegram redelivers, and a lost payment is not recoverable
// from our side (CLAUDE.md §7).

extension BotOrchestrator {
    func handlePreCheckoutQuery(_ query: TelegramPreCheckoutQuery) async {
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
    func handleSuccessfulPayment(message: TelegramMessage, payment: TelegramSuccessfulPayment) async {
        // Telegram redelivers updates after webhook timeouts and restarts; the
        // charge ID is what makes activation idempotent, and `fulfil` checks it.
        let chargeID = payment.telegram_payment_charge_id

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

        // `credits_<cents>` buys balance, anything else buys the subscription.
        // Everything that follows from either — activation, wallet, funnel,
        // referral bonus, traffic attribution, the flush — is one shared
        // routine, so this path cannot drift from the crypto and hosted-checkout
        // ones (CLAUDE.md §17).
        let payload = payment.invoice_payload
        let purpose: PurchasePurpose
        if payload.hasPrefix("credits_"),
           let cents = Int(payload.dropFirst("credits_".count)),
           CreditPack.isValid(cents: cents) {
            purpose = .credit(cents: cents)
        } else {
            purpose = .subscription
        }

        let outcome = await fulfillment.fulfil(PaymentReceipt(
            payerKey: payerKey,
            payerUserID: payer.id,
            chatID: message.chat.id,
            purpose: purpose,
            idempotencyKey: chargeID
        ))

        let activation: SubscriptionActivation
        let claim: ChatContextStore.ChatClaimOutcome
        switch outcome {
        case .duplicate:
            return

        case .credit(let cents, let wallet):
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

        case .subscription(let resolvedActivation, let resolvedClaim):
            activation = resolvedActivation
            claim = resolvedClaim
        }

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
}
