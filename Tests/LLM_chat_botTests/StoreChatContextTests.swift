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

    /// A turn that finished while an earlier one is still generating has an
    /// answer — and the next question must be asked with it. Sending the
    /// question without the answer is how the bot ends up answering it twice.
    func testAnAnswerWaitingOnAnEarlierTurnIsStillPartOfTheConversation() async {
        let store = Fixtures.makeStore()
        let first = GenerationID()
        let second = GenerationID()
        let third = GenerationID()

        _ = await store.snapshotAndAppend(chatKey: chat, generationID: first, content: input("первый"), username: nil)
        _ = await store.snapshotAndAppend(chatKey: chat, generationID: second, content: input("второй"), username: nil)
        // The second answer cannot be written to history yet — the first turn
        // still holds the queue — but it happened.
        _ = await store.appendAssistant(chatKey: chat, generationID: second, content: "ответ 2")

        let snapshot = await store.snapshotAndAppend(chatKey: chat, generationID: third, content: input("третий"), username: nil)
        XCTAssertEqual(snapshot.messages.map(\.role), ["system", "user", "user", "assistant", "user"])
        XCTAssertEqual(plainText(snapshot.messages[3]), "ответ 2")
        XCTAssertEqual(plainText(snapshot.messages.last), "третий")
    }

    /// The person took the question back — the model must not be asked it.
    func testACancelledTurnIsNotSentToTheModel() async {
        let store = Fixtures.makeStore()
        let blocking = GenerationID()
        let withdrawn = GenerationID()
        let next = GenerationID()

        _ = await store.snapshotAndAppend(chatKey: chat, generationID: blocking, content: input("держит очередь"), username: nil)
        _ = await store.snapshotAndAppend(chatKey: chat, generationID: withdrawn, content: input("снятый вопрос"), username: nil)
        await store.cancelPendingTurn(chatKey: chat, generationID: withdrawn)

        let snapshot = await store.snapshotAndAppend(chatKey: chat, generationID: next, content: input("новый"), username: nil)
        XCTAssertFalse(snapshot.messages.contains { plainText($0) == "снятый вопрос" })
    }

    /// The message count is not a size limit: one runaway answer is re-sent on
    /// every turn and rewritten into the row on every flush.
    func testHistoryStaysInsideItsByteBudget() async {
        let store = Fixtures.makeStore()
        await store.setMaxHistory(chatKey: chat, newMax: 50)
        let huge = String(repeating: "я", count: 60_000) // 120 000 bytes each

        for index in 0..<6 {
            let generation = GenerationID()
            _ = await store.snapshotAndAppend(chatKey: chat, generationID: generation, content: input("q\(index)"), username: nil)
            _ = await store.appendAssistant(chatKey: chat, generationID: generation, content: huge)
        }

        let generation = GenerationID()
        let snapshot = await store.snapshotAndAppend(chatKey: chat, generationID: generation, content: input("последний"), username: nil)
        let carried = snapshot.messages.dropFirst().reduce(0) { $0 + $1.byteCount }
        XCTAssertLessThanOrEqual(carried, ChatContext.historyByteBudget)
        XCTAssertEqual(snapshot.messages.first?.role, "system", "the role is never the message dropped")
        XCTAssertEqual(plainText(snapshot.messages.last), "последний", "the question being asked always survives")
    }

    /// The newest message survives whatever it weighs — a request without the
    /// question is not the conversation at all.
    func testTheQuestionSurvivesEvenWhenItAloneOverflowsTheBudget() async {
        let store = Fixtures.makeStore()
        let oversized = String(repeating: "x", count: ChatContext.historyByteBudget + 1_000)
        let generation = GenerationID()

        let snapshot = await store.snapshotAndAppend(chatKey: chat, generationID: generation, content: input(oversized), username: nil)
        XCTAssertEqual(snapshot.messages.count, 2)
        XCTAssertEqual(plainText(snapshot.messages.last), oversized)
    }

    /// Memory length multiplies the cost of every answer, so the bound is the
    /// domain's — not something each of the four call sites re-types.
    func testMemoryLengthIsClampedByTheDomain() async {
        let store = Fixtures.makeStore()
        await store.setMaxHistory(chatKey: chat, newMax: 100_000)
        var help = await store.fetchHelp(chatKey: chat)
        XCTAssertEqual(help.maxHistory, ChatContext.historyRange.upperBound)

        await store.setMaxHistory(chatKey: chat, newMax: 0)
        help = await store.fetchHelp(chatKey: chat)
        XCTAssertEqual(help.maxHistory, ChatContext.historyRange.lowerBound)
    }

    /// The answer was generated and the money is being taken; a `/clear_history`
    /// that landed mid-stream must not leave the chat's own totals short of what
    /// the tenant and the daily spend already counted.
    func testUsageIsCountedEvenWhenTheTurnWasDroppedMidStream() async {
        let store = Fixtures.makeStore()
        let generation = GenerationID()
        _ = await store.snapshotAndAppend(chatKey: chat, generationID: generation, content: input("q"), username: nil)
        await store.clearHistory(chatKey: chat)

        let cost = await store.appendAssistant(
            chatKey: chat, generationID: generation, content: "a",
            usage: usage(cost: 1, tokens: 15)
        )
        XCTAssertEqual(cost.real, .usd(1), "the caller charges this — it is real spend")

        let help = await store.fetchHelp(chatKey: chat)
        XCTAssertEqual(help.cumulativeUsage.generationCount, 1)
        XCTAssertEqual(help.cumulativeUsage.totalCost, .usd(1))
        let history = await store.history(chatKey: chat)
        XCTAssertEqual(history.count, 1, "the answer has nowhere to go, and that part is fine")
    }

    /// "↺ Сбросить" resets settings. What the chat accumulated — its totals,
    /// its presets, the funnel's activation flag, the ad throttle — is not a
    /// setting, and a button anyone can tap must not move the numbers.
    func testResetKeepsWhatTheChatAccumulated() async {
        let store = Fixtures.makeStore()
        let generation = GenerationID()
        _ = await store.snapshotAndAppend(chatKey: chat, generationID: generation, content: input("q"), username: nil)
        _ = await store.appendAssistant(chatKey: chat, generationID: generation, content: "a", usage: usage(cost: 1, tokens: 10))
        await store.markFirstMessageIfNeeded(chatKey: chat)

        await store.resetChat(chatKey: chat)
        await store.markFirstMessageIfNeeded(chatKey: chat)

        let report = await store.funnelReport()
        XCTAssertEqual(report.counters[FunnelEvent.firstMessage.rawValue], 1, "one chat is one activation, however often it is reset")
        let help = await store.fetchHelp(chatKey: chat)
        XCTAssertEqual(help.cumulativeUsage.generationCount, 1)
    }

    /// Every write to a chat marks it dirty; a turn is a write like any other.
    func testStartingATurnMarksTheChatDirty() async {
        let store = Fixtures.makeStore()
        _ = await store.drainDirtyBatch()

        _ = await store.snapshotAndAppend(chatKey: chat, generationID: GenerationID(), content: input("q"), username: nil)

        let batch = await store.drainDirtyBatch()
        XCTAssertTrue(batch.contexts.contains { $0.key == chat })
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
