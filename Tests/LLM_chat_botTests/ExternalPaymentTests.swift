import XCTest
@testable import LLM_chat_bot

// Hosted checkout (§7 «Внешняя касса»). The rules under test are product rules,
// not current outputs: an unsigned POST never buys anything, a quoted price is
// the price charged, one notification pays for one thing.

final class ExternalPaymentSignatureTests: XCTestCase {
    private let credentials = ExternalPaymentCredentials(
        merchantID: "7012",
        secretWord: "secret",
        callbackSecret: "secret2"
    )

    private func order(
        amountMinorUnits: Int = 10_011,
        id: String = "154",
        method: String? = nil,
        purpose: PurchasePurpose = .subscription
    ) -> ExternalPaymentOrder {
        ExternalPaymentOrder(
            id: id,
            vendor: .freekassa,
            payerKey: UserKey.identified(42),
            payerUserID: 42,
            chatID: 42,
            threadID: nil,
            purpose: purpose,
            currency: .rub,
            amountMinorUnits: amountMinorUnits,
            methodCode: method,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(3600),
            status: .pending,
            paidAt: nil,
            vendorPaymentID: nil
        )
    }

    /// The signature is the vendor's, not ours: this is the worked example from
    /// FreeKassa's own documentation, hashed outside this codebase.
    func testCheckoutURLCarriesTheDocumentedSignature() throws {
        let url = try FreeKassaCheckoutAdapter().checkoutURL(order: order(), credentials: credentials)
        XCTAssertTrue(url.hasPrefix("https://pay.fk.money/?"), url)
        XCTAssertTrue(url.contains("m=7012"), url)
        XCTAssertTrue(url.contains("oa=100.11"), url)
        XCTAssertTrue(url.contains("currency=RUB"), url)
        XCTAssertTrue(url.contains("o=154"), url)
        XCTAssertTrue(url.contains("s=64d0581f4a08af485a619950e023696a"), url)
        // No rail preselected unless one was configured.
        XCTAssertFalse(url.contains("&i="), url)
    }

    func testCheckoutURLPreselectsTheConfiguredRail() throws {
        let url = try FreeKassaCheckoutAdapter()
            .checkoutURL(order: order(method: "44"), credentials: credentials)
        XCTAssertTrue(url.contains("i=44"), url)
    }

    func testValidNotificationIsAccepted() throws {
        let callback = try FreeKassaCheckoutAdapter().verifyCallback(
            parameters: [
                "MERCHANT_ID": "7012",
                "AMOUNT": "100.11",
                "MERCHANT_ORDER_ID": "154",
                "intid": "987654",
                "CUR_ID": "44",
                "SIGN": "52f874217f646dd7624b46315a4e09d0",
            ],
            credentials: credentials
        )
        XCTAssertEqual(callback.orderID, "154")
        XCTAssertEqual(callback.vendorPaymentID, "987654")
        XCTAssertEqual(callback.amountMinorUnits, 10_011)
        XCTAssertEqual(callback.methodCode, "44")
    }

    /// The endpoint is public and hands out subscriptions: a wrong signature, a
    /// missing signature and a foreign merchant all have to fail closed.
    func testForgedNotificationsAreRejected() {
        let adapter = FreeKassaCheckoutAdapter()
        let valid = [
            "MERCHANT_ID": "7012",
            "AMOUNT": "100.11",
            "MERCHANT_ORDER_ID": "154",
            "SIGN": "52f874217f646dd7624b46315a4e09d0",
        ]

        var wrongSign = valid
        wrongSign["SIGN"] = String(repeating: "0", count: 32)
        XCTAssertThrowsError(try adapter.verifyCallback(parameters: wrongSign, credentials: credentials)) {
            XCTAssertEqual($0 as? ExternalPaymentError, .badSignature)
        }

        var noSign = valid
        noSign["SIGN"] = nil
        XCTAssertThrowsError(try adapter.verifyCallback(parameters: noSign, credentials: credentials)) {
            XCTAssertEqual($0 as? ExternalPaymentError, .badSignature)
        }

        // Same shape, signed with the *link* secret instead of the callback one.
        var linkSecretSign = valid
        linkSecretSign["SIGN"] = PaymentSignature.md5Hex("7012:100.11:secret:154")
        XCTAssertThrowsError(try adapter.verifyCallback(parameters: linkSecretSign, credentials: credentials)) {
            XCTAssertEqual($0 as? ExternalPaymentError, .badSignature)
        }

        // A tampered amount invalidates the signature it was not part of.
        var tamperedAmount = valid
        tamperedAmount["AMOUNT"] = "1.00"
        XCTAssertThrowsError(try adapter.verifyCallback(parameters: tamperedAmount, credentials: credentials)) {
            XCTAssertEqual($0 as? ExternalPaymentError, .badSignature)
        }
    }

