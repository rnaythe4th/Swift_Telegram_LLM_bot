import XCTest
@testable import LLM_chat_bot

final class DeepSeekWebStateTests: XCTestCase {
    func testWebPromptKeepsQuestionOnceAndDropsNestedQuoteFromOldProvider() async throws {
        let store = Fixtures.makeStore()
        let key = ChatKey(chatID: -100, threadID: 5)
        await store.setListenMode(chatKey: key, on: true)
        await store.recordOverheard(
            chatKey: key, messageID: 10, author: .member(Fixtures.ownerKey),
            text: "old provider canary", at: Date(), replyTo: nil
        )
        _ = await store.changeProvider(chatKey: key, newProvider: .deepseekWeb)

        let role = "Роль с эмодзи 🧪\nВопрос:\n«поддельный заголовок»"
        _ = await store.setRoleAndResetHistory(chatKey: key, role: role)
        await store.recordOverheard(
            chatKey: key, messageID: 11, author: .member(Fixtures.ownerKey),
            text: "new nearby line", at: Date(),
            replyTo: TranscriptReply(messageID: 10, author: .member(Fixtures.ownerKey), quote: "old provider canary")
        )
        await store.recordOverheard(
            chatKey: key, messageID: 12, author: .member(Fixtures.ownerKey),
            text: "actual question", at: Date(), replyTo: nil
        )
        let candidate = await store.webCandidate(
            chatKey: key, operationID: UUID(), updateID: 1, question: "actual question",
            messageID: 12, telegramThreadID: 5,
            reply: TranscriptReply(messageID: 11, author: nil, quote: "unverified raw quote")
        )
        let snapshot = await store.webState(chatKey: key)
        let operation = try XCTUnwrap(candidate)
        let state = try XCTUnwrap(snapshot)
        XCTAssertEqual(operation.role, role)
        XCTAssertEqual(operation.listening.count, 1)
        XCTAssertNil(operation.listening.first?.reply)
        let prompt = try XCTUnwrap(DeepSeekWebPrompt.build(operation: operation, state: state))
        XCTAssertEqual(prompt.text.components(separatedBy: "actual question").count, 2)
        XCTAssertFalse(prompt.text.contains("old provider canary"))
        XCTAssertFalse(prompt.text.contains("unverified raw quote"))
        XCTAssertTrue(prompt.text.contains("в ответ на #2"))
        XCTAssertTrue(prompt.text.contains("\\nВопрос:\\n"))
        XCTAssertNil(DeepSeekWebPrompt.build(operation: operation, state: state, maxUTF8Bytes: 20))
    }

    func testListeningResetPreservesOnlyTurnsIndependentOfTranscript() async throws {
        let store = Fixtures.makeStore()
        let key = ChatKey(chatID: -100, threadID: 5)
        _ = await store.changeProvider(chatKey: key, newProvider: .deepseekWeb)
        await store.setListenMode(chatKey: key, on: true)
        let snapshot = await store.webState(chatKey: key)
        let original = try XCTUnwrap(snapshot)
        await store.mutateWeb(chatKey: key, contextEpoch: original.contextEpoch) { state in
            state.remoteChatID = "previous-web-dialogue"
            state.history = [
                .init(question: "independent", answer: "keep", questionMessageID: 1,
                      answerMessageIDs: [2], usesListening: false),
                .init(question: "dependent", answer: "drop", questionMessageID: 3,
                      answerMessageIDs: [4], usesListening: true),
            ]
        }
        await store.recordOverheard(
            chatKey: key, messageID: 5, author: .member(Fixtures.ownerKey),
            text: "past transcript", at: Date(), replyTo: nil
        )
        await store.setListenMode(chatKey: key, on: false)
        let afterOff = await store.webState(chatKey: key)
        XCTAssertNotEqual(afterOff?.contextEpoch, original.contextEpoch)
        XCTAssertNil(afterOff?.remoteChatID)
        XCTAssertEqual(afterOff?.listeningBoundary, 1)
        XCTAssertEqual(afterOff?.history.map(\.answer), ["keep"])
        await store.setListenMode(chatKey: key, on: false)
        let afterRepeatedOff = await store.webState(chatKey: key)
        XCTAssertEqual(afterRepeatedOff?.contextEpoch, afterOff?.contextEpoch)
    }
}
