import XCTest
@testable import LLM_chat_bot

/// Who gets smart models, and who pays for them. Every gate in the bot funnels
/// through these three methods, so their precedence order is load-bearing.
final class StoreAccessTests: XCTestCase {

    private func makeSponsoredStore() async -> (ChatContextStore, sponsorKey: String) {
        let store = Fixtures.makeStore()
        await store.identifyUser(userID: 500, username: "sponsor", firstName: "Sponsor")
        _ = await store.activatePaidSubscription(username: UserKey.forUserID(500))
        return (store, UserKey.forUserID(500))
    }

    /// Callers hold keys, not handles (`invokerKey`, `actorKey`), and pass them
    /// in as `username:`. A key must resolve to itself — when it stopped doing
    /// so, every role gate silently answered "no" for identified users.
    func testKeyPassedAsUsernameResolvesToItself() async {
        let store = Fixtures.makeStore()
        await store.identifyUser(userID: 77, username: "alice", firstName: nil)

        let resolved = await store.userKey(username: "#77")
        XCTAssertEqual(resolved, "#77")
        let fromHandle = await store.userKey(username: "@alice")
        XCTAssertEqual(fromHandle, "#77")
        // Typed text still cannot forge a key shape it did not earn.
        let forged = await store.userKey(username: "#not-a-number")
        XCTAssertNil(forged)
    }

    func testRoleGatesAcceptKeysFromCallbackHandlers() async {
        let store = Fixtures.makeStore()
        await store.identifyUser(userID: Fixtures.ownerUserID, username: Fixtures.ownerUsername, firstName: nil)
        let key = await store.userKey(userID: Fixtures.ownerUserID)

        let isSuper = await store.isSuperAdmin(username: key)
        let isAdmin = await store.isAdmin(username: key, chatID: -1)
        let isOwner = await store.isTenantOwner(username: key, chatID: -1)
        XCTAssertTrue(isSuper)
        XCTAssertTrue(isAdmin)
        XCTAssertTrue(isOwner)
    }

    func testFreshUserHasNoCoverage() async {
        let store = Fixtures.makeStore()
        await store.identifyUser(userID: 7, username: "alice", firstName: nil)
        let covered = await store.hasSubscriptionCoverage(username: "alice", userID: 7, chatID: 7)
        XCTAssertFalse(covered)
        let status = await store.chatAccessStatus(chatID: 7, username: "alice", userID: 7)
        XCTAssertEqual(status, .free)
        XCTAssertFalse(status.isCovered)
    }

    func testOwnSubscriptionCovers() async {
        let (store, sponsor) = await makeSponsoredStore()
        let covered = await store.hasSubscriptionCoverage(username: sponsor, userID: 500, chatID: 500)
        XCTAssertTrue(covered)
        let status = await store.chatAccessStatus(chatID: 500, username: nil, userID: 500)
        guard case .ownSubscription = status else { return XCTFail("expected own subscription, got \(status)") }
    }

    func testExpiredSubscriptionStopsCovering() async {
        let (store, sponsor) = await makeSponsoredStore()
        _ = await store.expireTenantSubscription(username: sponsor)
        let covered = await store.hasSubscriptionCoverage(username: nil, userID: 500, chatID: 500)
        XCTAssertFalse(covered)
        // The panel survives: the tenant record is still there so they can renew.
        let subscription = await store.tenantSubscription(ownerUsername: sponsor)
        XCTAssertTrue(subscription.exists)
        XCTAssertFalse(subscription.isActive)
    }

    func testAssignedChatCoversEveryoneInIt() async {
        let (store, sponsor) = await makeSponsoredStore()
        _ = await store.assignChat(chatID: -100, to: sponsor)

        let guestCovered = await store.hasSubscriptionCoverage(username: "stranger", userID: 9, chatID: -100)
        XCTAssertTrue(guestCovered)
        let status = await store.chatAccessStatus(chatID: -100, username: "stranger", userID: 9)
        XCTAssertEqual(status, .sponsored("@sponsor"))
        XCTAssertEqual(status.payerUsername, "@sponsor")
    }

    func testLicensedUserIsCoveredAnywhere() async {
        let (store, sponsor) = await makeSponsoredStore()
        await store.identifyUser(userID: 9, username: "guest", firstName: nil)
        _ = await store.addLicensedUser(ownerUsername: sponsor, target: "@guest")

        let covered = await store.hasSubscriptionCoverage(username: "guest", userID: 9, chatID: -777)
        XCTAssertTrue(covered)
        let status = await store.chatAccessStatus(chatID: -777, username: "guest", userID: 9)
        XCTAssertEqual(status, .guest("@sponsor"))
    }

