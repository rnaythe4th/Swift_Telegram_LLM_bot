import Foundation

// Super-admin page for the hosted checkout (§7 «Внешняя касса») and the buy
// flow behind it: credentials, prices, the rails offered, and the signed link
// a payer opens.
//
// Nothing here is hardcoded per deployment: the merchant id, both secret words,
// the currency, both prices and the list of rails are typed into the bot, land
// in `bot_config`, and take effect on the next tap — the same rule the Stars,
// card and crypto pages follow.

extension BotMenuHandler {
    /// How a stored signing word appears on the page. Three states, not two:
    /// a word that is in the row but sealed under a key this process does not
    /// have is neither "set" nor "missing", and telling the owner "не задано"
    /// would send them to the vendor's cabinet for a value that never left.
    static func secretLine(_ secret: SealedSecret?) -> String {
        guard let secret else { return "<i>не задано</i>" }
        if secret.isUnreadable { return Texts.secretUnreadable }
        return ExternalPaymentConfig.mask(secret.value).map { "<code>\($0)</code>" } ?? "<i>не задано</i>"
    }

    // MARK: - Super-admin actions

    func handleExternalPayAdminAction(
        route: MenuRoute,
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard await requireSuperAdmin(callback) else { return }
        let config = await state.externalPaymentConfig()
        switch route.sub {
        case "toggle":
            // Refuse to switch on a merchant that cannot sign anything: an
            // enabled-but-unconfigured checkout shows a button that dead-ends
            // on the vendor's error page.
            if !config.enabled, config.credentials == nil {
                try? await telegram.answerCallback(
                    callbackQueryID: callback.id,
                    text: "Сначала заполните реквизиты магазина"
                )
                return
            }
            await state.updateExternalPaymentConfig { $0.enabled.toggle() }
            let now = await state.externalPaymentConfig().enabled
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: now ? "✓ Включено" : "✓ Выключено")
            try await showPage(.superExternalPay, chatKey: chatKey, callback: callback, message: message)

        case "merchant":
            try await promptExternal(
                kind: .externalMerchantID,
                title: "🏬 \(config.vendor.merchantIDLabel)",
                current: config.escapedMerchantID.map { "<code>\($0)</code>" } ?? "<i>не задан</i>",
                hint: "Отправьте \(config.vendor.merchantIDLabel.lowercased()) одним сообщением — он указан в кабинете \(config.vendor.displayName) на странице кассы.",
                chatKey: chatKey,
                callback: callback,
                message: message
            )

        case "secret":
            try await promptExternal(
                kind: .externalSecret,
                title: "🔑 \(config.vendor.secretLabel)",
                current: Self.secretLine(config.secretWord),
                hint: "Подписывает ссылку на оплату. Скопируйте из кабинета \(config.vendor.displayName) → настройки кассы.",
                chatKey: chatKey,
                callback: callback,
                message: message
            )

        case "secret2":
            try await promptExternal(
                kind: .externalCallbackSecret,
                title: "🔐 \(config.vendor.callbackSecretLabel)",
                current: Self.secretLine(config.callbackSecret),
                hint: "Проверяет уведомления об оплате. Именно оно решает, включать ли доступ, — поэтому оно другое, чем первое.",
                chatKey: chatKey,
                callback: callback,
                message: message
            )

        case "price":
            try await promptExternal(
                kind: .externalPrice,
                title: "💳 Цена подписки",
                current: config.priceLabel.map { "<b>\($0)</b>" } ?? "<i>не задана</i>",
                hint: "Введите сумму в \(config.currency.rawValue) (например <code>499</code>), или <b>0</b> — не продавать здесь подписку.",
                chatKey: chatKey,
                callback: callback,
                message: message
            )

        case "rate":
            var preview = ""
            for cents in CreditPack.centsOptions {
                if let minor = config.creditMinorUnits(cents: cents) {
                    preview += "\n\(CreditPack.label(cents: cents)) → <b>\(config.currency.format(minorUnits: minor))</b>"
                }
            }
            try await promptExternal(
                kind: .externalUsdRate,
                title: "💱 Курс пополнений",
                current: (config.usdRateLabel.map { "<b>\($0)</b>" } ?? "<i>не задан</i>") + preview,
                hint: "Сколько \(config.currency.rawValue) стоит <b>$1</b> на балансе (например <code>95</code>), или <b>0</b> — не продавать пополнения. Курс должен покрывать комиссию кассы.",
                chatKey: chatKey,
                callback: callback,
                message: message
            )

        case "currency":
            guard let currency = route.arg(2).flatMap(FiatCurrency.init(rawValue:)) else { return }
            await state.updateExternalPaymentConfig { $0.currency = currency }
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Валюта: \(currency.rawValue)")
            try await showPage(.superExternalPay, chatKey: chatKey, callback: callback, message: message)

        case "addmethod":
            let listing = config.methods.isEmpty
                ? "<i>пусто — на странице кассы покупатель выберет сам</i>"
                : config.methods.map { "• <code>\($0.escapedCode)</code> — \($0.escapedTitle)" }.joined(separator: "\n")
            try await promptExternal(
                kind: .externalMethodAdd,
                title: "➕ Способ оплаты",
                current: listing,
                hint: """
                Отправьте <code>код | название</code> — например <code>44 | СБП</code>.
                Код — это ID платёжной системы в кабинете \(config.vendor.displayName) (параметр <code>i</code>).
                """,
                chatKey: chatKey,
                callback: callback,
                message: message
            )

        case "togglemethod":
            guard let index = route.int(2) else { return }
            let ok = await state.toggleExternalPaymentMethod(at: index)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: ok ? "✓" : Texts.notFound)
            try await showPage(.superExternalPay, chatKey: chatKey, callback: callback, message: message)

