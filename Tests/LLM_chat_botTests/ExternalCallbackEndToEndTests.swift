import XCTest
@testable import LLM_chat_bot

// The money path of the hosted checkout, end to end: a signed notification from
// the vendor walks in through `ExternalPaymentService`, and the test reads what
// the payer would see plus what the store actually granted.
//
// Only the Bot API is faked (the same local stand-in the other end-to-end tests
// use); the adapter, the signature check, the order bookkeeping and the shared
// fulfilment routine are the real ones.

final class ExternalCallbackEndToEndTests: XCTestCase {
    private var telegram: FakeTelegram!
    private var store: ChatContextStore!
    private var service: ExternalPaymentService!
    private var gateway: TelegramHTTPGateway!
    private var durability: LockedValue<StateDurability>!

    private let payerID: UserID = 5_555
    private let merchantID = "7012"
    private let secretWord = "linksecret"
    private let callbackSecret = "callbacksecret"

    override func setUp() async throws {
        telegram = FakeTelegram()
        let baseURL = try await telegram.start()
        gateway = TelegramHTTPGateway(
            network: NetworkClient(),
            botToken: "test-token",
            apiBase: baseURL,
            rateLimiter: nil,
            metrics: nil
        )
        store = Fixtures.makeStore()
        await store.setExternalPaymentConfig(ExternalPaymentConfig(
            vendor: .freekassa,
            enabled: true,
            merchantID: merchantID,
            secretWord: SealedSecret(secretWord),
            callbackSecret: SealedSecret(callbackSecret),
            currency: .rub,
            priceMinorUnits: 49_900,
            usdRateMinorUnits: 9_500,
            methods: [ExternalPaymentMethod(code: "44", title: "СБП")]
        ))
        durability = LockedValue(.durable)
        let fulfillment = PaymentFulfillmentService(
            state: store,
            telegram: gateway,
            ledger: InMemoryLedger(),
            persistence: nil,
            metrics: RuntimeMetrics(),
            logger: SilentLogger(),
            durability: durability
        )
        service = ExternalPaymentService(
            state: store,
            resolver: ExternalCheckoutRegistry(),
            fulfillment: fulfillment,
            telegram: gateway,
            logger: SilentLogger(),
            metrics: RuntimeMetrics(),
            publicBaseURL: "https://bot.example.com",
            durability: durability
        )
    }

    override func tearDown() async throws {
        await telegram.stop()
        telegram = nil
        store = nil
        service = nil
        gateway = nil
        durability = nil
    }

    private func notification(orderID: String, amount: String, paymentID: String) -> [String: String] {
        [
            "MERCHANT_ID": merchantID,
            "AMOUNT": amount,
            "MERCHANT_ORDER_ID": orderID,
            "intid": paymentID,
            "SIGN": PaymentSignature.md5Hex("\(merchantID):\(amount):\(callbackSecret):\(orderID)"),
        ]
    }

    func testPaidNotificationOpensPremiumAndTellsThePayer() async throws {
        let checkout = try await service.createCheckout(
            payerKey: store.userKey(userID: payerID),
            payerUserID: payerID,
            chatID: payerID.privateChat,
            threadID: nil,
            purpose: .subscription,
            methodCode: "44"
        )
        XCTAssertTrue(checkout.url.contains("i=44"), checkout.url)
        XCTAssertEqual(checkout.order.amountMinorUnits, 49_900)

        let verdict = await service.handleCallback(
            vendor: .freekassa,
            parameters: notification(orderID: checkout.order.id, amount: "499.00", paymentID: "111")
        )
        guard case .acknowledged(let ack) = verdict else {
            return XCTFail("a valid notification must be acknowledged, got \(verdict)")
        }
        // FreeKassa retries until it reads exactly this.
        XCTAssertEqual(ack, "YES")

        let subscription = await store.tenantSubscription(ownerKey: store.userKey(userID: payerID))
        XCTAssertTrue(subscription.isActive, "the payment must open premium")
        let call = await telegram.waitForCall("sendMessage", containing: "Оплата получена")
        XCTAssertNotNil(call, "the payer has to be told, in the chat they paid from")
        let report = await store.funnelReport()
        XCTAssertEqual(report.counters[FunnelEvent.paid.rawValue], 1)
    }

