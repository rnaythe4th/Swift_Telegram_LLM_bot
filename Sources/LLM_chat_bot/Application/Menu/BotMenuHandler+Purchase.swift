import Foundation

// Purchase page and the buy flow: subscription and credit packs over Stars,
// card and crypto.

extension BotMenuHandler {
    /// `username` is needed to quote the same price the invoice will charge —
    /// a winback discount (roadmap step 8) is per user.
    func sendCryptoAssetChoice(chatKey: ChatKey, username: String? = nil) async {
        guard let service = cryptoService else {
            _ = try? await telegram.sendMessage(.init(
                chatID: chatKey.chatID,
                threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                replyTo: nil,
                text: "ℹ️ Крипто-оплата не настроена.",
                replyMarkup: nil
            ))
            return
        }
        let assets = await service.availableAssets()
        guard !assets.isEmpty else {
            _ = try? await telegram.sendMessage(.init(
                chatID: chatKey.chatID,
                threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                replyTo: nil,
                text: "ℹ️ Адреса для приёма крипто-оплаты не настроены.",
                replyMarkup: nil
            ))
            return
        }
        var rows: Keyboard = []
        for asset in assets {
            rows.row([menuButton(asset.displayLabel, .buy, "asset", "\(asset.rawValue)")])
        }
        rows.row([menuButton("✕ Отмена", command: .close)])

        let pricing = await state.subscriptionPricing(username: username)
        let cents = pricing.cryptoCents ?? 0
        let usd = String(format: "%.2f", Double(cents) / 100.0)
        var priceLine = "Сумма к оплате: <b>$\(usd)</b>"
        if let full = pricing.cryptoCentsFull, full != cents, let discount = pricing.discount {
            priceLine = String(
                format: "Сумма к оплате: <s>$%.2f</s> <b>$%.2f</b> (скидка −%d%%)",
                Double(full) / 100.0, Double(cents) / 100.0, discount.percent
            )
        }
        let text = """
        <b>🪙 Оплата криптой</b>

        \(priceLine)

        Выберите валюту/сеть:
        """
        _ = try? await telegram.sendMessage(.init(
            chatID: chatKey.chatID,
            threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
            replyTo: nil,
            text: text,
            replyMarkup: rows.markup
        ))
    }

    /// Buy flow: subscription and credit packs.
    func processPurchaseAction(
        route: MenuRoute,
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        switch route.command {
        case .buy:
            try await handleBuyAction(route: route, chatKey: chatKey, callback: callback, message: message)
            return

        default:
            break
        }
    }

