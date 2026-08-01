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

    private let payerID = 5_555
    private let merchantID = "7012"
    private let secretWord = "linksecret"
    private let callbackSecret = "callbacksecret"

    override func setUp() async throws {
        telegram = FakeTelegram()
        let baseURL = try await telegram.start()
        let gateway = TelegramHTTPGateway(
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
            secretWord: secretWord,
            callbackSecret: callbackSecret,
            currency: .rub,
            priceMinorUnits: 49_900,
            usdRateMinorUnits: 9_500,
            methods: [ExternalPaymentMethod(code: "44", title: "СБП")]
        ))
        let fulfillment = PaymentFulfillmentService(
            state: store,
            telegram: gateway,
            ledger: InMemoryLedger(),
            persistence: nil,
            metrics: RuntimeMetrics(),
            logger: SilentLogger()
        )
        service = ExternalPaymentService(
            state: store,
            resolver: ExternalCheckoutRegistry(),
            fulfillment: fulfillment,
            telegram: gateway,
            logger: SilentLogger(),
            metrics: RuntimeMetrics(),
            publicBaseURL: "https://bot.example.com"
        )
    }

    override func tearDown() async throws {
        await telegram.stop()
        telegram = nil
        store = nil
        service = nil
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
            chatID: payerID,
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

        let subscription = await store.tenantSubscription(ownerUsername: store.userKey(userID: payerID))
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
            chatID: payerID,
            threadID: nil,
            purpose: .subscription,
            methodCode: nil
        )
        let params = notification(orderID: checkout.order.id, amount: "499.00", paymentID: "222")
        _ = await service.handleCallback(vendor: .freekassa, parameters: params)
        let first = await store.tenantSubscription(ownerUsername: store.userKey(userID: payerID)).paidUntil

        _ = await service.handleCallback(vendor: .freekassa, parameters: params)
        let second = await store.tenantSubscription(ownerUsername: store.userKey(userID: payerID)).paidUntil

        XCTAssertEqual(first, second, "a redelivered notification must not extend the subscription")
        let report = await store.funnelReport()
        XCTAssertEqual(report.counters[FunnelEvent.paid.rawValue], 1)
    }

    func testTopUpNotificationCreditsTheWalletAtFaceValue() async throws {
        let checkout = try await service.createCheckout(
            payerKey: store.userKey(userID: payerID),
            payerUserID: payerID,
            chatID: payerID,
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
        let wallet = await store.balance(username: store.userKey(userID: payerID))
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
            chatID: payerID,
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
        let subscription = await store.tenantSubscription(ownerUsername: store.userKey(userID: payerID))
        XCTAssertFalse(subscription.isActive)
    }

    /// Underpayment means the shop is misconfigured or the order was tampered
    /// with: nothing is granted, and the payer is not left waiting in silence.
    func testUnderpaidNotificationGrantsNothingAndSaysSo() async throws {
        let checkout = try await service.createCheckout(
            payerKey: store.userKey(userID: payerID),
            payerUserID: payerID,
            chatID: payerID,
            threadID: nil,
            purpose: .subscription,
            methodCode: nil
        )
        _ = await service.handleCallback(
            vendor: .freekassa,
            parameters: notification(orderID: checkout.order.id, amount: "1.00", paymentID: "555")
        )
        let subscription = await store.tenantSubscription(ownerUsername: store.userKey(userID: payerID))
        XCTAssertFalse(subscription.isActive)
        let call = await telegram.waitForCall("sendMessage", containing: "не совпала")
        XCTAssertNotNil(call)
    }

    func testNotificationURLIsTheOneTheCabinetNeeds() async {
        let url = await service.callbackURL(for: .freekassa)
        XCTAssertEqual(url, "https://bot.example.com/payments/freekassa")
    }
}