    /// Documented casing is upper; what arrives has varied. A payment rejected
    /// over a lowercase key is indistinguishable from a wrong secret.
    func testFieldNamesAreMatchedCaseInsensitively() throws {
        let callback = try FreeKassaCheckoutAdapter().verifyCallback(
            parameters: [
                "merchant_id": "7012",
                "amount": "100.11",
                "merchant_order_id": "154",
                "sign": "52F874217F646DD7624B46315A4E09D0",
            ],
            credentials: credentials
        )
        XCTAssertEqual(callback.orderID, "154")
    }

    func testAmountsAreParsedWithoutFloatingPoint() {
        XCTAssertEqual(FiatCurrency.minorUnits(from: "499"), 49_900)
        XCTAssertEqual(FiatCurrency.minorUnits(from: "499.00"), 49_900)
        XCTAssertEqual(FiatCurrency.minorUnits(from: "0.29"), 29)
        XCTAssertEqual(FiatCurrency.minorUnits(from: "1 499,90"), 149_990)
        // Three decimals is not an amount in this currency — rounding it would
        // credit a different sum than the one that was paid.
        XCTAssertNil(FiatCurrency.minorUnits(from: "10.999"))
        XCTAssertNil(FiatCurrency.minorUnits(from: "abc"))
        XCTAssertEqual(FiatCurrency.decimalString(minorUnits: 49_900), "499.00")
    }
}

final class ExternalPaymentConfigTests: XCTestCase {
    func testMerchantIsUnusableUntilAllThreeSecretsExist() {
        var config = ExternalPaymentConfig.default
        XCTAssertNil(config.credentials)
        config.merchantID = "7012"
        config.secretWord = "one"
        XCTAssertNil(config.credentials, "two of three is still not a merchant")
        config.callbackSecret = "two"
        XCTAssertEqual(config.credentials?.merchantID, "7012")
    }

    func testSellingNeedsTheSwitchAndAPrice() {
        var config = ExternalPaymentConfig.default
        config.merchantID = "7012"
        config.secretWord = "one"
        config.callbackSecret = "two"
        config.priceMinorUnits = 49_900
        XCTAssertFalse(config.isEnabled, "credentials alone must not start selling")
        config.enabled = true
        XCTAssertTrue(config.isEnabled)
    }

    /// Same rule as the card (§7): switching the monthly plan off must not kill
    /// the cheapest entry point.
    func testTopUpsSurviveASwitchedOffSubscription() {
        var config = ExternalPaymentConfig.default
        config.enabled = true
        config.merchantID = "7012"
        config.secretWord = "one"
        config.callbackSecret = "two"
        config.usdRateMinorUnits = 9_500
        XCTAssertFalse(config.isEnabled)
        XCTAssertTrue(config.creditsEnabled)
        XCTAssertEqual(config.creditMinorUnits(cents: 200), 19_000)
        // Never below the currency floor — aggregators reject tiny orders.
        XCTAssertEqual(config.creditMinorUnits(cents: 1), FiatCurrency.rub.minMinorUnits)
    }