    func renderPay(chatKey: ChatKey, username: String?) async -> MenuScreen {
        // The purchase page itself makes sense in a group (anyone can open
        // premium for the chat), but the menu message there is shared: balance,
        // subscription dates and a personal winback discount would become public
        // (CLAUDE.md §17). In a group we quote the price list and keep every
        // personal number for the DM.
        let isGroup = chatKey.chatID < 0
        let personalKey: String? = isGroup ? nil : username
        // Prices come from one place so a winback discount (roadmap step 8) is
        // quoted here exactly as it will be charged.
        let pricing = await state.subscriptionPricing(username: personalKey)
        let starsPrice = pricing.stars
        let cryptoCents = pricing.cryptoCents
        let cryptoAssets: [CryptoAsset] = await {
            guard let service = cryptoService else { return [] }
            return await service.availableAssets()
        }()
        let starsAvailable = (starsPrice ?? 0) > 0
        let cryptoAvailable = cryptoCents != nil && !cryptoAssets.isEmpty
        let card = await state.cardConfig()
        // Hosted checkout (§7): the rails Telegram cannot reach — Сбер, СБП,
        // карты РФ, крипта — behind one aggregator.
        let external = await state.externalPaymentConfig()

        var lines: [String] = ["<b>⚡ Премиум-доступ для этого чата</b>", ""]
        var rows: Keyboard = []
        var unlimited = false

        if isGroup {
            // Public facts only: who (if anyone) already pays for this chat.
            if let sponsor = await state.chatSponsor(chatID: chatKey.chatID, askerUsername: nil) {
                lines.append("✅ Здесь премиум уже работает — его открыл <b>\(sponsor)</b>.")
                lines.append("")
                lines.append("""
                Своя подписка нужна, если хотите то же самое <b>в личке с ботом и в своих чатах</b>:
                • Умные модели — GPT, Claude, Gemini (точнее и способнее бесплатных)
                • Без рекламы и без дневных лимитов
                • Одна оплата — доступ во всех ваших чатах, на <b>\(ChatContextStore.subscriptionDays) дней</b>
                """)
            } else {
                lines.append("""
                Что открывается:
                • Умные модели — GPT, Claude, Gemini (точнее и способнее бесплатных)
                • Без рекламы
                • Без дневных лимитов
                • Работает у всех в этом чате — и в вашей личке с ботом

                Одна оплата — доступ во всех ваших чатах, на <b>\(ChatContextStore.subscriptionDays) дней</b>.
                """)
            }
            lines.append("")
            lines.append("<i>Цены — общие. Ваш баланс, срок вашей подписки и личные скидки видны только в личке с ботом: /menu.</i>")
        } else if let username = personalKey {
            if await state.isTenant(username: username) {
                let sub = await state.tenantSubscription(ownerUsername: username)
                let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy"
                if sub.paidUntil == nil {
                    lines.append("✅ У вас <b>бессрочный</b> доступ — покупать нечего.")
                    unlimited = true
                } else if let until = sub.paidUntil, sub.isActive {
                    lines.append("💳 Подписка активна до <b>\(f.string(from: until))</b>.")
                    lines.append("<i>Оплата ниже продлит её на \(ChatContextStore.subscriptionDays) дней (срок прибавляется).</i>")
                } else if let until = sub.paidUntil {
                    lines.append("⛔ Подписка истекла <b>\(f.string(from: until))</b>.")
                    lines.append("<i>Оплата ниже возобновит доступ на \(ChatContextStore.subscriptionDays) дней — чаты и настройки сохранены.</i>")
                }
                lines.append("Управление доступом — /menu → ⚡ Мой премиум.")
            } else {
                // Someone else already opened this chat: credit them and pitch
                // what a purchase would still add (roadmap step 3) instead of
                // selling access this person already enjoys here.
                let access = await state.chatAccessStatus(chatID: chatKey.chatID, username: username)
                if let payer = access.payerUsername {
                    lines.append("✅ Здесь премиум уже работает — его открыл <b>\(payer)</b>.")
                    lines.append("")
                    lines.append("""
                    Своя подписка нужна, если хотите то же самое <b>в личке с ботом и в своих чатах</b>:
                    • Умные модели — GPT, Claude, Gemini (точнее и способнее бесплатных)
                    • Без рекламы и без дневных лимитов
                    • Одна оплата — доступ во всех ваших чатах, на <b>\(ChatContextStore.subscriptionDays) дней</b>
                    """)
                } else {
                    lines.append("""
                    Что открывается:
                    • Умные модели — GPT, Claude, Gemini (точнее и способнее бесплатных)
                    • Без рекламы
                    • Без дневных лимитов
                    • Работает у всех в этом чате — и в вашей личке с ботом

                    Одна оплата — доступ во всех ваших чатах, на <b>\(ChatContextStore.subscriptionDays) дней</b>.
                    """)
                }
            }
            if let wallet = await state.balance(username: username) {
                lines.append("")
                lines.append(String(format: "💰 Баланс · <b>$%.4f</b>", wallet.balanceUsd) + (wallet.balanceUsd > 0 ? "" : " <i>(исчерпан)</i>"))
                lines.append("<i>С баланса списывается стоимость каждого ответа — обычно доли цента. Подписка при этом не нужна. Подробнее — /balance.</i>")
            }
        } else {
            lines.append("<i>Оплата привяжется к вашему аккаунту Telegram — @username для этого не нужен.</i>")
        }

        if !unlimited {
            // Winback offer: show what it costs now vs. normally, with the
            // deadline — a discount nobody can see converts nobody.
            if let discount = pricing.discount, pricing.hasDiscount {
                let f = DateFormatter(); f.dateFormat = "dd.MM HH:mm"
                lines.append("")
                lines.append("🎁 <b>Скидка −\(discount.percent)%</b> действует до <b>\(f.string(from: discount.expiresAt))</b>.")
                if let stars = pricing.stars, let full = pricing.starsFull, full != stars {
                    lines.append("Stars: <s>\(full) ⭐</s> → <b>\(stars) ⭐</b>")
                }
                if let cents = pricing.cryptoCents, let full = pricing.cryptoCentsFull, full != cents {
                    lines.append(String(format: "Крипта: <s>$%.2f</s> → <b>$%.2f</b>", Double(full) / 100.0, Double(cents) / 100.0))
                }
                if let minor = pricing.cardMinorUnits, let full = pricing.cardMinorUnitsFull, full != minor {
                    lines.append("Карта: <s>\(card.currency.format(minorUnits: full))</s> → <b>\(card.currency.format(minorUnits: minor))</b>")
                }
                if let minor = pricing.externalMinorUnits, let full = pricing.externalMinorUnitsFull, full != minor {
                    lines.append("Касса: <s>\(external.currency.format(minorUnits: full))</s> → <b>\(external.currency.format(minorUnits: minor))</b>")
                }
            }

            if starsAvailable, let starsPrice {
                let suffix = pricing.hasDiscount && pricing.starsFull != starsPrice ? " (−\(pricing.discount?.percent ?? 0)%)" : ""
                rows.row([menuButton("💫 Оплатить Stars · \(starsPrice) ⭐\(suffix)", .buy, "stars")])
            }
            if cryptoAvailable, let cents = cryptoCents {
                rows.row([menuButton(String(format: "🪙 Криптовалюта · $%.2f", Double(cents) / 100.0), .buy, "crypto")])
            }
            if card.isEnabled, let minorUnits = pricing.cardMinorUnits {
                rows.row([menuButton("💳 Картой · \(card.currency.format(minorUnits: minorUnits))", .buy, "card")])
            }
            if external.isEnabled, let minorUnits = pricing.externalMinorUnits {
                let suffix = pricing.hasDiscount && pricing.externalMinorUnitsFull != minorUnits
                    ? " (−\(pricing.discount?.percent ?? 0)%)"
                    : ""
                rows.row([menuButton(
                    "🏦 \(externalMethodsLabel(external)) · \(external.currency.format(minorUnits: minorUnits))\(suffix)",
                    .buy, "ext"
                )])
            }
            if !starsAvailable, !cryptoAvailable, !card.isEnabled, !external.isEnabled {
                lines.append("")
                lines.append("ℹ️ Продажа доступа сейчас недоступна.")
            }

            // Pay-as-you-go credit packs — a lower entry point than a full
            // subscription. Their availability is deliberately independent of
            // the subscription prices: each method only needs its own knob
            // (Stars rate / crypto addresses / card FX rate).
            // Crypto packs need an address, not a subscription price: a pack
            // costs its own face value.
            let creditsAvailable = await state.starsCreditsEnabled() || !cryptoAssets.isEmpty
                || card.creditsEnabled || external.creditsEnabled
            if username != nil, creditsAvailable {
                lines.append("")
                lines.append("💰 <b>Не готовы на месяц?</b> Пополните баланс — с него списывается стоимость каждого ответа, обычно доли цента. Доступны любые модели, подписка не нужна.")
                let packRow = CreditPack.centsOptions.map {
                    menuButton(CreditPack.label(cents: $0), .buy, "credits", "\($0)")
                }
                rows.row(packRow)
            }

            // Free way to get a balance: bring a friend (roadmap step 10).
            let referral = await state.referralConfig()
            if referral.enabled, referral.inviterRewardCents > 0, !botUsername.isEmpty, chatKey.chatID > 0 {
                lines.append("")
                lines.append("🎁 <b>Не хотите платить?</b> Пригласите друга — как только он задаст боту первый вопрос, вы оба получите на баланс (\(ReferralConfig.formatUsd(cents: referral.inviterRewardCents)) вам, \(ReferralConfig.formatUsd(cents: referral.inviteeRewardCents)) ему).")
                rows.row([menuButton("🎁 Пригласить друга", page: .referral)])
            }
        }
        rows.row(navButtons())
        return MenuScreen(lines.joined(separator: "\n"), rows)
    }

