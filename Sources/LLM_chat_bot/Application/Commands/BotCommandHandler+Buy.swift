import Foundation

// /buy: subscription and credit-pack invoices across every payment method.

extension BotCommandHandler {
    func handleBuy(chatKey: ChatKey, fromUser: TelegramUser?) async throws {
        // Nothing is sold while state is not durable (§4.3): a purchase written
        // into a memory that dies with the process takes real money and gives
        // back a subscription that lasts until the next redeploy.
        let durability = durability.value
        guard durability.acceptsPayments else {
            try await sendUserFeedback(chatKey: chatKey, text: "⏸ \(durability.purchaseRefusalMessage)")
            return
        }
        let starsPrice = await state.starsPrice()
        let cryptoPriceCents = await state.cryptoPriceUsdCents()
        let cryptoAssets: [CryptoAsset] = await {
            guard let service = cryptoService else { return [] }
            return await service.availableAssets()
        }()
        let cryptoAvailable = cryptoPriceCents != nil && !cryptoAssets.isEmpty
        // A credit pack costs its own face value, so paying for one in crypto
        // needs an address and nothing else — not the subscription price.
        let cryptoCreditsAvailable = !cryptoAssets.isEmpty
        let card = await state.cardConfig()
        let cardAvailable = card.isEnabled
        // Hosted checkout (§7): Сбер, СБП, карты РФ и крипта одним счётом.
        let external = await state.externalPaymentConfig()
        let externalAvailable = external.isEnabled

        // Credit packs are sold through their own switches (Stars rate / crypto
        // addresses / card FX rate), so /buy stays useful even when monthly
        // subscriptions are switched off (roadmap step 2).
        let creditsAvailable = await state.starsCreditsEnabled() || cryptoCreditsAvailable
            || card.creditsEnabled || external.creditsEnabled
        guard (starsPrice ?? 0) > 0 || cryptoAvailable || cardAvailable || externalAvailable || creditsAvailable else {
            try await sendUserFeedback(chatKey: chatKey, text: "ℹ️ Продажа доступа сейчас недоступна.")
            return
        }
        guard let buyerID = fromUser?.id else { return }
        // Purchases identify the buyer by userID, so a @username is optional.
        let username = state.userKey(userID: buyerID)
        await state.bumpPurchaseOpen(source: .command)
        // Prices for this user: a live winback discount (roadmap step 8) is
        // already applied, so quotes here match what checkout will charge.
        let pricing = await state.subscriptionPricing(username: username)
        // Existing tenant: unlimited → nothing to buy; with an expiry →
        // the same purchase flow extends the subscription.
        if await state.isTenant(username: username) {
            let sub = await state.tenantSubscription(ownerUsername: username)
            if sub.paidUntil == nil {
                try await sendUserFeedback(chatKey: chatKey, text: "✅ У вас бессрочный доступ к боту.")
                return
            }
            let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy"
            let statusLine = sub.isActive
                ? "Ваша подписка активна до <b>\(f.string(from: sub.paidUntil!))</b>."
                : "⛔ Ваша подписка истекла <b>\(f.string(from: sub.paidUntil!))</b>."
            var text = statusLine + "\nОплата ниже продлит её на \(ChatContextStore.subscriptionDays) дней."
            if let discount = pricing.discount, pricing.hasDiscount {
                let df = DateFormatter(); df.dateFormat = "dd.MM HH:mm"
                text += "\n🎁 Ваша скидка <b>−\(discount.percent)%</b> действует до <b>\(df.string(from: discount.expiresAt))</b>."
            }
            try await sendUserFeedback(chatKey: chatKey, text: text)
        }

        // Exactly one way to pay and nothing cheaper to offer → straight to the
        // invoice; otherwise show the choice, so the low-threshold top-up is
        // never hidden behind a single-method shortcut.
        let methodCount = ((starsPrice ?? 0) > 0 ? 1 : 0) + (cryptoAvailable ? 1 : 0)
            + (cardAvailable ? 1 : 0) + (externalAvailable ? 1 : 0)
        let discountNote = pricing.hasDiscount ? " · скидка −\(pricing.discount?.percent ?? 0)%" : ""
        if methodCount == 1, !creditsAvailable {
            if let starsAmount = pricing.stars, starsAmount > 0 {
                try await telegram.sendInvoice(.init(
                    chatID: chatKey.chatID,
                    title: "Премиум-доступ · \(ChatContextStore.subscriptionDays) дней\(discountNote)",
                    description: "Умные модели (GPT, Claude, Gemini), без рекламы и лимитов — для этого чата и вашей лички",
                    payload: "buy_access",
                    starsAmount: starsAmount
                ))
                await state.bumpFunnel(.invoiceSent)
                return
            }
            if cryptoAvailable {
                await menuHandler.sendCryptoAssetChoice(chatKey: chatKey, username: username)
                return
            }
            if cardAvailable, let token = card.providerToken, let minorUnits = pricing.cardMinorUnits {
                try await telegram.sendInvoice(.init(
                    chatID: chatKey.chatID,
                    title: "Премиум-доступ · \(ChatContextStore.subscriptionDays) дней\(discountNote)",
                    description: "Умные модели (GPT, Claude, Gemini), без рекламы и лимитов — для этого чата и вашей лички",
                    payload: "buy_access_card",
                    kind: .fiat(currency: card.currency.rawValue, amountMinorUnits: minorUnits, providerToken: token)
                ))
                await state.bumpFunnel(.invoiceSent)
                return
            }
        }

        // Several methods available → choice menu
        var rows: [[InlineKeyboardButton]] = []
        if let starsAmount = pricing.stars, starsAmount > 0 {
            rows.append([InlineKeyboardButton(
                text: "💫 Stars · \(starsAmount) ⭐\(discountNote)",
                callback_data: BotCallbackAction.menu(action: MenuRoute.link(.buy, "stars")).rawData
            )])
        }
        if cryptoAvailable, let cents = pricing.cryptoCents {
            let label = String(format: "🪙 Криптовалюта · $%.2f", Double(cents) / 100.0)
            rows.append([InlineKeyboardButton(
                text: label,
                callback_data: BotCallbackAction.menu(action: MenuRoute.link(.buy, "crypto")).rawData
            )])
        }
        if cardAvailable, let minorUnits = pricing.cardMinorUnits {
            rows.append([InlineKeyboardButton(
                text: "💳 Картой · \(card.currency.format(minorUnits: minorUnits))",
                callback_data: BotCallbackAction.menu(action: MenuRoute.link(.buy, "card")).rawData
            )])
        }
        if externalAvailable, let minorUnits = pricing.externalMinorUnits {
            rows.append([InlineKeyboardButton(
                text: "🏦 \(menuHandler.externalMethodsLabel(external)) · \(external.currency.format(minorUnits: minorUnits))\(discountNote)",
                callback_data: BotCallbackAction.menu(action: MenuRoute.link(.buy, "ext")).rawData
            )])
        }
        // Lower entry point right next to the monthly price: a top-up is the
        // first payment most people are willing to make (roadmap step 2).
        var creditsNote = ""
        if creditsAvailable {
            rows.append(CreditPack.centsOptions.map {
                InlineKeyboardButton(
                    text: "💰 \(CreditPack.label(cents: $0))",
                    callback_data: BotCallbackAction.menu(action: MenuRoute.link(.buy, "credits", "\($0)")).rawData
                )
            })
            creditsNote = "\n\n💰 <b>Не готовы на месяц?</b> Пополните баланс — с него списывается стоимость каждого ответа, обычно доли цента. Подписка при этом не нужна."
        }
        let markup = InlineKeyboardMarkup(inline_keyboard: rows)
        _ = try await telegram.sendMessage(.init(
            chatID: chatKey.chatID,
            threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
            replyTo: nil,
            text: """
            <b>💳 Выберите способ оплаты</b>

            Доступ включится автоматически сразу после оплаты.\(creditsNote)
            """,
            replyMarkup: markup
        ))
    }
}
