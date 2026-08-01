import XCTest
@testable import LLM_chat_bot

/// Money: markup, wallets, the daily premium taste and the lapsed-wallet offer.
final class StoreBillingTests: XCTestCase {

    func testMarkupIsClampedAndDrivesEveryQuotedPrice() async {
        let store = Fixtures.makeStore()
        await store.setMarkupPercent(30)
        var multiplier = await store.priceMultiplier()
        XCTAssertEqual(multiplier, 1.3, accuracy: 0.0001)

        await store.setMarkupPercent(-10)
        multiplier = await store.priceMultiplier()
        XCTAssertEqual(multiplier, 1.0, accuracy: 0.0001)

        await store.setMarkupPercent(9_000)
        let clamped = await store.markupPercent()
        XCTAssertEqual(clamped, 500)
    }

    func testBilledCostFallsBackToTheCurrentMarkupForOldRows() async {
        let store = Fixtures.makeStore()
        await store.setMarkupPercent(50)
        let legacy = CumulativeUsage(totalTokens: 0, totalCost: .usd(2), generationCount: 1)
        let billed = await store.billedCost(of: legacy)
        XCTAssertEqual(billed, .usd(3))
    }

    /// Only a real credit-pack purchase makes someone a proven payer; bonuses
    /// must not.
    func testPurchasedCreditIsTrackedApartFromBonuses() async {
        let store = Fixtures.makeStore()
        await store.identifyUser(userID: 20, username: "payer", firstName: nil)
        let key = UserKey.forUserID(20)

        _ = await store.creditBalance(key: key, amount: .usd(1))      // referral bonus
        var wallet = await store.balance(username: key)
        XCTAssertEqual(wallet?.balance, .usd(1))
        XCTAssertEqual(wallet?.toppedUp, .zero)

        _ = await store.creditPurchasedBalance(key: key, amount: .usd(5))
        wallet = await store.balance(username: key)
        XCTAssertEqual(wallet?.balance, .usd(6))
        XCTAssertEqual(wallet?.toppedUp, .usd(5))
    }

    func testBillingKeyIgnoresEmptyWallets() async {
        let store = Fixtures.makeStore()
        await store.identifyUser(userID: 22, username: "broke", firstName: nil)
        let key = UserKey.forUserID(22)
        _ = await store.setBalanceAmount(username: key, amount: .usd(0))
        let billing = await store.billingKey(username: "broke", userID: 22)
        XCTAssertNil(billing)
    }

    /// The number under the answer and the number taken off the wallet come
    /// from the same formula — a projection that disagrees with the charge is
    /// a support ticket.
    func testProjectedBalanceMatchesTheChargeFormula() async {
        let store = Fixtures.makeStore()
        await store.setMarkupPercent(30)
        await store.identifyUser(userID: 23, username: "u", firstName: nil)
        let key = UserKey.forUserID(23)
        _ = await store.creditPurchasedBalance(key: key, amount: .usd(1))

        let projected = await store.projectedBalanceAfterCharge(username: key, realCost: .usd(0.5))

        let ledger = InMemoryLedger()
        _ = try? await ledger.inTransaction {
            try await $0.credit(key, .usd(1), kind: .topup, purchased: true, ref: nil)
        }
        let debit = try? await ledger.inTransaction {
            try await $0.debit(key, upTo: Money.usd(0.5).multiplied(byPercent: 30), real: .usd(0.5), ref: nil)
        }
        XCTAssertEqual(projected, debit?.remaining)
    }

    // MARK: - Daily premium taste

    func testDailyPremiumIsConsumedThenExhausted() async {
        let store = Fixtures.makeStore()
        await store.setDailyPremiumLimit(2)

        guard case .allowed(let remainingFirst, let limit) = await store.consumeDailyPremium(chatID: 30, userID: 30, isGroup: false) else {
            return XCTFail("first answer must be allowed")
        }
        XCTAssertEqual(limit, 2)
        XCTAssertEqual(remainingFirst, 1)

        guard case .allowed(let remainingSecond, _) = await store.consumeDailyPremium(chatID: 30, userID: 30, isGroup: false) else {
            return XCTFail("second answer must be allowed")
        }
        XCTAssertEqual(remainingSecond, 0)

        guard case .exhausted = await store.consumeDailyPremium(chatID: 30, userID: 30, isGroup: false) else {
            return XCTFail("third answer must hit the cap")
        }
    }

    /// A turn that produced nothing must not cost one of the day's few smart
    /// answers.
    func testRefundGivesTheUnitBack() async {
        let store = Fixtures.makeStore()
        await store.setDailyPremiumLimit(1)
        _ = await store.consumeDailyPremium(chatID: 31, userID: 31, isGroup: false)
        await store.refundDailyPremium(chatID: 31, userID: 31, isGroup: false)

        let left = await store.remainingDailyPremium(chatID: 31, userID: 31, isGroup: false)
        XCTAssertEqual(left.remaining, 1)
    }

    func testRefundCannotCreateCredit() async {
        let store = Fixtures.makeStore()
        await store.setDailyPremiumLimit(2)
        await store.refundDailyPremium(chatID: 32, userID: 32, isGroup: false)
        let left = await store.remainingDailyPremium(chatID: 32, userID: 32, isGroup: false)
        XCTAssertEqual(left.remaining, 2)
    }

