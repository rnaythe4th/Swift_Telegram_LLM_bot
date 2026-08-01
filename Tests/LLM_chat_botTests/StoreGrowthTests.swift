import XCTest
@testable import LLM_chat_bot

/// Referral: two-sided rewards, the paid-conversion bonus and the anti-fraud
/// rules that keep a farm of empty accounts from paying for itself.
final class StoreReferralTests: XCTestCase {

    /// An inviter the bot has met, and a friend it has never seen.
    private func makePair() async -> ChatContextStore {
        let store = Fixtures.makeStore()
        await store.identifyUser(userID: 100, username: "inviter", firstName: "Inviter")
        return store
    }

    func testBindThenRewardOnTheFirstRealAnswer() async {
        let store = await makePair()

        let outcome = await store.bindReferral(invitedUserID: 200, invitedUsername: "friend", inviterUserID: 100)
        guard case .bound(let inviter, let inviteeReward) = outcome else {
            return XCTFail("expected a binding, got \(outcome)")
        }
        XCTAssertEqual(inviter, "@inviter")
        XCTAssertEqual(inviteeReward, ReferralConfig.default.inviteeReward)

        // Binding alone pays nothing — that is what makes farming expensive.
        var inviterWallet = await store.balance(UserKey.identified(100))
        XCTAssertNil(inviterWallet)

        await store.identifyUser(userID: 200, username: "friend", firstName: nil)
        let payout = await store.redeemReferralIfDue(userID: 200, username: "friend")
        XCTAssertEqual(payout?.inviterUserID, 100)
        XCTAssertEqual(payout?.inviterReward, ReferralConfig.default.inviterReward)
        XCTAssertEqual(payout?.inviteeReward, ReferralConfig.default.inviteeReward)

        // The store decides and stamps; it does **not** credit. Money moves
        // through `LedgerPort` under its own idempotency claim, so a crash
        // between the credit and the stamp cannot pay the pair twice (§10.2).
        // `EndToEndTests.testReferralDeepLinkPaysAfterFirstAnswer` covers the
        // whole path, wallets included.
        inviterWallet = await store.balance(UserKey.identified(100))
        XCTAssertNil(inviterWallet, "crediting here as well would pay the bonus twice")
    }

    func testRewardIsPaidOnlyOnce() async {
        let store = await makePair()
        _ = await store.bindReferral(invitedUserID: 200, invitedUsername: nil, inviterUserID: 100)
        _ = await store.redeemReferralIfDue(userID: 200, username: nil)
        let again = await store.redeemReferralIfDue(userID: 200, username: nil)
        XCTAssertNil(again, "a redelivered message must not pay twice")
    }

    func testSelfInviteIsRefusedAndCounted() async {
        let store = await makePair()
        let outcome = await store.bindReferral(invitedUserID: 100, invitedUsername: "inviter", inviterUserID: 100)
        XCTAssertEqual(outcome, .selfInvite)
        let overview = await store.referralOverview()
        XCTAssertEqual(overview.refusedSelf, 1)
        XCTAssertEqual(overview.bound, 0)
    }

    func testOnePersonIsAttributedOnceForever() async {
        let store = await makePair()
        await store.identifyUser(userID: 101, username: "other", firstName: nil)
        _ = await store.bindReferral(invitedUserID: 200, invitedUsername: nil, inviterUserID: 100)

        let second = await store.bindReferral(invitedUserID: 200, invitedUsername: nil, inviterUserID: 101)
        guard case .alreadyBound = second else { return XCTFail("expected alreadyBound, got \(second)") }
        let overview = await store.referralOverview()
        XCTAssertEqual(overview.refusedRepeat, 1)
    }

    func testUnknownInviterIsRefused() async {
        let store = Fixtures.makeStore()
        let outcome = await store.bindReferral(invitedUserID: 200, invitedUsername: nil, inviterUserID: 999)
        XCTAssertEqual(outcome, .unknownInviter)
        let overview = await store.referralOverview()
        XCTAssertEqual(overview.refusedUnknown, 1)
    }

