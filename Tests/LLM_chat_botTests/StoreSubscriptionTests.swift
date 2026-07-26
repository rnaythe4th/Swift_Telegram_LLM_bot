import XCTest
@testable import LLM_chat_bot

/// Subscriptions: activation arithmetic, the sweep's notice selection and the
/// single source of prices every payment path reads.
final class StoreSubscriptionTests: XCTestCase {

    private func makeSponsor(_ store: ChatContextStore, userID: Int = 500, username: String = "sponsor") async -> String {
        await store.identifyUser(userID: userID, username: username, firstName: nil)
        return UserKey.forUserID(userID)
    }

    func testFirstPaymentStartsAndSecondExtends() async {
        let store = Fixtures.makeStore()
        let key = await makeSponsor(store)

        let first = await store.activatePaidSubscription(username: key)
        guard case .started(let until) = first else { return XCTFail("expected .started, got \(first)") }
        XCTAssertEqual(until.timeIntervalSinceNow, Fixtures.days(30), accuracy: 60)

        let second = await store.activatePaidSubscription(username: key)
        guard case .extended(let extended) = second else { return XCTFail("expected .extended, got \(second)") }
        XCTAssertEqual(extended.timeIntervalSinceNow, Fixtures.days(60), accuracy: 60)
    }

    /// Paying never shortens access: an expired subscription restarts from now,
    /// a live one is extended from its end.
    func testExpiredSubscriptionRestartsFromNow() async {
        let store = Fixtures.makeStore()
        let key = await makeSponsor(store)
        _ = await store.activatePaidSubscription(username: key)
        _ = await store.expireTenantSubscription(username: key)

        _ = await store.activatePaidSubscription(username: key)
        let subscription = await store.tenantSubscription(ownerUsername: key)
        XCTAssertTrue(subscription.isActive)
        XCTAssertEqual(subscription.paidUntil?.timeIntervalSinceNow ?? 0, Fixtures.days(30), accuracy: 60)
    }

    func testUnlimitedTenantStaysUnlimited() async {
        let store = Fixtures.makeStore()
        let key = await makeSponsor(store)
        _ = await store.activatePaidSubscription(username: key)
        _ = await store.setTenantUnlimited(username: key)

        let outcome = await store.activatePaidSubscription(username: key)
        guard case .alreadyUnlimited = outcome else {
            return XCTFail("expected .alreadyUnlimited, got \(outcome)")
        }
        let subscription = await store.tenantSubscription(ownerUsername: key)
        XCTAssertNil(subscription.paidUntil)
        XCTAssertTrue(subscription.isActive)
    }

    // MARK: - Sweep

    func testNoticeIsDueOncePerWaveAndClearedByRenewal() async {
        let store = Fixtures.makeStore()
        let key = await makeSponsor(store)
        _ = await store.activatePaidSubscription(username: key)
        let paidUntil = await store.tenantSubscription(ownerUsername: key).paidUntil!
        let dayBefore = paidUntil.addingTimeInterval(-Fixtures.days(0.5))

        var due = await store.dueSubscriptionNotices(now: dayBefore)
        XCTAssertEqual(due.first?.notice, .expiring(daysBefore: 1))
        XCTAssertEqual(due.first?.label, "@sponsor")

        _ = await store.markNoticeSent(username: key, notice: .expiring(daysBefore: 1), paidUntil: paidUntil)
        due = await store.dueSubscriptionNotices(now: dayBefore)
        XCTAssertTrue(due.isEmpty, "a delivered wave must not repeat inside its cycle")

        _ = await store.extendTenantSubscription(username: key, days: 30)
        let renewed = await store.tenantSubscription(ownerUsername: key).paidUntil!
        due = await store.dueSubscriptionNotices(now: renewed.addingTimeInterval(-Fixtures.days(0.5)))
        XCTAssertEqual(due.first?.notice, .expiring(daysBefore: 1), "a new cycle gets its own reminder")
    }

