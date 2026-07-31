import XCTest
@testable import LLM_chat_bot

/// The chat's "waiting for a typed value" slot. One wait per chat, and it
/// belongs to whoever armed it — in a group the next message can come from
/// anyone, and swallowing it reads as the bot being broken.
final class StorePendingInputTests: XCTestCase {

    private let chat = ChatKey(chatID: -500, threadID: 0)

    // MARK: - One slot

    func testArmingAWaitReplacesThePreviousOne() async {
        let store = Fixtures.makeStore()

        await store.setPending(.starsPrice, menuMessageID: 11, chatKey: chat)
        await store.setPending(.admin(.init(kind: .markupPercent)), menuMessageID: 22, chatKey: chat)

        let pending = await store.pendingRequest(chatKey: chat)
        XCTAssertEqual(pending?.menuMessageID, 22, "the newer wait must own the menu message")
        guard case .admin(let admin)? = pending?.kind else {
            return XCTFail("expected the admin wait to win, got \(String(describing: pending?.kind))")
        }
        XCTAssertEqual(admin.kind, .markupPercent)
    }

    func testConsumingLeavesNothingBehind() async {
        let store = Fixtures.makeStore()
        await store.setPending(.freeModel, menuMessageID: 7, chatKey: chat)
        await store.notePendingInputOwner("#1", chatKey: chat)

        let consumed = await store.consumePending(chatKey: chat)
        XCTAssertNotNil(consumed)

        let stillPending = await store.hasAnyPendingInput(chatKey: chat)
        XCTAssertFalse(stillPending)
        // The owner cannot outlive the wait: a stale one would hand the next
        // typed value to the wrong person.
        let owner = await store.pendingInputOwner(chatKey: chat)
        XCTAssertNil(owner)
    }

    func testClearingDropsEveryKindOfWait() async {
        let store = Fixtures.makeStore()
        for kind in [PendingKind.cryptoPrice, .cryptoAddress(chain: .ton), .preset(.init(category: .model, scope: .chat, kind: .add))] {
            await store.setPending(kind, menuMessageID: 3, chatKey: chat)
            await store.clearPending(chatKey: chat)
            let pending = await store.hasAnyPendingInput(chatKey: chat)
            XCTAssertFalse(pending, "\(kind) survived a clear")
        }
    }

    func testWaitsAreScopedToTheirChat() async {
        let store = Fixtures.makeStore()
        let other = ChatKey(chatID: -501, threadID: 0)
        await store.setPending(.starsPrice, menuMessageID: 1, chatKey: chat)

        let elsewhere = await store.hasAnyPendingInput(chatKey: other)
        XCTAssertFalse(elsewhere)
    }

    // MARK: - Ownership

    func testTheWaitBelongsToWhoeverArmedIt() async {
        let store = Fixtures.makeStore()
        await store.setPending(.starsPrice, menuMessageID: 9, chatKey: chat)
        await store.notePendingInputOwner("#42", chatKey: chat)

        let owner = await store.pendingInputOwner(chatKey: chat)
        XCTAssertEqual(owner, "#42")
    }

    func testANewTapperTakesOverTheWait() async {
        let store = Fixtures.makeStore()
        await store.setPending(.starsPrice, menuMessageID: 9, chatKey: chat)
        await store.notePendingInputOwner("#42", chatKey: chat)

        // Someone else taps a button that arms a different value.
        await store.setPending(.starsPerUsd, menuMessageID: 10, chatKey: chat)
        await store.notePendingInputOwner("#43", chatKey: chat)

        let owner = await store.pendingInputOwner(chatKey: chat)
        XCTAssertEqual(owner, "#43")
    }

    /// Re-arming a live wait (the menu redraws its own prompt) must not drop
    /// the owner: losing it would open the wait to the whole group.
    func testRearmingALiveWaitKeepsTheOwner() async {
        let store = Fixtures.makeStore()
        await store.setPending(.starsPrice, menuMessageID: 9, chatKey: chat)
        await store.notePendingInputOwner("#42", chatKey: chat)

        await store.setPending(.starsPrice, menuMessageID: 9, chatKey: chat)

        let owner = await store.pendingInputOwner(chatKey: chat)
        XCTAssertEqual(owner, "#42")
    }

    func testOwnerIsNotRememberedWithoutAWait() async {
        let store = Fixtures.makeStore()
        await store.notePendingInputOwner("#42", chatKey: chat)

        let owner = await store.pendingInputOwner(chatKey: chat)
        XCTAssertNil(owner, "an owner without a wait is a stale entry waiting to misfire")
    }
}