    func testExistingUserCannotBeInvited() async {
        let store = await makePair()
        // The "friend" already has a wallet — they are not a new user.
        _ = await store.creditPurchasedBalance(key: UserKey.identified(200), amount: .usd(1))
        let outcome = await store.bindReferral(invitedUserID: 200, invitedUsername: nil, inviterUserID: 100)
        XCTAssertEqual(outcome, .notNewUser)
        let overview = await store.referralOverview()
        XCTAssertEqual(overview.refusedNotNew, 1)
    }

    /// Past the cap the pair still binds — but the friend is not promised money
    /// that will never arrive.
    func testCapStopsPayoutsAndIsSaidUpFront() async {
        let store = await makePair()
        var config = ReferralConfig.default
        config.maxRewardsPerInviter = 1
        await store.setReferralConfig(config)

        _ = await store.bindReferral(invitedUserID: 200, invitedUsername: nil, inviterUserID: 100)
        _ = await store.redeemReferralIfDue(userID: 200, username: nil)

        let second = await store.bindReferral(invitedUserID: 201, invitedUsername: nil, inviterUserID: 100)
        guard case .boundWithoutReward = second else {
            return XCTFail("expected boundWithoutReward, got \(second)")
        }
        let payout = await store.redeemReferralIfDue(userID: 201, username: nil)
        XCTAssertNil(payout)

        let overview = await store.referralOverview()
        XCTAssertEqual(overview.rewarded, 1)
        XCTAssertEqual(overview.blocked, 1)
    }

    /// Raising the cap pays the pair that was waiting behind it.
    func testRaisingTheCapUnblocksAPendingPair() async {
        let store = await makePair()
        var config = ReferralConfig.default
        config.maxRewardsPerInviter = 1
        await store.setReferralConfig(config)
        _ = await store.bindReferral(invitedUserID: 200, invitedUsername: nil, inviterUserID: 100)
        _ = await store.redeemReferralIfDue(userID: 200, username: nil)
        _ = await store.bindReferral(invitedUserID: 201, invitedUsername: nil, inviterUserID: 100)

        config.maxRewardsPerInviter = 5
        await store.setReferralConfig(config)
        let payout = await store.redeemReferralIfDue(userID: 201, username: nil)
        XCTAssertNotNil(payout)
    }

    /// The bonus that buys customers rather than signups: paid once, and the
    /// anti-farming cap deliberately does not apply to it.
    func testPayingFriendBonusIsPaidOnceAndIgnoresTheCap() async {
        let store = await makePair()
        var config = ReferralConfig.default
        config.maxRewardsPerInviter = 1
        await store.setReferralConfig(config)
        _ = await store.bindReferral(invitedUserID: 200, invitedUsername: nil, inviterUserID: 100)
        _ = await store.redeemReferralIfDue(userID: 200, username: nil)

        let bonus = await store.redeemReferralPaymentBonus(payerUserID: 200)
        XCTAssertEqual(bonus?.amount, ReferralConfig.default.payingFriendBonus)
        let again = await store.redeemReferralPaymentBonus(payerUserID: 200)
        XCTAssertNil(again, "a redelivered payment must not pay the bonus twice")

        let overview = await store.referralOverview()
        XCTAssertEqual(overview.paidConversions, 1)
    }

    func testDisabledProgramBindsNothing() async {
        let store = await makePair()
        var config = ReferralConfig.default
        config.enabled = false
        await store.setReferralConfig(config)

        let outcome = await store.bindReferral(invitedUserID: 200, invitedUsername: nil, inviterUserID: 100)
        XCTAssertEqual(outcome, .disabled)
    }

    func testPersonalStatsCountPendingAndRewarded() async {
        let store = await makePair()
        _ = await store.bindReferral(invitedUserID: 200, invitedUsername: nil, inviterUserID: 100)
        _ = await store.bindReferral(invitedUserID: 201, invitedUsername: nil, inviterUserID: 100)
        _ = await store.redeemReferralIfDue(userID: 200, username: nil)

        let stats = await store.referralUserStats(userID: 100)
        XCTAssertEqual(stats.invited, 2)
        XCTAssertEqual(stats.rewarded, 1)
        XCTAssertEqual(stats.pending, 1)
        XCTAssertEqual(stats.capRemaining, ReferralConfig.default.maxRewardsPerInviter - 1)
    }