    /// What to call the hosted checkout on a button. Naming the rails ("Сбер,
    /// СБП, карта") sells better than naming the aggregator, which no buyer has
    /// heard of — but the list is configuration, so it is derived, not written.
    func externalMethodsLabel(_ config: ExternalPaymentConfig) -> String {
        let titles = config.activeMethods.prefix(3).map(\.title)
        guard !titles.isEmpty else { return "Картой · СБП · Сбер" }
        return titles.joined(separator: " · ")
    }

    // MARK: - Buy flow (user-facing)

    private func handleBuyAction(
        route: MenuRoute,
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard !route.sub.isEmpty else { return }
        switch route.sub {
        case "credits":
            try await showCreditPackMethods(route: route, chatKey: chatKey, callback: callback, message: message)

        case "cstars", "ccard":
            try await sendCreditPackInvoice(route: route, chatKey: chatKey, callback: callback)

        case "stars", "card":
            try await sendSubscriptionInvoice(route: route, chatKey: chatKey, callback: callback)

        case "crypto", "ccrypto", "asset", "casset":
            try await handleCryptoPurchase(route: route, chatKey: chatKey, callback: callback, message: message)

        case "ext", "cext":
            try await handleExternalPurchase(route: route, chatKey: chatKey, callback: callback, message: message)

        case "extcancel":
            try await handleExternalCancel(route: route, callback: callback, message: message)

        case "refresh", "cancel":
            try await handleInvoiceControl(route: route, callback: callback, message: message)

        default:
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: nil)
        }
    }

    /// A pack was chosen → offer the payment methods that can top up a balance.
    private func showCreditPackMethods(
        route: MenuRoute,
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        // Pack chosen → offer the payment methods available for credits.
        guard let cents = route.int(2), CreditPack.isValid(cents: cents) else {
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: Texts.unknownPack)
            return
        }
        var rows: Keyboard = []
        if await state.starsCreditsEnabled() {
            let stars = await state.starsForCents(cents)
            rows.row([menuButton("💫 Stars · \(stars) ⭐", .buy, "cstars", "\(cents)")])
        }
        let cryptoAssets: [CryptoAsset]
        if let service = cryptoService { cryptoAssets = await service.availableAssets() } else { cryptoAssets = [] }
        // Only addresses are needed here — the pack is invoiced at its own
        // face value, so the subscription price has no say.
        if !cryptoAssets.isEmpty {
            rows.row([menuButton("🪙 Криптой", .buy, "ccrypto", "\(cents)")])
        }
        let creditCard = await state.cardConfig()
        if let minorUnits = creditCard.creditMinorUnits(cents: cents), creditCard.creditsEnabled {
            rows.row([menuButton("💳 Картой · \(creditCard.currency.format(minorUnits: minorUnits))", .buy, "ccard", "\(cents)")])
        }
        let creditExternal = await state.externalPaymentConfig()
        if creditExternal.creditsEnabled, let minorUnits = creditExternal.creditMinorUnits(cents: cents) {
            rows.row([menuButton(
                "🏦 \(externalMethodsLabel(creditExternal)) · \(creditExternal.currency.format(minorUnits: minorUnits))",
                .buy, "cext", "\(cents)"
            )])
        }
        rows.row(navButtons())
        let text = """
        💰 <b>Пополнить баланс на \(CreditPack.label(cents: cents))</b>

        Баланс — как счёт на телефоне: с него списывается стоимость каждого ответа бота. Обычно это доли цента, так что \(CreditPack.label(cents: cents)) хватает надолго. Доступны любые модели, подписка не нужна.

        Сколько списалось и сколько осталось — видно под самим ответом (включите показ: /show_cost).

        Выберите способ оплаты:
        """
        try await editOrAnswer(callback: callback, message: message, screen: MenuScreen(text, rows))
    }

    /// Invoice for a credit pack: Stars or card, priced by its own knob.
    private func sendCreditPackInvoice(
        route: MenuRoute,
        chatKey: ChatKey,
        callback: CallbackQuery
    ) async throws {
        switch route.sub {
        case "ccard":
            // Credit pack on the card. The pack's USD face value is converted
            // with the super-admin's FX rate (roadmap step 2).
            guard let cents = route.int(2), CreditPack.isValid(cents: cents) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: Texts.unknownPack)
                return
            }
            let packCard = await state.cardConfig()
            guard packCard.creditsEnabled, let token = packCard.providerToken,
                  let minorUnits = packCard.creditMinorUnits(cents: cents) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Пополнение картой отключено")
                return
            }
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: nil)
            try await telegram.sendInvoice(.init(
                chatID: chatKey.chatID,
                title: "Пополнение баланса · \(CreditPack.label(cents: cents))",
                description: "Деньги на баланс: с него списывается стоимость каждого ответа, доступны любые модели",
                payload: "credits_\(cents)",
                kind: .fiat(currency: packCard.currency.rawValue, amountMinorUnits: minorUnits, providerToken: token)
            ))
            await state.bumpFunnel(.invoiceSent)

        case "cstars":
            // Credit pack via Stars.
            guard let cents = route.int(2), CreditPack.isValid(cents: cents) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: Texts.unknownPack)
                return
            }
            guard await state.starsCreditsEnabled() else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Stars-оплата отключена")
                return
            }
            let stars = await state.starsForCents(cents)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: nil)
            try await telegram.sendInvoice(.init(
                chatID: chatKey.chatID,
                title: "Пополнение баланса · \(CreditPack.label(cents: cents))",
                description: "Деньги на баланс: с него списывается стоимость каждого ответа, доступны любые модели",
                payload: "credits_\(cents)",
                starsAmount: stars
            ))
            await state.bumpFunnel(.invoiceSent)

        default:
            break
        }
    }

    /// Invoice for the 30-day subscription. Prices come from
    /// `subscriptionPricing`, so a winback discount is charged as quoted.
    private func sendSubscriptionInvoice(
        route: MenuRoute,
        chatKey: ChatKey,
        callback: CallbackQuery
    ) async throws {
        switch route.sub {
        case "stars":
            // Identity is the userID; a @username is not needed to buy.
            let starsKey = state.userKey(userID: callback.from.id)
            // Winback discount, when live, is already baked into the price.
            let starsPricing = await state.subscriptionPricing(username: starsKey)
            guard let price = starsPricing.stars, price > 0 else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Stars-оплата отключена")
                return
            }
            // Unlimited tenants have nothing to buy; expiring ones renew.
            let starsSub = await state.tenantSubscription(ownerUsername: starsKey)
            if starsSub.exists, starsSub.paidUntil == nil {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "У вас бессрочный доступ")
                return
            }
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: nil)
            let starsDiscountNote = starsPricing.hasDiscount
                ? " · скидка −\(starsPricing.discount?.percent ?? 0)%"
                : ""
            try await telegram.sendInvoice(.init(
                chatID: chatKey.chatID,
                title: "Премиум-доступ · \(ChatContextStore.subscriptionDays) дней\(starsDiscountNote)",
                description: "Умные модели (GPT, Claude, Gemini), без рекламы и лимитов — для этого чата и вашей лички",
                payload: "buy_access",
                starsAmount: price
            ))
            await state.bumpFunnel(.invoiceSent)

        case "card":
            let card = await state.cardConfig()
            let cardKey = state.userKey(userID: callback.from.id)
            let cardPricing = await state.subscriptionPricing(username: cardKey)
            guard card.isEnabled, let token = card.providerToken, let minorUnits = cardPricing.cardMinorUnits else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Оплата картой отключена")
                return
            }
            let cardSub = await state.tenantSubscription(ownerUsername: cardKey)
            if cardSub.exists, cardSub.paidUntil == nil {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "У вас бессрочный доступ")
                return
            }
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: nil)
            let cardDiscountNote = cardPricing.hasDiscount
                ? " · скидка −\(cardPricing.discount?.percent ?? 0)%"
                : ""
            try await telegram.sendInvoice(.init(
                chatID: chatKey.chatID,
                title: "Премиум-доступ · \(ChatContextStore.subscriptionDays) дней\(cardDiscountNote)",
                description: "Умные модели (GPT, Claude, Gemini), без рекламы и лимитов — для этого чата и вашей лички",
                payload: "buy_access_card",
                kind: .fiat(currency: card.currency.rawValue, amountMinorUnits: minorUnits, providerToken: token)
            ))
            await state.bumpFunnel(.invoiceSent)

        default:
            break
        }
    }

    /// Crypto: pick the asset, then create (or refresh) the invoice.
    private func handleCryptoPurchase(
        route: MenuRoute,
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        switch route.sub {
        case "crypto":
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: nil)
            await sendCryptoAssetChoice(chatKey: chatKey, username: state.userKey(userID: callback.from.id))

        case "ccrypto":
            // Credit pack via crypto → pick asset (cents carried in callback).
            guard let cents = route.int(2), CreditPack.isValid(cents: cents) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: Texts.unknownPack)
                return
            }
            guard let service = cryptoService else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: Texts.cryptoUnavailable)
                return
            }
            let assets = await service.availableAssets()
            guard !assets.isEmpty else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Адреса не настроены")
                return
            }
            var assetRows = Keyboard(assets.map {
                [menuButton($0.displayLabel, .buy, "casset", "\($0.rawValue)", "\(cents)")]
            })
            assetRows.row(navButtons())
            let assetText = """
            🪙 <b>Пополнение баланса на \(CreditPack.label(cents: cents))</b>

            Выберите монету и сеть для оплаты:
            """
            try await editOrAnswer(callback: callback, message: message, screen: MenuScreen(assetText, assetRows))

        case "casset":
            guard let asset = route.arg(2).flatMap(CryptoAsset.init(rawValue:)),
                  let cents = route.int(3), CreditPack.isValid(cents: cents) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Неизвестная монета")
                return
            }
            guard let service = cryptoService else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: Texts.cryptoUnavailable)
                return
            }
            let creditKey = state.userKey(userID: callback.from.id)
            do {
                let invoice = try await service.createOrRefreshInvoice(
                    username: creditKey,
                    userChatID: chatKey.chatID,
                    asset: asset,
                    purpose: .credit(cents: cents)
                )
                try await editOrAnswer(callback: callback, message: message, screen: renderInvoice(invoice))
            } catch {
                logger.error("crypto credit invoice creation failed: \(error)")
                try? await telegram.answerCallback(
                    callbackQueryID: callback.id,
                    text: UserFacingError.shortMessage(error, context: "Не удалось создать счёт")
                )
            }

        case "asset":
            guard let asset = route.arg(2).flatMap(CryptoAsset.init(rawValue:)) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Неизвестная монета")
                return
            }
            guard let service = cryptoService else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: Texts.cryptoUnavailable)
                return
            }
            let cryptoKey = state.userKey(userID: callback.from.id)
            let cryptoSub = await state.tenantSubscription(ownerUsername: cryptoKey)
            if cryptoSub.exists, cryptoSub.paidUntil == nil {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "У вас бессрочный доступ")
                return
            }
            do {
                let invoice = try await service.createOrRefreshInvoice(
                    username: cryptoKey,
                    userChatID: chatKey.chatID,
                    asset: asset
                )
                try await editOrAnswer(callback: callback, message: message, screen: renderInvoice(invoice))
            } catch {
                logger.error("crypto invoice creation failed: \(error)")
                try? await telegram.answerCallback(
                    callbackQueryID: callback.id,
                    text: UserFacingError.shortMessage(error, context: "Не удалось создать счёт")
                )
            }

        default:
            break
        }
    }

    /// An open invoice belongs to one person: refresh and cancel check that.
    private func handleInvoiceControl(
        route: MenuRoute,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        switch route.sub {
        case "refresh":
            guard let invoiceID = route.arg(2) else { return }
            guard let invoice = await state.cryptoInvoice(id: invoiceID) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Счёт не найден")
                return
            }
            // An invoice names an address and an exact amount — a hand-made
            // callback should not be able to read someone else's.
            guard invoice.username == invokerKey(callback) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: Texts.notYourInvoice)
                return
            }
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: nil)
            try await editOrAnswer(callback: callback, message: message, screen: renderInvoice(invoice))

        case "cancel":
            guard let invoiceID = route.arg(2) else { return }
            guard let invoice = await state.cryptoInvoice(id: invoiceID) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Счёт не найден")
                return
            }
            // Invoices are filed under a UserKey (`#12345`), so comparing a raw
            // handle was true for everyone — nobody could cancel their own.
            guard invoice.username == invokerKey(callback) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: Texts.notYourInvoice)
                return
            }
            await cryptoService?.cancelInvoice(id: invoiceID)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Счёт отменён")
            try await telegram.editMessage(.init(
                chatID: message.chat.id,
                messageID: message.message_id,
                text: "❌ Счёт отменён.",
                replyMarkup: InlineKeyboardMarkup(inline_keyboard: [])
            ))

        default:
            break
        }
    }

    private func renderInvoice(_ invoice: CryptoInvoice) -> MenuScreen {
        let amount = CryptoAmountFormatter.format(atomic: invoice.exactAmountAtomic, decimals: invoice.asset.decimals)
        let received = CryptoAmountFormatter.format(atomic: invoice.accumulatedAtomic, decimals: invoice.asset.decimals)
        let remaining = CryptoAmountFormatter.format(atomic: invoice.remainingAtomic, decimals: invoice.asset.decimals)
        let expiresMin = max(0, Int(invoice.expiresAt.timeIntervalSinceNow / 60))

        var statusLine = ""
        switch invoice.status {
        case .open:
            statusLine = "⏳ Ожидаю оплату"
        case .partial:
            statusLine = "⚠️ Частично оплачено"
        case .paid:
            statusLine = "✅ Оплачено"
        case .expired:
            statusLine = "⌛ Истёк"
        case .cancelled:
            statusLine = "❌ Отменён"
        }

        let purposeLine: String
        switch invoice.resolvedPurpose {
        case .subscription:
            purposeLine = "Назначение: <b>Премиум-доступ · \(ChatContextStore.subscriptionDays) дн.</b>"
        case .credit(let cents):
            purposeLine = "Назначение: <b>Пополнение баланса \(CreditPack.label(cents: cents))</b>"
        }
        var lines: [String] = [
            "<b>🪙 Счёт на оплату</b>",
            "",
            purposeLine,
            "Сеть: <b>\(invoice.asset.displayLabel)</b>",
            "К оплате: <b>\(amount) \(invoice.asset.symbol)</b>",
        ]
        if invoice.accumulatedAtomic > 0 {
            lines.append("Получено: <b>\(received) \(invoice.asset.symbol)</b>")
            lines.append("Осталось: <b>\(remaining) \(invoice.asset.symbol)</b>")
        }
        lines.append("")
        lines.append("Адрес:")
        lines.append("<code>\(invoice.receivingAddress)</code>")
        lines.append("")
        lines.append("⚠️ <b>Отправьте РОВНО эту сумму.</b> Она уникальна — именно по ней бот узнаёт ваш платёж. Если сумма другая, зачислять придётся вручную.")
        lines.append("")
        lines.append("Срок: <b>\(expiresMin) мин</b>")
        lines.append(statusLine)

        var rows: Keyboard = []
        if invoice.status == .open || invoice.status == .partial {
            rows.row([menuButton("🔄 Обновить статус", .buy, "refresh", "\(invoice.id)")])
            rows.row([menuButton("❌ Отменить счёт", .buy, "cancel", "\(invoice.id)")])
        }
        rows.row([menuButton(Texts.close, command: .close)])

        return MenuScreen(lines.joined(separator: "\n"), rows)
    }
}
