import XCTest
@testable import LLM_chat_bot

/// Adoption: everything stored under a bare handle moves to `#<userID>` the
/// first time that person actually talks to the bot. Losing any of it would
/// mean losing money, access or a role on a rename.
final class StoreIdentityTests: XCTestCase {

    func testPendingWalletIsAdoptedAndSummed() async {
        let store = Fixtures.makeStore()
        // Somebody was told about, but never seen: a pending record.
        _ = await store.creditPurchasedBalance(key: UserKey.pending("@newbie")!, amount: .usd(3))
        let pending = await store.balance(UserKey.pending("newbie")!)
        XCTAssertEqual(pending?.balance, .usd(3))

        await store.identifyUser(userID: 700, username: "newbie", firstName: "Newbie")

        let adopted = await store.balance(UserKey.identified(700))
        XCTAssertEqual(adopted?.balance, .usd(3))
        XCTAssertEqual(adopted?.toppedUp, .usd(3), "a proven payer must not become a stranger again")
    }

    /// Wallets under both keys are merged whole — including the "paid real
    /// money" marker and the lapse timestamps.
    func testWalletsUnderBothKeysAreMerged() async {
        let store = Fixtures.makeStore()
        _ = await store.creditPurchasedBalance(key: UserKey.pending("@dual")!, amount: .usd(2))
        _ = await store.creditBalance(key: UserKey.identified(701), amount: .usd(5))

        await store.identifyUser(userID: 701, username: "dual", firstName: nil)

        let wallet = await store.balance(UserKey.identified(701))
        XCTAssertEqual(wallet?.balance, .usd(7))
        XCTAssertEqual(wallet?.toppedUp, .usd(2))
        let leftovers = await store.allBalances().filter { $0.key == UserKey.pending("dual") }
        XCTAssertTrue(leftovers.isEmpty, "the pending row must not linger")
    }

    func testPendingLicenceIsAdopted() async {
        let store = Fixtures.makeStore()
        await store.identifyUser(userID: 702, username: "sponsor", firstName: nil)
        let sponsor = UserKey.identified(702)
        _ = await store.activatePaidSubscription(sponsor)
        _ = await store.addLicensedUser(ownerKey: sponsor, target: UserKey.pending("@guest")!)

        // Before the guest is seen, the licence hangs off their handle.
        var covered = await store.hasSubscriptionCoverage(key: UserKey.pending("guest")!, userID: nil, chatID: nil)
        XCTAssertTrue(covered)

        await store.identifyUser(userID: 703, username: "guest", firstName: nil)
        covered = await store.hasSubscriptionCoverage(key: nil, userID: 703, chatID: nil)
        XCTAssertTrue(covered, "the licence must survive the move to a stable key")

        let licensed = await store.licensedUsers(ownerKey: sponsor)
        XCTAssertEqual(licensed.map(\.key), [UserKey.identified(703)])
        XCTAssertEqual(licensed.map(\.label), ["@guest"])
    }

    func testPendingSuperAdminIsAdopted() async {
        let store = Fixtures.makeStore()
        _ = await store.addSuperAdmin(UserKey.pending("@staff")!)
        await store.identifyUser(userID: 704, username: "staff", firstName: nil)

        let isSuper = await store.isSuperAdmin(UserKey.identified(704))
        XCTAssertTrue(isSuper)
        let keys = await store.listSuperAdmins().map(\.key)
        XCTAssertTrue(keys.contains(UserKey.identified(704)))
        XCTAssertFalse(keys.contains(UserKey.pending("staff")!))
    }

    func testPendingTenantAndItsChatsAreAdopted() async {
        let store = Fixtures.makeStore()
        _ = await store.activatePaidSubscription(UserKey.pending("@futureadmin")!)
        _ = await store.assignChat(chatID: -800, to: UserKey.pending("futureadmin")!)

        await store.identifyUser(userID: 705, username: "futureadmin", firstName: nil)
        let key = UserKey.identified(705)

        let subscription = await store.tenantSubscription(ownerKey: key)
        XCTAssertTrue(subscription.isActive)
        let owner = await store.chatOwner(chatID: -800)
        XCTAssertEqual(owner, key)
    }

    /// Renaming changes only the label — never where the state lives.
    func testRenameKeepsEverythingInPlace() async {
        let store = Fixtures.makeStore()
        await store.identifyUser(userID: 706, username: "before", firstName: nil)
        let key = UserKey.identified(706)
        _ = await store.activatePaidSubscription(key)

        await store.identifyUser(userID: 706, username: "after", firstName: nil)

        let subscription = await store.tenantSubscription(ownerKey: key)
        XCTAssertTrue(subscription.isActive)
        let label = await store.displayLabel(forKey: key)
        XCTAssertEqual(label, "@after")
        let stale = await store.userKey(forHandle: "before")
        XCTAssertEqual(stale, UserKey.pending("before"), "the freed handle no longer points at them")
    }