    func testMethodListIsTrimmedDedupedAndCapped() {
        var config = ExternalPaymentConfig.default
        config.methods = [
            ExternalPaymentMethod(code: " 44 ", title: "  СБП  "),
            ExternalPaymentMethod(code: "44", title: "СБП дубль"),
            ExternalPaymentMethod(code: "", title: "мусор"),
        ] + (0..<ExternalPaymentConfig.maxMethods).map {
            ExternalPaymentMethod(code: "code\($0)", title: "Способ \($0)")
        }
        let normalized = config.normalized
        XCTAssertEqual(normalized.methods.count, ExternalPaymentConfig.maxMethods)
        XCTAssertEqual(normalized.methods.first?.code, "44")
        XCTAssertEqual(normalized.methods.first?.title, "СБП")
        XCTAssertEqual(normalized.methods.filter { $0.code == "44" }.count, 1)
    }

    func testMethodParsingTakesCodeAndTitle() {
        let method = ExternalPaymentMethod.parse(" 44 | СБП ")
        XCTAssertEqual(method?.code, "44")
        XCTAssertEqual(method?.title, "СБП")
        // Title is optional; the code doubles as one.
        XCTAssertEqual(ExternalPaymentMethod.parse("13")?.title, "13")
        XCTAssertNil(ExternalPaymentMethod.parse("   "))
    }

    func testSecretsAreMaskedForDisplay() {
        XCTAssertEqual(ExternalPaymentConfig.mask("supersecretword")?.contains("supersecretword"), false)
        XCTAssertNil(ExternalPaymentConfig.mask(""))
    }

    /// A row written by another build must not take the merchant credentials
    /// down with it — one unreadable field cannot stop the bot taking money.
    func testUnknownFieldsAndVendorsDecodeToDefaults() throws {
        let json = """
        {"config":{"vendor":"some_new_vendor","enabled":true,"merchantID":"7012",
        "secretWord":"one","callbackSecret":"two","currency":"XXX","priceMinorUnits":49900,
        "methods":[{"code":"44","title":"СБП"}]},"orders":[]}
        """
        let snapshot = try JSONDecoder().decode(ExternalPaymentSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.config.merchantID, "7012")
        XCTAssertEqual(snapshot.config.vendor, .freekassa)
        XCTAssertEqual(snapshot.config.currency, .rub)
        XCTAssertEqual(snapshot.config.methods.count, 1)
    }
}

final class ExternalPaymentStoreTests: XCTestCase {
    private func configuredStore(
        price: Int? = 49_900,
        rate: Int? = 9_500
    ) async -> ChatContextStore {
        let store = Fixtures.makeStore()
        await store.setExternalPaymentConfig(ExternalPaymentConfig(
            vendor: .freekassa,
            enabled: true,
            merchantID: "7012",
            secretWord: "one",
            callbackSecret: "two",
            currency: .rub,
            priceMinorUnits: price,
            usdRateMinorUnits: rate,
            methods: [ExternalPaymentMethod(code: "44", title: "СБП")]
        ))
        return store
    }

    /// §17: every quoted price comes from `subscriptionPricing`, so a winback
    /// discount cannot show one number and charge another.
    func testWinbackDiscountReachesTheHostedCheckoutPrice() async {
        let store = await configuredStore()
        let discount = SubscriptionDiscount(percent: 30, expiresAt: Date().addingTimeInterval(3600))
        let pricing = await store.subscriptionPricing(key: UserKey.identified(42), applying: discount)
        XCTAssertEqual(pricing.externalMinorUnitsFull, 49_900)
        XCTAssertEqual(pricing.externalMinorUnits, 34_930)
        XCTAssertTrue(pricing.hasDiscount)
    }

    func testDiscountNeverFallsBelowTheCurrencyFloor() async {
        let store = await configuredStore(price: FiatCurrency.rub.minMinorUnits)
        let discount = SubscriptionDiscount(percent: 90, expiresAt: Date().addingTimeInterval(3600))
        let pricing = await store.subscriptionPricing(key: UserKey.identified(42), applying: discount)
        XCTAssertEqual(pricing.externalMinorUnits, FiatCurrency.rub.minMinorUnits)
    }

    func testDisabledCheckoutQuotesNoPrice() async {
        let store = await configuredStore()
        await store.updateExternalPaymentConfig { $0.enabled = false }
        let pricing = await store.subscriptionPricing(key: UserKey.identified(42))
        XCTAssertNil(pricing.externalMinorUnits)
    }