    func testConfigIsClampedOnSet() async {
        let store = Fixtures.makeStore()
        var wild = ReferralConfig.default
        wild.inviterRewardCents = 999_999
        wild.maxRewardsPerInviter = -5
        await store.setReferralConfig(wild)

        let stored = await store.referralConfig()
        XCTAssertEqual(stored.inviterRewardCents, ReferralConfig.rewardRange.upperBound)
        XCTAssertEqual(stored.maxRewardsPerInviter, ReferralConfig.capRange.lowerBound)
    }
}

/// Paid-traffic attribution: the three numbers a campaign is judged on.
final class StoreTrafficSourceTests: XCTestCase {

    func testTagSanitizationAndLinkShape() {
        XCTAssertEqual(TrafficSourceLink.sanitize("Telegram Ads!"), "telegramads")
        XCTAssertEqual(TrafficSourceLink.sanitize("vk-2024_a"), "vk-2024_a")
        XCTAssertNil(TrafficSourceLink.sanitize("!!!"))
        XCTAssertEqual(TrafficSourceLink.sanitize(String(repeating: "a", count: 50))?.count, TrafficSourceLink.maxTagLength)

        XCTAssertEqual(TrafficSourceLink.tag(payload: "src_vk"), "vk")
        XCTAssertNil(TrafficSourceLink.tag(payload: "ref_123"))
        XCTAssertTrue(TrafficSourceLink.url(botUsername: "testbot", tag: "vk").contains("start=src_vk"))
    }

    func testJoinActivatePayIsCountedPerCampaign() async {
        let store = Fixtures.makeStore()

        let outcome = await store.bindTrafficSource(userID: 300, tag: "vk", username: nil)
        XCTAssertEqual(outcome, .bound(tag: "vk"))
        await store.markTrafficSourceActivation(userID: 300)
        await store.recordTrafficSourcePayment(userID: 300)
        await store.recordTrafficSourcePayment(userID: 300)   // repeat purchase

        let overview = await store.trafficSourceOverview()
        let row = overview.rows.first { $0.tag == "vk" }
        XCTAssertEqual(row?.tally.joined, 1)
        XCTAssertEqual(row?.tally.activated, 1)
        XCTAssertEqual(row?.tally.payers, 1, "a repeat purchase is not a second payer")
        XCTAssertEqual(row?.tally.payments, 2)
    }

    /// First touch wins: a later campaign must not claim a click somebody else
    /// paid for.
    func testSecondLinkDoesNotStealTheAttribution() async {
        let store = Fixtures.makeStore()
        _ = await store.bindTrafficSource(userID: 301, tag: "vk", username: nil)
        let second = await store.bindTrafficSource(userID: 301, tag: "google", username: nil)
        XCTAssertEqual(second, .alreadyAttributed(tag: "vk"))

        let overview = await store.trafficSourceOverview()
        XCTAssertEqual(overview.rows.first { $0.tag == "google" }?.tally.joined ?? 0, 0)
    }

    /// Counting existing users as acquisitions would make CAC look better than
    /// it is.
    func testExistingUserIsNotAnAcquisition() async {
        let store = Fixtures.makeStore()
        _ = await store.creditPurchasedBalance(key: UserKey.identified(302), amount: .usd(1))
        let outcome = await store.bindTrafficSource(userID: 302, tag: "vk", username: nil)
        XCTAssertEqual(outcome, .knownUser)
    }

    func testActivationWithoutAttributionIsIgnored() async {
        let store = Fixtures.makeStore()
        await store.markTrafficSourceActivation(userID: 999)
        await store.recordTrafficSourcePayment(userID: 999)
        let overview = await store.trafficSourceOverview()
        XCTAssertTrue(overview.rows.isEmpty)
    }

    func testClearingWipesEverything() async {
        let store = Fixtures.makeStore()
        _ = await store.bindTrafficSource(userID: 303, tag: "vk", username: nil)
        await store.clearTrafficSources()
        let overview = await store.trafficSourceOverview()
        XCTAssertTrue(overview.rows.isEmpty)
    }
}