    func testLabelsNeverShowTheStorageKey() async {
        let store = Fixtures.makeStore()
        await store.identifyUser(userID: 707, username: nil, firstName: "Без ника")

        let label = await store.displayLabel(forKey: UserKey.identified(707))
        XCTAssertEqual(label, "Без ника")
        XCTAssertFalse(label.contains("#"))

        let unknown = await store.displayLabel(forKey: UserKey.identified(9_999))
        XCTAssertEqual(unknown, "id 9999")
    }
}

/// Chat ownership: who a chat belongs to, and what a payment may and may not
/// take away.
final class StoreChatOwnershipTests: XCTestCase {

    func testAutoAssignAttachesAnUnownedChatToTheSendersTenant() async {
        let store = Fixtures.makeStore()
        await store.identifyUser(userID: 800, username: "admin", firstName: nil)
        let key = UserKey.identified(800)
        _ = await store.activatePaidSubscription(key)

        await store.autoAssignIfNeeded(chatID: -810, senderKey: UserKey.pending("admin"), senderUserID: 800)
        let owner = await store.chatOwner(chatID: -810)
        XCTAssertEqual(owner, key)
    }

    func testAutoAssignNeverOverwritesAnExistingOwner() async {
        let store = Fixtures.makeStore()
        await store.identifyUser(userID: 801, username: "first", firstName: nil)
        await store.identifyUser(userID: 802, username: "second", firstName: nil)
        _ = await store.activatePaidSubscription(UserKey.identified(801))
        _ = await store.activatePaidSubscription(UserKey.identified(802))
        _ = await store.assignChat(chatID: -811, to: UserKey.identified(801))

        await store.autoAssignIfNeeded(chatID: -811, senderKey: UserKey.pending("second"), senderUserID: 802)
        let owner = await store.chatOwner(chatID: -811)
        XCTAssertEqual(owner, UserKey.identified(801))
    }

    /// Buying premium inside someone else's group must not quietly take the
    /// group away from the sponsor who is still paying for it.
    func testPaymentKeepsALiveSponsorsGroup() async {
        let store = Fixtures.makeStore()
        await store.identifyUser(userID: 803, username: "sponsor", firstName: nil)
        await store.identifyUser(userID: 804, username: "member", firstName: nil)
        let sponsor = UserKey.identified(803)
        let member = UserKey.identified(804)
        _ = await store.activatePaidSubscription(sponsor)
        _ = await store.assignChat(chatID: -812, to: sponsor)
        _ = await store.activatePaidSubscription(member)

        let outcome = await store.claimChatForPayment(chatID: -812, payerKey: member)
        guard case .keptSponsor(let label) = outcome else {
            return XCTFail("expected keptSponsor, got \(outcome)")
        }
        XCTAssertEqual(label, "@sponsor")
        let owner = await store.chatOwner(chatID: -812)
        XCTAssertEqual(owner, sponsor)
    }

    func testPaymentClaimsAGroupWhoseSponsorLapsed() async {
        let store = Fixtures.makeStore()
        await store.identifyUser(userID: 805, username: "expired", firstName: nil)
        await store.identifyUser(userID: 806, username: "payer", firstName: nil)
        let old = UserKey.identified(805)
        let payer = UserKey.identified(806)
        _ = await store.activatePaidSubscription(old)
        _ = await store.assignChat(chatID: -813, to: old)
        _ = await store.expireTenantSubscription(old)
        _ = await store.activatePaidSubscription(payer)

        let outcome = await store.claimChatForPayment(chatID: -813, payerKey: payer)
        guard case .assigned = outcome else { return XCTFail("expected assigned, got \(outcome)") }
        let owner = await store.chatOwner(chatID: -813)
        XCTAssertEqual(owner, payer)
    }

    /// The payer's own DM always follows the payer.
    func testPrivateChatAlwaysFollowsThePayer() async {
        let store = Fixtures.makeStore()
        await store.identifyUser(userID: 807, username: "a", firstName: nil)
        await store.identifyUser(userID: 808, username: "b", firstName: nil)
        _ = await store.activatePaidSubscription(UserKey.identified(807))
        _ = await store.activatePaidSubscription(UserKey.identified(808))
        _ = await store.assignChat(chatID: 808, to: UserKey.identified(807))

        let outcome = await store.claimChatForPayment(chatID: 808, payerKey: UserKey.identified(808))
        guard case .assigned = outcome else { return XCTFail("expected assigned, got \(outcome)") }
    }

    /// Telegram delivers a group entry twice (`my_chat_member` and the replayed
    /// `/start`), so only one of the two paths may greet.
    func testOnlyOnePathGreetsAGroup() async {
        let store = Fixtures.makeStore()
        let first = await store.claimGroupGreeting(chatID: -820)
        let second = await store.claimGroupGreeting(chatID: -820)
        XCTAssertTrue(first)
        XCTAssertFalse(second)
    }
}