    /// The vendor redelivers until it hears YES, and a lost YES must not buy a
    /// second month.
    func testRepeatedNotificationDoesNotPayTwice() async throws {
        let checkout = try await service.createCheckout(
            payerKey: store.userKey(userID: payerID),
            payerUserID: payerID,
            chatID: payerID.privateChat,
            threadID: nil,
            purpose: .subscription,
            methodCode: nil
        )
        let params = notification(orderID: checkout.order.id, amount: "499.00", paymentID: "222")
        _ = await service.handleCallback(vendor: .freekassa, parameters: params)
        let first = await store.tenantSubscription(ownerKey: store.userKey(userID: payerID)).paidUntil

        _ = await service.handleCallback(vendor: .freekassa, parameters: params)
        let second = await store.tenantSubscription(ownerKey: store.userKey(userID: payerID)).paidUntil

        XCTAssertEqual(first, second, "a redelivered notification must not extend the subscription")
        let report = await store.funnelReport()
        XCTAssertEqual(report.counters[FunnelEvent.paid.rawValue], 1)
    }

    /// The database dies between opening the checkout and the vendor's
    /// notification. The vendor's retry loop is the only second chance this
    /// rail has, so it must not be ended by a process that cannot keep what it
    /// writes — and the worst case is silent: with no state restored the
    /// notification looks like one for an *unknown* order, which is
    /// acknowledged by design. The payment would be gone with nothing anywhere
    /// saying it happened.
    func testANotificationArrivingWhileStateIsNotDurableIsNotAcknowledged() async throws {
        let checkout = try await service.createCheckout(
            payerKey: store.userKey(userID: payerID),
            payerUserID: payerID,
            chatID: payerID.privateChat,
            threadID: nil,
            purpose: .subscription,
            methodCode: nil
        )
        let params = notification(orderID: checkout.order.id, amount: "499.00", paymentID: "555")

        durability.value = .volatile(reason: "restore failed")
        let verdict = await service.handleCallback(vendor: .freekassa, parameters: params)
        guard case .rejected = verdict else {
            return XCTFail("a notification we cannot durably apply must stay unacknowledged, got \(verdict)")
        }
        let granted = await store.tenantSubscription(ownerKey: store.userKey(userID: payerID))
        XCTAssertFalse(granted.exists, "nothing may be granted from a state that dies with the process")

        // Storage is back. The order was never closed, so the retry the vendor
        // was still making applies the payment — exactly once.
        durability.value = .durable
        let retry = await service.handleCallback(vendor: .freekassa, parameters: params)
        guard case .acknowledged = retry else {
            return XCTFail("the retry must be applied once storage is back, got \(retry)")
        }
        let subscription = await store.tenantSubscription(ownerKey: store.userKey(userID: payerID))
        XCTAssertTrue(subscription.isActive, "the retry has to buy what the first delivery could not")
        let report = await store.funnelReport()
        XCTAssertEqual(report.counters[FunnelEvent.paid.rawValue], 1, "one payment, one activation")
    }

    /// Same rule one level down, for every rail at once: `fulfil` is the single
    /// place all of them meet, and `.failed` is what each of them already knows
    /// to leave its door open on.
    func testFulfilmentRefusesToApplyAPaymentWhileStateIsNotDurable() async throws {
        let ledger = InMemoryLedger()
        let fulfillment = PaymentFulfillmentService(
            state: store,
            telegram: gateway,
            ledger: ledger,
            persistence: nil,
            metrics: RuntimeMetrics(),
            logger: SilentLogger(),
            durability: durability
        )
        let receipt = PaymentReceipt(
            payerKey: store.userKey(userID: payerID),
            payerUserID: payerID,
            chatID: payerID.privateChat,
            purpose: .credit(cents: 500),
            idempotencyKey: "charge-volatile",
            method: .stars
        )

        durability.value = .volatile(reason: "no DATABASE_URL")
        guard case .failed = await fulfillment.fulfil(receipt) else {
            return XCTFail("a payment must not be applied while state is not durable")
        }
        let empty = await store.balance(store.userKey(userID: payerID))
        XCTAssertNil(empty, "nothing may be credited")

        // The idempotency key must still be free, or the redelivery that is
        // supposed to save the payment would be dismissed as a duplicate.
        durability.value = .durable
        guard case .credit(let cents, let wallet) = await fulfillment.fulfil(receipt) else {
            return XCTFail("the redelivery must apply the payment")
        }
        XCTAssertEqual(cents, 500)
        XCTAssertEqual(wallet.balance, .usd(5))
    }

    func testTopUpNotificationCreditsTheWalletAtFaceValue() async throws {
        let checkout = try await service.createCheckout(
            payerKey: store.userKey(userID: payerID),
            payerUserID: payerID,
            chatID: payerID.privateChat,
            threadID: nil,
            purpose: .credit(cents: 500),
            methodCode: nil
        )
        // $5 at 95 ₽/$ — the rate the super-admin set, not a market guess.
        XCTAssertEqual(checkout.order.amountMinorUnits, 47_500)

        _ = await service.handleCallback(
            vendor: .freekassa,
            parameters: notification(orderID: checkout.order.id, amount: "475.00", paymentID: "333")
        )
        let wallet = await store.balance(store.userKey(userID: payerID))
        XCTAssertEqual(wallet?.balance, .usd(5))
        // Paid with real money: this is what makes a lapsed wallet worth an
        // offer later (§7 «Возврат по балансу»).
        XCTAssertEqual(wallet?.toppedUp, .usd(5))
    }

