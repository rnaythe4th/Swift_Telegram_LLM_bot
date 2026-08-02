import Foundation

// The hosted-checkout flow, end to end: open an order, hand the payer a signed
// link, settle the notification the vendor sends back.
//
// Everything vendor-specific is behind `ExternalCheckoutResolver`, and
// everything money-specific is behind `PaymentFulfillmentService`. What is left
// here is the part that is the same for every aggregator: which price applies,
// which order a callback belongs to, and what the payer is told.

/// A checkout the payer can open right now.
struct ExternalCheckout: Sendable {
    let order: ExternalPaymentOrder
    let url: String
}

/// What the HTTP layer should answer. The vendor's retry loop stops on the
/// acknowledgement and only on that, so "rejected" is reserved for requests
/// that never authenticated — anything we accepted but could not use is
/// acknowledged and logged, or the aggregator hammers the endpoint forever.
enum ExternalCallbackVerdict: Sendable {
    case acknowledged(String)
    case rejected(reason: String)
}

actor ExternalPaymentService {
    private let state: ChatContextStore
    private let resolver: any ExternalCheckoutResolver
    private let fulfillment: PaymentFulfillmentService
    private let telegram: TelegramGatewayPort
    private let logger: LoggerPort
    private let metrics: RuntimeMetrics
    /// Public origin of this deployment, for the notification URL the merchant
    /// cabinet needs. nil in local polling mode — the settings page then says
    /// so instead of printing a URL that resolves to nothing.
    private let publicBaseURL: String?
    /// Whether anything written now survives the process (§4.3). The vendor's
    /// retry loop is the only second chance this rail has, so a notification
    /// arriving while state is not durable must go unacknowledged.
    private let durability: LockedValue<StateDurability>

    init(
        state: ChatContextStore,
        resolver: any ExternalCheckoutResolver,
        fulfillment: PaymentFulfillmentService,
        telegram: TelegramGatewayPort,
        logger: LoggerPort,
        metrics: RuntimeMetrics,
        publicBaseURL: String?,
        durability: LockedValue<StateDurability> = LockedValue(.durable)
    ) {
        self.state = state
        self.resolver = resolver
        self.fulfillment = fulfillment
        self.telegram = telegram
        self.logger = logger
        self.metrics = metrics
        self.publicBaseURL = publicBaseURL
        self.durability = durability
    }

    // MARK: - Configuration surface (for the menu)

    /// Notification URL to paste into the merchant cabinet, or nil when this
    /// deployment has no public address.
    func callbackURL(for vendor: ExternalPaymentVendor) -> String? {
        publicBaseURL.map { vendor.callbackURL(publicBaseURL: $0) }
    }

    // MARK: - Opening a checkout

    func createCheckout(
        payerKey: UserKey,
        payerUserID: UserID?,
        chatID: ChatID,
        threadID: Int64?,
        purpose: PurchasePurpose,
        methodCode: String?
    ) async throws -> ExternalCheckout {
        let config = await state.externalPaymentConfig()
        guard config.enabled, let credentials = config.credentials else {
            throw ExternalPaymentError.notConfigured
        }
        let amountMinorUnits = try await price(for: purpose, payerKey: payerKey, config: config)

        await state.expireDueExternalOrders()
        let normalizedMethod = methodCode?.isEmpty == true ? nil : methodCode
        // Tapping "оплатить" twice must not open a second order: the vendor's
        // page is already on the payer's screen, and two live orders for one
        // purchase mean two payments waiting to happen. The amount has to match
        // too — a winback discount that expired between taps is a new price.
        if let existing = await state.openExternalOrder(
            payerKey: payerKey,
            purpose: purpose,
            methodCode: normalizedMethod
        ), existing.amountMinorUnits == amountMinorUnits {
            let url = try resolver.adapter(for: existing.vendor)
                .checkoutURL(order: existing, credentials: credentials)
            return ExternalCheckout(order: existing, url: url)
        }

        let now = Date()
        let order = ExternalPaymentOrder(
            id: ExternalPaymentOrder.makeID(),
            vendor: config.vendor,
            payerKey: payerKey,
            payerUserID: payerUserID,
            chatID: chatID,
            threadID: threadID,
            purpose: purpose,
            currency: config.currency,
            amountMinorUnits: amountMinorUnits,
            methodCode: normalizedMethod,
            createdAt: now,
            expiresAt: now.addingTimeInterval(ExternalPaymentConfig.orderLifetime),
            status: .pending,
            paidAt: nil,
            vendorPaymentID: nil
        )
        let url = try resolver.adapter(for: config.vendor)
            .checkoutURL(order: order, credentials: credentials)
        // Stored only once the link exists: an order nobody could ever pay is
        // just a row that will expire.
        await state.upsertExternalOrder(order)
        logger.info("external checkout \(order.id) opened for \(order.payerKey): \(order.amountLabel) via \(config.vendor.rawValue)")
        return ExternalCheckout(order: order, url: url)
    }

    private func price(
        for purpose: PurchasePurpose,
        payerKey: UserKey,
        config: ExternalPaymentConfig
    ) async throws -> Int {
        switch purpose {
        case .subscription:
            // Single source of prices (§17): a live winback discount is already
            // baked in, so the link charges exactly what was quoted.
            guard let amount = await state.subscriptionPricing(key: payerKey).externalMinorUnits else {
                throw ExternalPaymentError.priceNotSet
            }
            return amount
        case .credit(let cents):
            guard config.creditsEnabled, let amount = config.creditMinorUnits(cents: cents) else {
                throw ExternalPaymentError.priceNotSet
            }
            return amount
        }
    }

    func cancelCheckout(orderID: String, payerKey: UserKey) async -> Bool {
        guard let order = await state.externalOrder(id: orderID), order.payerKey == payerKey else {
            return false
        }
        return await state.cancelExternalOrder(id: orderID)
    }

    // MARK: - Settling a notification

    func handleCallback(
        vendor: ExternalPaymentVendor,
        parameters: [String: String]
    ) async -> ExternalCallbackVerdict {
        // Before anything is looked up: a process that cannot keep what it
        // writes must not end the vendor's retry loop. Without this the worst
        // case is silent and total — the database is down, the restore left us
        // with no orders at all, so the notification looks like one for an
        // *unknown* order, which is acknowledged by design. The vendor stops
        // retrying and the purchase is gone with nothing anywhere that says it
        // happened.
        let durability = durability.value
        guard durability.acceptsPayments else {
            await metrics.increment(MetricName.paymentsRefusedVolatile)
            logger.error("external callback (\(vendor.rawValue)) left unacknowledged: state is \(durability.statusLine)")
            return .rejected(reason: "state is not durable")
        }

        let config = await state.externalPaymentConfig()
        // A callback for a vendor we are not configured for cannot be checked
        // at all — there is no secret to check it against.
        guard config.vendor == vendor, config.acceptsCallbacks, let credentials = config.credentials else {
            logger.warning("external callback for \(vendor.rawValue) while it is not configured")
            return .rejected(reason: "not configured")
        }
        let adapter = resolver.adapter(for: vendor)
        let callback: ExternalCheckoutCallback
        do {
            callback = try adapter.verifyCallback(parameters: parameters, credentials: credentials)
        } catch {
            // The endpoint is public; a bad signature is either a
            // misconfiguration or someone trying their luck. Both are worth a
            // log line and neither gets an acknowledgement.
            logger.warning("external callback rejected (\(vendor.rawValue)): \(error)")
            return .rejected(reason: "bad signature")
        }

        guard let order = await state.externalOrder(id: callback.orderID) else {
            // Signed by us, unknown to us: the order was pruned or the merchant
            // is shared with another installation. Acknowledge — a retry loop
            // will not make the order reappear — but say so loudly.
            logger.error("external callback for unknown order \(callback.orderID) (\(vendor.rawValue), payment \(callback.vendorPaymentID))")
            return .acknowledged(adapter.acknowledgement)
        }

        guard callback.amountMinorUnits >= order.amountMinorUnits else {
            // Underpaid: the aggregator does not do partials, so this means the
            // order was tampered with or the shop is misconfigured. Nothing is
            // credited, and the payer is told rather than left waiting.
            logger.error("external callback underpaid: order \(order.id) expected \(order.amountMinorUnits), got \(callback.amountMinorUnits)")
            await notifyAmountMismatch(order: order, receivedMinorUnits: callback.amountMinorUnits)
            return .acknowledged(adapter.acknowledgement)
        }

        guard let paidOrder = await state.markExternalOrderPaid(
            id: order.id,
            vendorPaymentID: callback.vendorPaymentID
        ) else {
            // Already settled — the vendor simply did not hear our first YES.
            await metrics.increment(MetricName.paymentsDeduplicated)
            return .acknowledged(adapter.acknowledgement)
        }

        let outcome = await fulfillment.fulfil(PaymentReceipt(
            payerKey: paidOrder.payerKey,
            payerUserID: paidOrder.payerUserID ?? paidOrder.payerKey.userID,
            chatID: paidOrder.chatID,
            purpose: paidOrder.purpose,
            idempotencyKey: "ext:\(vendor.rawValue):\(callback.vendorPaymentID)",
            method: .external
        ))
        if case .failed = outcome {
            // Nothing was committed, so the order goes back to `pending` and
            // the vendor is *not* acknowledged: only an unacknowledged
            // notification is retried, and only a reopened order lets the retry
            // get past the duplicate check above. Acknowledging here — which is
            // what this used to do — ended the retry loop on a purchase that
            // had bought nothing.
            await state.reopenExternalOrder(id: paidOrder.id)
            logger.error("external order \(paidOrder.id) could not be applied — reopened, awaiting the vendor's retry")
            return .rejected(reason: "not applied")
        }
        await announce(outcome: outcome, order: paidOrder, methodCode: callback.methodCode)
        return .acknowledged(adapter.acknowledgement)
    }

    // MARK: - Telling the payer

    private func announce(
        outcome: PaymentFulfillmentOutcome,
        order: ExternalPaymentOrder,
        methodCode: String?
    ) async {
        switch outcome {
        case .duplicate:
            return

        case .failed:
            // Handled by the caller, which reopens the order and withholds the
            // acknowledgement so the vendor delivers again.
            return

        case .subscription(let activation, let claim):
            let payerLabel = await state.displayLabel(forKey: order.payerKey)
            await send(chatID: order.chatID, threadID: order.threadID, text: Self.subscriptionText(
                order: order,
                payerLabel: payerLabel,
                activation: activation,
                claim: claim
            ))
            logger.info("external order \(order.id) paid: subscription for \(payerLabel) (\(order.amountLabel))")

        case .credit(let cents, let wallet):
            let text = """
            ✅ <b>Баланс пополнен на \(CreditPack.label(cents: cents))!</b>

            Оплачено: <b>\(order.amountLabel)</b>
            Текущий баланс: <b>\(wallet.balance.formatted(fractionDigits: 2))</b>

            Теперь вам доступны любые модели: с баланса списывается стоимость каждого ответа, обычно доли цента. Сколько списалось и сколько осталось — видно под самим ответом (включите показ: /show_cost).
            """
            await send(chatID: order.chatID, threadID: order.threadID, text: text)
            logger.info("external order \(order.id) paid: +\(cents)c to \(order.payerKey) (\(order.amountLabel))")
        }
    }

    private static func subscriptionText(
        order: ExternalPaymentOrder,
        payerLabel: String,
        activation: SubscriptionActivation,
        claim: ChatContextStore.ChatClaimOutcome
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy"
        let isGroup = order.chatID.isGroup
        if case .keptSponsor(let sponsor) = claim {
            return """
            ✅ <b>Оплата получена!</b>

            Принято: <b>\(order.amountLabel)</b>

            \(payerLabel), премиум-доступ активирован для вас — в личке с ботом и в ваших чатах.
            Здесь премиум уже открыл \(sponsor) — этот чат остаётся за ним.
            """
        }
        let line: String
        switch activation {
        case .started(let until):
            line = isGroup
                ? "🎉 \(payerLabel) открыл премиум-доступ для этого чата — теперь всем доступны умные модели без рекламы."
                : "Добро пожаловать, \(payerLabel)! Премиум-доступ активирован, подписка до <b>\(formatter.string(from: until))</b>."
        case .extended(let until):
            line = isGroup
                ? "🎉 \(payerLabel) продлил премиум-доступ для этого чата."
                : "Подписка продлена до <b>\(formatter.string(from: until))</b>."
        case .alreadyUnlimited:
            line = "У \(payerLabel) бессрочный доступ — ничего не изменилось."
        }
        return """
        ✅ <b>Оплата получена!</b>

        Принято: <b>\(order.amountLabel)</b>

        \(line)
        Используйте /menu для настройки или просто начните общение.
        """
    }

    private func notifyAmountMismatch(order: ExternalPaymentOrder, receivedMinorUnits: Int) async {
        let received = order.currency.format(minorUnits: receivedMinorUnits)
        await send(chatID: order.chatID, threadID: order.threadID, text: """
        ⚠️ <b>Сумма оплаты не совпала</b>

        Ожидалось: <b>\(order.amountLabel)</b>
        Получено: <b>\(received)</b>

        Доступ не включён автоматически. Напишите владельцу бота — платёж найдут по номеру счёта <code>\(order.id)</code>.
        """)
    }

    private func send(chatID: ChatID, threadID: Int64?, text: String) async {
        _ = try? await telegram.sendMessage(.init(
            chatID: chatID,
            threadID: (threadID ?? 0) == 0 ? nil : threadID,
            replyTo: nil,
            text: text,
            replyMarkup: nil
        ))
    }
}