    /// A mark written against a stale cycle must not silence the live one.
    func testMarkForAnotherCycleIsRefused() async {
        let store = Fixtures.makeStore()
        let key = await makeSponsor(store)
        _ = await store.activatePaidSubscription(username: key)
        let accepted = await store.markNoticeSent(
            username: key, notice: .expiring(daysBefore: 1), paidUntil: Date(timeIntervalSince1970: 0)
        )
        XCTAssertFalse(accepted)
    }

    /// Super-admins own the bot rather than buy from it.
    func testSuperAdminIsNeverSoldTheBotsOwnProduct() async {
        let store = Fixtures.makeStore()
        let key = await makeSponsor(store, userID: 505, username: "staff")
        _ = await store.activatePaidSubscription(username: key)
        let paidUntil = await store.tenantSubscription(ownerUsername: key).paidUntil!
        let dayBefore = paidUntil.addingTimeInterval(-Fixtures.days(0.5))

        var due = await store.dueSubscriptionNotices(now: dayBefore)
        XCTAssertEqual(due.count, 1)

        _ = await store.addSuperAdmin(target: key)
        due = await store.dueSubscriptionNotices(now: dayBefore)
        XCTAssertTrue(due.isEmpty)
    }

    /// The bot's owner starts out unlimited, so a payment cannot shorten or
    /// restart their access.
    func testOwnerTenantIsUnlimitedFromTheStart() async {
        let store = Fixtures.makeStore()
        await store.identifyUser(userID: Fixtures.ownerUserID, username: Fixtures.ownerUsername, firstName: nil)
        let ownerKey = UserKey.forUserID(Fixtures.ownerUserID)

        let outcome = await store.activatePaidSubscription(username: ownerKey)
        guard case .alreadyUnlimited = outcome else {
            return XCTFail("expected .alreadyUnlimited, got \(outcome)")
        }
        let subscription = await store.tenantSubscription(ownerUsername: ownerKey)
        XCTAssertTrue(subscription.isActive)
        XCTAssertNil(subscription.paidUntil)
    }

    func testOptOutSilencesTheSweepForThatSponsor() async {
        let store = Fixtures.makeStore()
        let key = await makeSponsor(store)
        _ = await store.activatePaidSubscription(username: key)
        let paidUntil = await store.tenantSubscription(ownerUsername: key).paidUntil!
        _ = await store.setRemindersOptOut(username: key, optOut: true)

        let due = await store.dueSubscriptionNotices(now: paidUntil.addingTimeInterval(-Fixtures.days(0.5)))
        XCTAssertTrue(due.isEmpty)
        let optedOut = await store.remindersOptOut(username: key)
        XCTAssertTrue(optedOut)
    }

    // MARK: - Winback discount

    /// The sweep grants before it sends, so a transient send error must not push
    /// the deadline forward on every pass.
    func testDiscountIsGrantedOncePerWindow() async {
        let store = Fixtures.makeStore()
        let key = await makeSponsor(store)
        _ = await store.activatePaidSubscription(username: key)
        let now = Date()

        let first = await store.grantWinbackDiscount(username: key, percent: 30, hours: 48, now: now)
        let second = await store.grantWinbackDiscount(username: key, percent: 50, hours: 48, now: now.addingTimeInterval(3600))
        XCTAssertEqual(first?.expiresAt, second?.expiresAt)
        XCTAssertEqual(second?.percent, 30, "a percent changed mid-window applies to the next offer")
    }

    func testDiscountIsConsumedByAPurchase() async {
        let store = Fixtures.makeStore()
        let key = await makeSponsor(store)
        _ = await store.activatePaidSubscription(username: key)
        _ = await store.grantWinbackDiscount(username: key, percent: 30, hours: 48)

        let consumed = await store.consumeWinbackDiscount(username: key)
        XCTAssertEqual(consumed?.percent, 30)
        let afterwards = await store.subscriptionDiscount(username: key)
        XCTAssertNil(afterwards)
    }