    func testWhitelistedUserIsCoveredInThatChat() async {
        let (store, sponsor) = await makeSponsoredStore()
        _ = await store.assignChat(chatID: -101, to: sponsor)
        await store.addToWhitelist(userID: 11, chatID: -101)
        _ = await store.unassignChat(chatID: -101)
        // Chat no longer belongs to the sponsor, so only the whitelist could
        // cover — and it hangs off the default tenant, which is not paid.
        let covered = await store.hasSubscriptionCoverage(username: nil, userID: 11, chatID: -101)
        XCTAssertFalse(covered)
    }

    func testPositiveBalanceGivesFullAccessButNotSubscriptionCoverage() async {
        let store = Fixtures.makeStore()
        await store.identifyUser(userID: 12, username: "payer", firstName: nil)
        _ = await store.creditPurchasedBalance(username: UserKey.forUserID(12), amount: .usd(5))

        let subscription = await store.hasSubscriptionCoverage(username: "payer", userID: 12, chatID: 12)
        XCTAssertFalse(subscription)
        let full = await store.hasFullModelAccess(username: "payer", userID: 12, chatID: 12)
        XCTAssertTrue(full)
        let status = await store.chatAccessStatus(chatID: 12, username: nil, userID: 12)
        XCTAssertEqual(status, .balance(.usd(5)))
    }

    /// A wallet belongs to a person, not to a handle: no @username needed.
    func testBalanceIsFoundByUserIDAlone() async {
        let store = Fixtures.makeStore()
        await store.identifyUser(userID: 13, username: nil, firstName: "Без ника")
        _ = await store.creditBalance(key: UserKey.forUserID(13), amount: .usd(1))
        let key = await store.billingKey(username: nil, userID: 13)
        XCTAssertEqual(key, UserKey.forUserID(13))
    }

    func testSponsorCreditNamesTheSponsorButNotToThemselves() async {
        let (store, sponsor) = await makeSponsoredStore()
        _ = await store.assignChat(chatID: -200, to: sponsor)

        let forGuest = await store.chatSponsor(chatID: -200, askerUsername: "guest")
        XCTAssertEqual(forGuest, "@sponsor")
        let forSponsor = await store.chatSponsor(chatID: -200, askerUsername: "sponsor")
        XCTAssertNil(forSponsor)
    }

    /// Under every answer the credit is noise; once an hour it is a standing
    /// thank-you.
    func testSponsorCreditIsRateLimited() async {
        let (store, sponsor) = await makeSponsoredStore()
        _ = await store.assignChat(chatID: -201, to: sponsor)
        let now = Date()

        let first = await store.chatSponsorForCredit(chatID: -201, askerUsername: "guest", now: now)
        XCTAssertEqual(first, "@sponsor")
        let second = await store.chatSponsorForCredit(chatID: -201, askerUsername: "guest", now: now.addingTimeInterval(60))
        XCTAssertNil(second)
        let later = await store.chatSponsorForCredit(
            chatID: -201, askerUsername: "guest",
            now: now.addingTimeInterval(ChatContextStore.sponsorCreditCooldown + 1)
        )
        XCTAssertEqual(later, "@sponsor")
    }

    func testRootIsSuperAdminAndSimulationHidesIt() async {
        let store = Fixtures.makeStore()
        await store.identifyUser(userID: Fixtures.ownerUserID, username: Fixtures.ownerUsername, firstName: nil)
        let ownerKey = UserKey.forUserID(Fixtures.ownerUserID)

        var isSuper = await store.isSuperAdmin(username: ownerKey)
        XCTAssertTrue(isSuper)
        let isRoot = await store.isRootSuperAdmin(username: ownerKey)
        XCTAssertTrue(isRoot)

        _ = await store.setSimulatedRole(username: ownerKey, role: .regularUser)
        isSuper = await store.isSuperAdmin(username: ownerKey)
        XCTAssertFalse(isSuper, "simulation must hide the role from ordinary gates")
        let reallySuper = await store.isActuallySuperAdmin(username: ownerKey)
        XCTAssertTrue(reallySuper, "the /simulate gate itself must ignore simulation")
    }

    /// The owner is pinned by userID, so renting out the handle does not hand
    /// over root.
    func testPinnedOwnerKeepsRootAfterHandleChangesHands() async {
        let store = Fixtures.makeStore()
        await store.identifyUser(userID: Fixtures.ownerUserID, username: Fixtures.ownerUsername, firstName: nil)
        // Somebody else picks up the freed handle.
        await store.identifyUser(userID: 999, username: Fixtures.ownerUsername, firstName: "Impostor")

        let impostorIsRoot = await store.isRootSuperAdmin(username: UserKey.forUserID(999))
        XCTAssertFalse(impostorIsRoot)
        let ownerIsRoot = await store.isRootSuperAdmin(username: UserKey.forUserID(Fixtures.ownerUserID))
        XCTAssertTrue(ownerIsRoot)
    }
}
