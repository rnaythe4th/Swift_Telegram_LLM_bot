import XCTest
@testable import LLM_chat_bot

/// A group upgraded to a supergroup keeps its people, its history and whoever
/// pays for it — but gets a brand-new `chat_id`, which every one of those is
/// keyed by. Telegram announces the upgrade once and never again.
final class StoreChatMigrationTests: XCTestCase {

    private let oldChat: ChatID = -4_400
    private let newChat: ChatID = -1_009_876_543_210
    private let sponsor: UserID = 5_500

    private func makeSponsoredGroup() async -> ChatContextStore {
        let store = Fixtures.makeStore()
        await store.identifyUser(userID: sponsor, username: "payer", firstName: "Payer")
        await store.activatePaidSubscription(Fixtures.key(sponsor), days: 30)
        await store.assignChat(chatID: oldChat, to: Fixtures.key(sponsor))
        await store.recordChatMeta(
            chatID: oldChat,
            info: ChatMetaInfo(type: "group", title: "Наш чат", username: nil, firstName: nil)
        )
        return store
    }

    /// The licence somebody bought is pinned to a chat id. Left behind, the
    /// upgraded group is a free chat that the next speaker may claim for a
    /// different tenant — while the sponsor keeps paying for an id that no
    /// longer receives anything.
    func testTheGroupKeepsThePersonPayingForIt() async {
        let store = await makeSponsoredGroup()

        let moved = await store.migrateChat(from: oldChat, to: newChat)

        XCTAssertTrue(moved)
        let covered = await store.hasSubscriptionCoverage(key: nil, userID: nil, chatID: newChat)
        XCTAssertTrue(covered, "the supergroup is covered by the same subscription")
        let orphaned = await store.hasSubscriptionCoverage(key: nil, userID: nil, chatID: oldChat)
        XCTAssertFalse(orphaned, "the id that no longer exists keeps nothing")
    }

    func testTheConversationAndTheSettingsFollowTheChat() async {
        let store = await makeSponsoredGroup()
        let oldKey = ChatKey(chatID: oldChat, threadID: 0)
        let newKey = ChatKey(chatID: newChat, threadID: 0)
        let generation = GenerationID()
        _ = await store.snapshotAndAppend(chatKey: oldKey, generationID: generation, content: UserInputContent(text: "вопрос"), username: "payer")
        _ = await store.appendAssistant(chatKey: oldKey, generationID: generation, content: "ответ")
        _ = await store.addChatPreset(category: .role, chatKey: oldKey, display: "Физик", value: "ты физик")

        _ = await store.migrateChat(from: oldChat, to: newChat)

        let history = await store.history(chatKey: newKey)
        XCTAssertEqual(history.count, 3, "system + the question + the answer")
        let presets = await store.chatPresets(category: .role, chatKey: newKey)
        XCTAssertEqual(presets.map(\.value), ["ты физик"])
        let leftBehind = await store.history(chatKey: oldKey)
        XCTAssertEqual(leftBehind.count, 1, "the old id starts from a bare system message")
    }

    /// Both halves of the move have to reach storage: the new row written and
    /// the old one deleted. A dirty-only move leaves two chats in the database,
    /// and the next restore brings the orphan back.
    func testTheMoveIsWrittenAndTheOldRowDeleted() async {
        let store = await makeSponsoredGroup()
        let oldKey = ChatKey(chatID: oldChat, threadID: 0)
        _ = await store.ensure(chatKey: oldKey)
        _ = await store.drainDirtyBatch()

        _ = await store.migrateChat(from: oldChat, to: newChat)
        let batch = await store.drainDirtyBatch()

        XCTAssertTrue(batch.chats.contains { $0.chatID == newChat })
        XCTAssertTrue(batch.deletedChats.contains(oldChat))
        XCTAssertTrue(batch.contexts.contains { $0.key.chatID == newChat })
        XCTAssertTrue(batch.deletedContexts.contains { $0.chatID == oldChat })
    }

    /// Updates from the supergroup can arrive before the announcement does, and
    /// what the supergroup itself said is the newer truth.
    func testStateAlreadyUnderTheNewIDIsNotOverwritten() async {
        let store = await makeSponsoredGroup()
        let newKey = ChatKey(chatID: newChat, threadID: 0)
        _ = await store.setRoleAndResetHistory(chatKey: newKey, role: "уже-новая-роль")

        _ = await store.migrateChat(from: oldChat, to: newChat)

        let role = await store.fetchHelp(chatKey: newKey).role
        XCTAssertEqual(role, "уже-новая-роль")
    }

    func testAChatWithNothingStoredIsNotAMigration() async {
        let store = Fixtures.makeStore()
        let moved = await store.migrateChat(from: -1, to: -2)
        XCTAssertFalse(moved)
    }
}