        case "delmethod":
            guard let index = route.int(2) else { return }
            let ok = await state.removeExternalPaymentMethod(at: index)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: ok ? "✓ Удалено" : Texts.notFound)
            try await showPage(.superExternalPay, chatKey: chatKey, callback: callback, message: message)

        case "defaults":
            await state.updateExternalPaymentConfig { $0.methods = $0.vendor.defaultMethods }
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Стандартный набор")
            try await showPage(.superExternalPay, chatKey: chatKey, callback: callback, message: message)

        default:
            try await showPage(.superExternalPay, chatKey: chatKey, callback: callback, message: message)
        }
    }

    private func promptExternal(
        kind: AdminPendingInputKind,
        title: String,
        current: String,
        hint: String,
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        await state.setPending(.admin(.init(kind: kind)), menuMessageID: message.message_id, chatKey: chatKey)
        let text = """
        <b>\(title)</b>

        Сейчас: \(current)

        \(hint)
        """
        try await editOrAnswer(
            callback: callback,
            message: message,
            screen: MenuScreen(text, [[cancelButton(to: .superExternalPay)]])
        )
    }

    // MARK: - Super-admin page

    func renderSuperExternalPay(chatKey: ChatKey) async -> MenuScreen {
        let config = await state.externalPaymentConfig()
        let vendor = config.vendor
        let callbackURL = await externalPayments?.callbackURL(for: vendor)

        var rows: Keyboard = [
            [menuButton(config.enabled ? "🟢 Касса включена" : "⚪️ Касса выключена", .extpay, "toggle")],
            [
                menuButton(config.merchantID == nil ? "🏬 ID магазина" : "🏬 ID магазина ✓", .extpay, "merchant"),
                menuButton(config.secretWord == nil ? "🔑 Слово 1" : "🔑 Слово 1 ✓", .extpay, "secret"),
                menuButton(config.callbackSecret == nil ? "🔐 Слово 2" : "🔐 Слово 2 ✓", .extpay, "secret2"),
            ],
            [
                menuButton("✏️ Цена подписки", .extpay, "price"),
                menuButton("💱 Курс пополнений", .extpay, "rate"),
            ],
        ]
        var currencyRow: [InlineKeyboardButton] = []
        for currency in FiatCurrency.allCases {
            let mark = currency == config.currency ? "✅ " : ""
            currencyRow.append(menuButton("\(mark)\(currency.rawValue)", .extpay, "currency", currency.rawValue))
        }
        rows.row(currencyRow)
        rows.row([
            menuButton("➕ Способ оплаты", .extpay, "addmethod"),
            menuButton("↺ Стандартные", .extpay, "defaults"),
        ])
        for (index, method) in config.methods.enumerated() {
            rows.row([
                menuButton("\(toggleMark(method.enabled)) \(method.title)", .extpay, "togglemethod", "\(index)"),
                menuButton("🗑", .extpay, "delmethod", "\(index)"),
            ])
        }
        rows.row([backButton(to: .superAdmin)])

        let statusLine: String
        if config.credentials == nil {
            statusLine = "🔴 <b>Не настроена</b> — заполните реквизиты магазина."
        } else if !config.enabled {
            statusLine = "🔴 <b>Выключена</b> — реквизиты сохранены, продажа не идёт."
        } else if config.isEnabled || config.creditsEnabled {
            statusLine = "🟢 <b>Работает</b>"
        } else {
            statusLine = "🟡 <b>Включена, но нечего продавать</b> — задайте цену подписки или курс пополнений."
        }

        let methodsLine = config.methods.isEmpty
            ? "<i>не заданы — покупатель выберет способ на странице кассы</i>"
            : config.methods
                .map { "\(toggleMark($0.enabled)) \($0.escapedTitle) · <code>\($0.escapedCode)</code>" }
                .joined(separator: "\n")

        // Without this URL nothing arrives back and every payment hangs — so it
        // is printed in full, ready to copy, and its absence is called out.
        let callbackLine = callbackURL.map { "<code>\($0)</code>" }
            ?? "<i>нет публичного адреса (локальный режим) — касса работать не будет</i>"

        let packsLine: String
        if config.creditsEnabled {
            let packs = CreditPack.centsOptions.compactMap { cents -> String? in
                guard let minor = config.creditMinorUnits(cents: cents) else { return nil }
                return "\(CreditPack.label(cents: cents)) → \(config.currency.format(minorUnits: minor))"
            }
            packsLine = "🟢 Пополнение баланса · \(config.usdRateLabel ?? "")\n<i>\(packs.joined(separator: " · "))</i>"
        } else {
            packsLine = "🔴 Пополнение баланса выключено — задайте курс"
        }

        let text = """
        <b>🏦 Внешняя касса · \(vendor.displayName)</b>

        \(statusLine)
        Подписка: \(config.priceLabel.map { "<b>\($0)</b>" } ?? "<i>не продаётся</i>")
        \(packsLine)

        <b>Реквизиты</b>
        \(vendor.merchantIDLabel): \(config.escapedMerchantID.map { "<code>\($0)</code>" } ?? "<i>не задан</i>")
        \(vendor.secretLabel): \(Self.secretLine(config.secretWord))
        \(vendor.callbackSecretLabel): \(Self.secretLine(config.callbackSecret))

        <b>URL оповещения</b> <i>(вставить в кабинет кассы)</i>
        \(callbackLine)

        <b>Способы оплаты</b>
        \(methodsLine)

        <i>Регистрация: \(vendor.signupURL) · инструкция — PAYMENTS_SETUP.md</i>
        """
        return MenuScreen(text, rows)
    }

    // MARK: - Buy flow

    /// `buy:ext…` — subscription and credit packs through the hosted checkout.
    func handleExternalPurchase(
        route: MenuRoute,
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard let service = externalPayments else {
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: Texts.externalUnavailable)
            return
        }
        let config = await state.externalPaymentConfig()
        let payerKey = invokerKey(callback)

        let purpose: PurchasePurpose
        let methodIndexArgument: Int?
        switch route.sub {
        case "ext":
            purpose = .subscription
            methodIndexArgument = route.int(2)
        case "cext":
            guard let cents = route.int(2), CreditPack.isValid(cents: cents) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: Texts.unknownPack)
                return
            }
            purpose = .credit(cents: cents)
            methodIndexArgument = route.int(3)
        default:
            return
        }

        // Unlimited tenants have nothing to buy — same guard as the other methods.
        if case .subscription = purpose {
            let subscription = await state.tenantSubscription(ownerKey: payerKey)
            if subscription.exists, subscription.paidUntil == nil {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "У вас бессрочный доступ")
                return
            }
        }

        let methods = config.activeMethods
        // Several rails configured and none chosen yet → let the payer pick
        // here, so "СБП" is one tap rather than a hunt on the vendor's page.
        if methodIndexArgument == nil, methods.count > 1 {
            try await editOrAnswer(
                callback: callback,
                message: message,
                screen: methodChoiceScreen(purpose: purpose, methods: methods, config: config)
            )
            return
        }
        let methodCode: String? = {
            if let index = methodIndexArgument, index >= 0, index < methods.count { return methods[index].code }
            return methods.count == 1 ? methods[0].code : nil
        }()

        do {
            let checkout = try await service.createCheckout(
                payerKey: payerKey,
                payerUserID: callback.from.id,
                chatID: chatKey.chatID,
                threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                purpose: purpose,
                methodCode: methodCode
            )
            await state.bumpFunnel(.invoiceSent)
            try await editOrAnswer(
                callback: callback,
                message: message,
                screen: checkoutScreen(checkout, methodTitle: methods.first { $0.code == methodCode }?.escapedTitle)
            )
        } catch {
            logger.error("external checkout failed: \(error)")
            try? await telegram.answerCallback(
                callbackQueryID: callback.id,
                text: UserFacingError.shortMessage(error, context: "Не удалось открыть оплату")
            )
        }
    }

    private func methodChoiceScreen(
        purpose: PurchasePurpose,
        methods: [ExternalPaymentMethod],
        config: ExternalPaymentConfig
    ) -> MenuScreen {
        var rows = Keyboard()
        for (index, method) in methods.enumerated() {
            switch purpose {
            case .subscription:
                rows.row([menuButton(method.title, .buy, "ext", "\(index)")])
            case .credit(let cents):
                rows.row([menuButton(method.title, .buy, "cext", "\(cents)", "\(index)")])
            }
        }
        rows.row(navButtons())
        let what: String
        switch purpose {
        case .subscription:
            what = "Премиум-доступ · \(ChatContextStore.subscriptionDays) дней"
        case .credit(let cents):
            what = "Пополнение баланса на \(CreditPack.label(cents: cents))"
        }
        let text = """
        <b>🏦 Оплата через \(config.vendor.displayName)</b>

        \(what)

        Выберите способ оплаты — откроется защищённая страница кассы. Доступ включится автоматически сразу после оплаты.
        """
        return MenuScreen(text, rows)
    }

    /// `methodTitle` arrives already escaped (`ExternalPaymentMethod
    /// .escapedTitle`): it is text a super-admin typed and this screen is the
    /// one message a paying customer must receive.
    private func checkoutScreen(_ checkout: ExternalCheckout, methodTitle: String?) -> MenuScreen {
        let order = checkout.order
        let what: String
        switch order.purpose {
        case .subscription:
            what = "Премиум-доступ · \(ChatContextStore.subscriptionDays) дней"
        case .credit(let cents):
            what = "Пополнение баланса на \(CreditPack.label(cents: cents))"
        }
        let minutes = max(1, Int(order.expiresAt.timeIntervalSinceNow / 60))
        var rows: Keyboard = [
            [InlineKeyboardButton(text: "🔗 Оплатить \(order.amountLabel)", url: checkout.url)],
        ]
        rows.row([menuButton("❌ Отменить счёт", .buy, "extcancel", order.id)])
        rows.row([menuButton(Texts.close, command: .close)])
        let methodLine = methodTitle.map { "Способ: <b>\($0)</b>\n" } ?? ""
        let text = """
        <b>🏦 Счёт на оплату</b>

        Назначение: <b>\(what)</b>
        \(methodLine)К оплате: <b>\(order.amountLabel)</b>
        Счёт действует: <b>\(minutes) мин</b>

        Нажмите кнопку ниже — откроется страница оплаты. Доступ включится автоматически, сообщение об этом придёт сюда же.
        """
        return MenuScreen(text, rows)
    }

    /// `buy:extcancel:<id>` — an order names an amount and belongs to one
    /// person, so a hand-made callback must not close someone else's.
    func handleExternalCancel(
        route: MenuRoute,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard let service = externalPayments, let orderID = route.arg(2) else { return }
        let cancelled = await service.cancelCheckout(orderID: orderID, payerKey: invokerKey(callback))
        guard cancelled else {
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: Texts.notYourInvoice)
            return
        }
        try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Счёт отменён")
        try await telegram.editMessage(.init(
            chatID: message.chat.id,
            messageID: message.message_id,
            text: "❌ Счёт отменён.",
            replyMarkup: InlineKeyboardMarkup(inline_keyboard: [])
        ))
    }
}
