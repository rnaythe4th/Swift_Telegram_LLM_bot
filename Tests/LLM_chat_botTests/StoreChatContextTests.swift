import XCTest
@testable import LLM_chat_bot

/// One chat's memory: pending turns keep parallel questions in order, the
/// system message is never trimmed away, and a model parked by the daily cap
/// comes back on its own.
final class StoreChatContextTests: XCTestCase {

    private let chat = ChatKey(chatID: 900, threadID: 0)

    private func input(_ text: String) -> UserInputContent {
        UserInputContent(text: text)
    }

    private func plainText(_ message: ChatMessage?) -> String? {
        guard case .text(let value) = message?.content else { return nil }
        return value
    }

    private func usage(cost: Double, tokens: Double) -> StreamUsageSummary {
        StreamUsageSummary(
            promptTokens: nil, completionTokens: nil, totalTokens: tokens,
            cacheHitTokens: nil, cacheWriteTokens: nil, cacheMissTokens: nil,
            reasoningTokens: nil, cost: cost
        )
    }

    func testAnswerIsAppendedAsAUserAssistantPair() async {
        let store = Fixtures.makeStore()
        let generation = GenerationID()

        _ = await store.snapshotAndAppend(chatKey: chat, generationID: generation, content: input("вопрос"), username: "alice")
        // Until the turn resolves the question is pending, not history.
        var history = await store.history(chatKey: chat)
        XCTAssertEqual(history.count, 1, "only the system message so far")

        _ = await store.appendAssistant(chatKey: chat, generationID: generation, content: "ответ")
        history = await store.history(chatKey: chat)
        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history.last?.role, "assistant")
    }

    /// Two questions asked while the first is still generating must land in the
    /// order they were asked.
    func testParallelTurnsKeepTheirOrder() async {
        let store = Fixtures.makeStore()
        let first = GenerationID()
        let second = GenerationID()

        _ = await store.snapshotAndAppend(chatKey: chat, generationID: first, content: input("первый"), username: nil)
        _ = await store.snapshotAndAppend(chatKey: chat, generationID: second, content: input("второй"), username: nil)

        // The second finishes first; nothing may be written until the first does.
        _ = await store.appendAssistant(chatKey: chat, generationID: second, content: "ответ 2")
        var history = await store.history(chatKey: chat)
        XCTAssertEqual(history.count, 1)

        _ = await store.appendAssistant(chatKey: chat, generationID: first, content: "ответ 1")
        history = await store.history(chatKey: chat)
        XCTAssertEqual(history.map(\.role), ["system", "user", "assistant", "user", "assistant"])
        XCTAssertEqual(plainText(history[2]), "ответ 1")
        XCTAssertEqual(plainText(history[4]), "ответ 2")
    }

    func testCancelledTurnLeavesNoTrace() async {
        let store = Fixtures.makeStore()
        let generation = GenerationID()
        _ = await store.snapshotAndAppend(chatKey: chat, generationID: generation, content: input("вопрос"), username: nil)
        await store.cancelPendingTurn(chatKey: chat, generationID: generation)

        let history = await store.history(chatKey: chat)
        XCTAssertEqual(history.count, 1)
    }

    func testUsageAccumulatesWithMarkup() async {
        let store = Fixtures.makeStore()
        await store.setMarkupPercent(30)
        let generation = GenerationID()
        _ = await store.snapshotAndAppend(chatKey: chat, generationID: generation, content: input("q"), username: nil)
        _ = await store.appendAssistant(
            chatKey: chat, generationID: generation, content: "a",
            usage: usage(cost: 1, tokens: 15)
        )

        let help = await store.fetchHelp(chatKey: chat)
        XCTAssertEqual(help.cumulativeUsage.generationCount, 1)
        XCTAssertEqual(help.cumulativeUsage.totalCost, .usd(1))
        XCTAssertEqual(help.cumulativeUsage.totalBilledCost, .usd(1.3))
    }

    func testTrimmingKeepsTheSystemMessageFirst() async {
        let store = Fixtures.makeStore()
        await store.setMaxHistory(chatKey: chat, newMax: 2)
        for index in 0..<5 {
            let generation = GenerationID()
            _ = await store.snapshotAndAppend(chatKey: chat, generationID: generation, content: input("q\(index)"), username: nil)
            _ = await store.appendAssistant(chatKey: chat, generationID: generation, content: "a\(index)")
        }

        let history = await store.history(chatKey: chat)
        XCTAssertEqual(history.first?.role, "system")
        XCTAssertLessThanOrEqual(history.count, 6)
        XCTAssertEqual(plainText(history.last), "a4")
    }

    func testClearHistoryKeepsTheRole() async {
        let store = Fixtures.makeStore()
        let generation = GenerationID()
        _ = await store.snapshotAndAppend(chatKey: chat, generationID: generation, content: input("q"), username: nil)
        _ = await store.appendAssistant(chatKey: chat, generationID: generation, content: "a")
        await store.clearHistory(chatKey: chat)

        let history = await store.history(chatKey: chat)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.role, "system")
    }

    /// A model parked by the daily cap must come back by itself once access
    /// appears — otherwise paying looks like nothing happened.
    func testDowngradedModelIsRestorable() async {
        let store = Fixtures.makeStore()
        await store.setModelOnly(chatKey: chat, model: "paid/model")
        await store.downgradeModelToFree(chatKey: chat, freeModel: "free/model")

        var help = await store.fetchHelp(chatKey: chat)
        XCTAssertEqual(help.model, "free/model")

        let restored = await store.restoreDowngradedModel(chatKey: chat)
        XCTAssertEqual(restored, "paid/model")
        help = await store.fetchHelp(chatKey: chat)
        XCTAssertEqual(help.model, "paid/model")

        let again = await store.restoreDowngradedModel(chatKey: chat)
        XCTAssertNil(again, "nothing is parked any more")
    }

    /// Choosing a model by hand is a decision — it clears the parked one.
    func testExplicitChoiceForgetsTheParkedModel() async {
        let store = Fixtures.makeStore()
        await store.setModelOnly(chatKey: chat, model: "paid/model")
        await store.downgradeModelToFree(chatKey: chat, freeModel: "free/model")
        await store.setModelOnly(chatKey: chat, model: "other/model")

        let restored = await store.restoreDowngradedModel(chatKey: chat)
        XCTAssertNil(restored)
    }

    /// Forum topics are separate conversations.
    func testThreadsAreSeparateContexts() async {
        let store = Fixtures.makeStore()
        let main = ChatKey(chatID: 901, threadID: 0)
        let topic = ChatKey(chatID: 901, threadID: 7)
        await store.setModelOnly(chatKey: main, model: "a/model")
        await store.setModelOnly(chatKey: topic, model: "b/model")

        let mainHelp = await store.fetchHelp(chatKey: main)
        let topicHelp = await store.fetchHelp(chatKey: topic)
        XCTAssertEqual(mainHelp.model, "a/model")
        XCTAssertEqual(topicHelp.model, "b/model")
    }

    /// Looking at a chat must not create one (and must not mark it dirty).
    func testPeekNeverCreatesAContext() async {
        let store = Fixtures.makeStore()
        let unseen = ChatKey(chatID: 902, threadID: 0)
        let peeked = await store.peekHelp(chatKey: unseen)
        XCTAssertNil(peeked)

        let batch = await store.drainDirtyBatch()
        XCTAssertFalse(batch.contexts.contains { $0.key == unseen })
    }
}