    /// An unsigned POST is the whole threat model of a public endpoint.
    func testForgedNotificationGrantsNothing() async throws {
        let checkout = try await service.createCheckout(
            payerKey: store.userKey(userID: payerID),
            payerUserID: payerID,
            chatID: payerID.privateChat,
            threadID: nil,
            purpose: .subscription,
            methodCode: nil
        )
        var forged = notification(orderID: checkout.order.id, amount: "499.00", paymentID: "444")
        forged["SIGN"] = String(repeating: "f", count: 32)

        let verdict = await service.handleCallback(vendor: .freekassa, parameters: forged)
        guard case .rejected = verdict else {
            return XCTFail("an unsigned notification must be rejected, got \(verdict)")
        }
        let subscription = await store.tenantSubscription(ownerKey: store.userKey(userID: payerID))
        XCTAssertFalse(subscription.isActive)
    }

    /// Underpayment means the shop is misconfigured or the order was tampered
    /// with: nothing is granted, and the payer is not left waiting in silence.
    func testUnderpaidNotificationGrantsNothingAndSaysSo() async throws {
        let checkout = try await service.createCheckout(
            payerKey: store.userKey(userID: payerID),
            payerUserID: payerID,
            chatID: payerID.privateChat,
            threadID: nil,
            purpose: .subscription,
            methodCode: nil
        )
        _ = await service.handleCallback(
            vendor: .freekassa,
            parameters: notification(orderID: checkout.order.id, amount: "1.00", paymentID: "555")
        )
        let subscription = await store.tenantSubscription(ownerKey: store.userKey(userID: payerID))
        XCTAssertFalse(subscription.isActive)
        let call = await telegram.waitForCall("sendMessage", containing: "не совпала")
        XCTAssertNotNil(call)
    }

    /// The database refusing the write is the one case where the vendor must
    /// *not* hear YES: only an unacknowledged notification is retried, and only
    /// an order that is open again can be settled by that retry. Closing the
    /// order and answering YES anyway — which is what this used to do — ended
    /// the retry loop on a payment that had bought nothing.
    func testAPaymentTheDatabaseRefusesIsRetriedRatherThanLost() async throws {
        let checkout = try await service.createCheckout(
            payerKey: store.userKey(userID: payerID),
            payerUserID: payerID,
            chatID: payerID.privateChat,
            threadID: nil,
            purpose: .subscription,
            methodCode: nil
        )
        let params = notification(orderID: checkout.order.id, amount: "499.00", paymentID: "666")

        // Same store, same order — only the ledger is unavailable.
        let refusing = ExternalPaymentService(
            state: store,
            resolver: ExternalCheckoutRegistry(),
            fulfillment: PaymentFulfillmentService(
                state: store,
                telegram: gateway,
                ledger: RefusingLedger(),
                persistence: nil,
                metrics: RuntimeMetrics(),
                logger: SilentLogger()
            ),
            telegram: gateway,
            logger: SilentLogger(),
            metrics: RuntimeMetrics(),
            publicBaseURL: "https://bot.example.com"
        )

        let verdict = await refusing.handleCallback(vendor: .freekassa, parameters: params)
        guard case .rejected = verdict else {
            return XCTFail("an unapplied payment must not be acknowledged, got \(verdict)")
        }
        let stalled = await store.tenantSubscription(ownerKey: store.userKey(userID: payerID))
        XCTAssertFalse(stalled.isActive, "nothing was committed, so nothing may be granted")
        let reopened = await store.externalOrder(id: checkout.order.id)
        XCTAssertEqual(reopened?.status, .pending, "the order has to be open for the retry to settle it")

        // The vendor delivers again once the database is back.
        let retry = await service.handleCallback(vendor: .freekassa, parameters: params)
        guard case .acknowledged = retry else {
            return XCTFail("the retry must land, got \(retry)")
        }
        let granted = await store.tenantSubscription(ownerKey: store.userKey(userID: payerID))
        XCTAssertTrue(granted.isActive, "the redelivered payment must open premium")
        let report = await store.funnelReport()
        XCTAssertEqual(report.counters[FunnelEvent.paid.rawValue], 1, "the payment must count once, not twice")
    }

    func testNotificationURLIsTheOneTheCabinetNeeds() async {
        let url = await service.callbackURL(for: .freekassa)
        XCTAssertEqual(url, "https://bot.example.com/payments/freekassa")
    }
}