    /// A group shares one allowance (social pressure); a DM counts per person.
    func testGroupSharesOneAllowanceAndPrivateChatsDoNot() async {
        let store = Fixtures.makeStore()
        await store.setDailyPremiumLimit(1)

        _ = await store.consumeDailyPremium(chatID: -40, userID: 1, isGroup: true)
        guard case .exhausted = await store.consumeDailyPremium(chatID: -40, userID: 2, isGroup: true) else {
            return XCTFail("a group shares one counter")
        }
        guard case .allowed = await store.consumeDailyPremium(chatID: 2, userID: 2, isGroup: false) else {
            return XCTFail("a private chat has its own counter")
        }
    }

    func testZeroLimitMeansNoTasteAtAll() async {
        let store = Fixtures.makeStore()
        await store.setDailyPremiumLimit(0)
        guard case .exhausted(let limit) = await store.consumeDailyPremium(chatID: 33, userID: 33, isGroup: false) else {
            return XCTFail("expected exhausted")
        }
        XCTAssertEqual(limit, 0, "0 means the feature is off — not 'you used 0 of 0'")
    }

    func testPaidModelAccessGateForPickers() async {
        let store = Fixtures.makeStore()
        await store.setDailyPremiumLimit(1)
        await store.identifyUser(userID: 34, username: "free", firstName: nil)

        guard case .dailyTaste(let remaining, _) = await store.paidModelAccess(username: "free", userID: 34, chatID: 34) else {
            return XCTFail("free tier with units left may still pick a smart model")
        }
        XCTAssertEqual(remaining, 1)

        _ = await store.consumeDailyPremium(chatID: 34, userID: 34, isGroup: false)
        guard case .none = await store.paidModelAccess(username: "free", userID: 34, chatID: 34) else {
            return XCTFail("spent allowance leaves free models only")
        }

        _ = await store.creditPurchasedBalance(key: UserKey.forUserID(34), amount: .usd(3))
        guard case .full = await store.paidModelAccess(username: "free", userID: 34, chatID: 34) else {
            return XCTFail("a positive balance lifts the ceiling")
        }
    }

    // MARK: - Lapsed wallets

    private func makeLapsedStore() async -> (ChatContextStore, key: String) {
        let store = Fixtures.makeStore()
        await store.identifyUser(userID: 50, username: "lapsed", firstName: nil)
        // A DM is the only channel for a wallet notice.
        await store.recordChatMeta(
            chatID: 50,
            info: ChatMetaInfo(type: "private", title: nil, username: "lapsed", firstName: nil)
        )
        let key = UserKey.forUserID(50)
        _ = await store.creditPurchasedBalance(key: key, amount: .usd(5))
        _ = await store.setBalanceAmount(username: key, amount: .usd(0))
        return (store, key)
    }

    func testLapsedWalletBecomesDueOnlyAfterTheIdlePeriod() async {
        let (store, key) = await makeLapsedStore()
        let now = Date()

        let tooEarly = await store.dueWalletWinbacks(now: now)
        XCTAssertTrue(tooEarly.isEmpty)

        let due = await store.dueWalletWinbacks(now: now.addingTimeInterval(Fixtures.days(30)))
        XCTAssertEqual(due.first?.key, key)
        XCTAssertEqual(due.first?.privateChatID, 50)
        XCTAssertEqual(due.first?.toppedUp, .usd(5))
    }

    func testOfferGoesOutOncePerLapseAndTopUpOpensANewCycle() async {
        let (store, key) = await makeLapsedStore()
        let later = Date().addingTimeInterval(Fixtures.days(30))

        _ = await store.markWalletWinbackSent(key: key, now: later)
        let afterSend = await store.dueWalletWinbacks(now: later)
        XCTAssertTrue(afterSend.isEmpty)

        _ = await store.creditPurchasedBalance(key: key, amount: .usd(5))
        _ = await store.setBalanceAmount(username: key, amount: .usd(0))
        let afterTopUp = await store.dueWalletWinbacks(now: later.addingTimeInterval(Fixtures.days(30)))
        XCTAssertEqual(afterTopUp.count, 1, "coming back and lapsing again is a new cycle")
    }

    /// The audience is proven payers only — free credit does not qualify.
    func testWalletThatNeverPaidIsNeverOffered() async {
        let store = Fixtures.makeStore()
        await store.identifyUser(userID: 51, username: "bonus", firstName: nil)
        await store.recordChatMeta(
            chatID: 51,
            info: ChatMetaInfo(type: "private", title: nil, username: "bonus", firstName: nil)
        )
        _ = await store.creditBalance(key: UserKey.forUserID(51), amount: .usd(1))
        _ = await store.setBalanceAmount(username: UserKey.forUserID(51), amount: .usd(0))

        let due = await store.dueWalletWinbacks(now: Date().addingTimeInterval(Fixtures.days(60)))
        XCTAssertTrue(due.isEmpty)
    }

    func testWalletWithMoneyLeftIsNotLapsed() async {
        let (store, key) = await makeLapsedStore()
        _ = await store.setBalanceAmount(username: key, amount: .usd(1))
        let due = await store.dueWalletWinbacks(now: Date().addingTimeInterval(Fixtures.days(60)))
        XCTAssertTrue(due.isEmpty)
    }
}