    func testPricingAppliesTheDiscountToEveryMethod() async {
        let store = Fixtures.makeStore()
        let key = await makeSponsor(store)
        _ = await store.activatePaidSubscription(username: key)
        await store.setStarsPrice(1000)
        await store.setCryptoPriceUsdCents(1000)
        _ = await store.grantWinbackDiscount(username: key, percent: 30, hours: 48)

        let pricing = await store.subscriptionPricing(username: key)
        XCTAssertTrue(pricing.hasDiscount)
        XCTAssertEqual(pricing.starsFull, 1000)
        XCTAssertEqual(pricing.stars, 700)
        XCTAssertEqual(pricing.cryptoCents, 700)
    }

    /// A personal offer must never reach a group price list.
    func testPricingWithoutAUserIsThePriceList() async {
        let store = Fixtures.makeStore()
        let key = await makeSponsor(store)
        _ = await store.activatePaidSubscription(username: key)
        await store.setStarsPrice(1000)
        _ = await store.grantWinbackDiscount(username: key, percent: 30, hours: 48)

        let pricing = await store.subscriptionPricing(username: nil)
        XCTAssertFalse(pricing.hasDiscount)
        XCTAssertEqual(pricing.stars, 1000)
    }

    /// The preview quotes what a real offer would, without granting anything.
    func testPreviewDiscountChangesNothingStored() async {
        let store = Fixtures.makeStore()
        let key = await makeSponsor(store)
        _ = await store.activatePaidSubscription(username: key)
        await store.setStarsPrice(1000)

        let preview = await store.subscriptionPricing(
            username: key,
            applying: SubscriptionDiscount(percent: 50, expiresAt: Date().addingTimeInterval(3600))
        )
        XCTAssertEqual(preview.stars, 500)
        let stored = await store.subscriptionDiscount(username: key)
        XCTAssertNil(stored)
    }

    func testClearAllDiscountsIsTheEscapeHatch() async {
        let store = Fixtures.makeStore()
        let a = await makeSponsor(store, userID: 501, username: "a")
        let b = await makeSponsor(store, userID: 502, username: "b")
        for key in [a, b] {
            _ = await store.activatePaidSubscription(username: key)
            _ = await store.grantWinbackDiscount(username: key, percent: 30, hours: 48)
        }
        let cleared = await store.clearAllWinbackDiscounts()
        XCTAssertEqual(cleared, 2)
    }

    // MARK: - Delivery channels

    func testGroupChannelsSkipChatsTheBotWasRemovedFrom() async {
        let store = Fixtures.makeStore()
        let key = await makeSponsor(store)
        _ = await store.activatePaidSubscription(username: key)
        _ = await store.assignChat(chatID: -900, to: key)
        _ = await store.assignChat(chatID: -901, to: key)

        var chats = await store.ownedGroupChatIDs(owner: key)
        XCTAssertEqual(Set(chats), [-900, -901])

        await store.setBotPresence(chatID: -901, isMember: false)
        chats = await store.ownedGroupChatIDs(owner: key)
        XCTAssertEqual(chats, [-900], "a chat the bot was thrown out of is not a channel")

        // Coming back restores it — the licence and the history were never lost.
        await store.setBotPresence(chatID: -901, isMember: true)
        chats = await store.ownedGroupChatIDs(owner: key)
        XCTAssertEqual(Set(chats), [-900, -901])
    }

    func testPrivateChannelNeedsADialogWithTheBot() async {
        let store = Fixtures.makeStore()
        let key = await makeSponsor(store, userID: 503, username: "dm")

        var dm = await store.privateChatID(forKey: key)
        XCTAssertNil(dm, "Telegram forbids bot-initiated conversations")

        await store.recordChatMeta(chatID: 503, info: ChatMetaInfo(type: "private", title: nil, username: "dm", firstName: nil))
        dm = await store.privateChatID(forKey: key)
        XCTAssertEqual(dm, 503)

        await store.setBotPresence(chatID: 503, isMember: false)
        dm = await store.privateChatID(forKey: key)
        XCTAssertNil(dm, "a blocked DM is not a channel")
    }
}