    /// Tapping "оплатить" twice must reuse the open order: two live orders for
    /// one purchase are two payments waiting to happen.
    func testOpenOrderIsReusedForTheSamePurchase() async {
        let store = await configuredStore()
        let order = makeOrder(id: "a1", purpose: .subscription, method: "44")
        await store.upsertExternalOrder(order)
        let found = await store.openExternalOrder(payerKey: UserKey.identified(42), purpose: .subscription, methodCode: "44")
        XCTAssertEqual(found?.id, "a1")
        // A different rail or a different thing bought is a different order.
        let otherRail = await store.openExternalOrder(payerKey: UserKey.identified(42), purpose: .subscription, methodCode: "13")
        XCTAssertNil(otherRail)
        let otherPurpose = await store.openExternalOrder(
            payerKey: UserKey.identified(42),
            purpose: .credit(cents: 200),
            methodCode: "44"
        )
        XCTAssertNil(otherPurpose)
    }

    /// A notification is delivered until acknowledged, so the second one must
    /// find nothing left to pay for.
    func testAnOrderCanOnlyBePaidOnce() async {
        let store = await configuredStore()
        await store.upsertExternalOrder(makeOrder(id: "a1", purpose: .subscription, method: nil))
        let first = await store.markExternalOrderPaid(id: "a1", vendorPaymentID: "987")
        XCTAssertEqual(first?.status, .paid)
        let second = await store.markExternalOrderPaid(id: "a1", vendorPaymentID: "987")
        XCTAssertNil(second)
    }

    func testExpiredOrdersStopBeingPayable() async {
        let store = await configuredStore()
        var stale = makeOrder(id: "old", purpose: .subscription, method: nil)
        stale.expiresAt = Date().addingTimeInterval(-60)
        await store.upsertExternalOrder(stale)
        let expired = await store.expireDueExternalOrders()
        XCTAssertEqual(expired.count, 1)
        let paid = await store.markExternalOrderPaid(id: "old", vendorPaymentID: "987")
        XCTAssertNil(paid)
    }

    /// The callback lands in whichever process is alive by then, so both the
    /// merchant configuration and the open orders have to survive a restart.
    func testConfigAndOpenOrdersSurviveARestart() async {
        let store = await configuredStore()
        await store.upsertExternalOrder(makeOrder(id: "a1", purpose: .credit(cents: 500), method: "44"))

        let batch = await store.drainDirtyBatch()
        XCTAssertTrue(batch.configs.contains { $0.name == .externalPayments })
        XCTAssertEqual(batch.externalOrders.count, 1, "an open order is a row of its own")

        // Round-trip through JSON, exactly as the config row does.
        let stored = await store.externalPaymentConfig()
        let data = try! JSONEncoder().encode(stored)
        let decoded = try! JSONDecoder().decode(ExternalPaymentConfig.self, from: data)

        let restored = Fixtures.makeStore()
        await restored.restoreExternalPayments(config: decoded, orders: batch.externalOrders.map(\.order))
        let config = await restored.externalPaymentConfig()
        XCTAssertEqual(config.merchantID, "7012")
        XCTAssertEqual(config.callbackSecret, "two")
        XCTAssertEqual(config.priceMinorUnits, 49_900)
        let order = await restored.externalOrder(id: "a1")
        XCTAssertEqual(order?.purpose, .credit(cents: 500))
        XCTAssertEqual(order?.amountMinorUnits, 47_500)
    }

    private func makeOrder(id: String, purpose: PurchasePurpose, method: String?) -> ExternalPaymentOrder {
        let amount: Int
        switch purpose {
        case .subscription: amount = 49_900
        case .credit(let cents): amount = cents * 95
        }
        return ExternalPaymentOrder(
            id: id,
            vendor: .freekassa,
            payerKey: UserKey.identified(42),
            payerUserID: 42,
            chatID: 42,
            threadID: nil,
            purpose: purpose,
            currency: .rub,
            amountMinorUnits: amount,
            methodCode: method,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(3600),
            status: .pending,
            paidAt: nil,
            vendorPaymentID: nil
        )
    }
}
