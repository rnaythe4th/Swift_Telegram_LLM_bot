import XCTest
@testable import LLM_chat_bot

final class DeepSeekWebStateTests: XCTestCase {
    func testWebDefaultMigratesStoredChatsAndKeepsLaterProviderChoices() async throws {
        let original = Fixtures.makeStore()
        let dm = ChatKey(chatID: 100, threadID: 0)
        let topic = ChatKey(chatID: -100, threadID: 5)
        await original.setReasoningEffort(chatKey: dm, effort: .high)
        await original.setTemperature(chatKey: dm, value: 0.5)
        let generation = GenerationID()
        _ = await original.snapshotAndAppend(chatKey: dm, generationID: generation,
                                             content: .init(text: "old question", attachments: []), username: nil)
        _ = await original.appendAssistant(chatKey: dm, generationID: generation, content: "old answer")
        _ = await original.fetchHelp(chatKey: topic)

        var saved = PersistedBotState()
        saved.contexts = await original.drainDirtyBatch().contexts
        let store = Fixtures.makeStore(defaultProvider: .deepseekWeb)
        await store.restore(from: saved)

        let migrated = await store.drainDirtyBatch().contexts
        XCTAssertEqual(Set(migrated.map(\.key)), [dm, topic])
        XCTAssertTrue(migrated.allSatisfy { $0.snapshot.webSelected == true && $0.snapshot.deepSeekWeb != nil })
        let fresh = await store.provider(chatKey: ChatKey(chatID: 101, threadID: 0))
        XCTAssertEqual(fresh, .deepseekWeb)

        _ = await store.changeProvider(chatKey: dm, newProvider: .openrouter)
        let api = await store.fetchHelp(chatKey: dm)
        let history = await store.history(chatKey: dm)
        XCTAssertEqual(api.reasoningEffort, .high)
        XCTAssertEqual(api.temp, 0.5)
        XCTAssertEqual(history.map(\.role), ["system", "user", "assistant"])

        let updated = await store.drainDirtyBatch().contexts
        let choice = try XCTUnwrap(updated.first { $0.key == dm })
        XCTAssertEqual(choice.snapshot.webSelected, false)
        saved.contexts = [choice] + migrated.filter { $0.key != dm }
        let restarted = Fixtures.makeStore(defaultProvider: .deepseekWeb)
        await restarted.restore(from: saved)
        let selected = await restarted.provider(chatKey: dm)
        let groupProvider = await restarted.provider(chatKey: topic)
        XCTAssertEqual(selected, .openrouter)
        XCTAssertEqual(groupProvider, .deepseekWeb)
    }

    func testWebDefaultAcceptsGroupQuestionsBeforeSharingListeningBuffer() async throws {
        let store = Fixtures.makeStore(defaultProvider: .deepseekWeb)
        let topic = ChatKey(chatID: -100, threadID: 5)
        await store.setListenMode(chatKey: topic, on: true)
        _ = await store.changeProvider(chatKey: topic, newProvider: .deepseekWeb)
        await store.recordOverheard(chatKey: topic, messageID: 10, author: .member(Fixtures.ownerKey),
                                    text: "before approval", at: Date(), replyTo: nil)
        let first = await store.webCandidate(
            chatKey: topic, operationID: UUID(), updateID: 1, question: "a question",
            messageID: 11, telegramThreadID: 5,
            reply: TranscriptReply(messageID: 10, author: .member(Fixtures.ownerKey), quote: "before approval")
        )
        let operation = try XCTUnwrap(first)
        XCTAssertTrue(operation.listening.isEmpty)
        XCTAssertNil(operation.reply)

        await store.allowWebListening(chatKey: topic)
        await store.recordOverheard(chatKey: topic, messageID: 12, author: .member(Fixtures.ownerKey),
                                    text: "after approval", at: Date(), replyTo: nil)
        let second = await store.webCandidate(
            chatKey: topic, operationID: UUID(), updateID: 2, question: "another question",
            messageID: 13, telegramThreadID: 5, reply: nil
        )
        XCTAssertEqual(second?.listening.map(\.text), ["after approval"])
    }

    func testSwitchingFromAPIToWebDoesNotApproveListening() async {
        let store = Fixtures.makeStore()
        let topic = ChatKey(chatID: -100, threadID: 5)
        await store.setListenMode(chatKey: topic, on: true)
        _ = await store.changeProvider(chatKey: topic, newProvider: .deepseekWeb)

        let listening = await store.listening(chatKey: topic)
        let sharingAllowed = await store.webListeningAllowed(chatKey: topic)
        XCTAssertTrue(listening.isOn)
        XCTAssertFalse(sharingAllowed)
    }

    func testDeepThinkIsSavedPerTopicAndCapturedWhenQueued() async throws {
        let store = Fixtures.makeStore()
        let key = ChatKey(chatID: -100, threadID: 5)
        let other = ChatKey(chatID: -100, threadID: 6)
        await store.setReasoningEffort(chatKey: key, effort: .high)
        _ = await store.changeProvider(chatKey: key, newProvider: .deepseekWeb)
        _ = await store.changeProvider(chatKey: other, newProvider: .deepseekWeb)

        let toggle = await store.setWebDeepThink(chatKey: key, enabled: nil)
        XCTAssertEqual(toggle, true, "An API grade leaves the Web default in effect")
        let candidate = await store.webCandidate(
            chatKey: key, operationID: UUID(), updateID: 1, question: "question",
            messageID: 10, telegramThreadID: 5, reply: nil
        )
        let operation = try XCTUnwrap(candidate)
        _ = await store.setWebDeepThink(chatKey: key, enabled: false)
        await store.clearHistory(chatKey: key)

        let policy = await store.webState(chatKey: key)
        let otherPolicy = await store.webState(chatKey: other)
        let originalEffort = await store.reasoningEffort(chatKey: key)
        XCTAssertEqual(policy?.deepThink, false)
        XCTAssertNil(otherPolicy?.deepThink)
        XCTAssertEqual(originalEffort, .high)

        let saved = try JSONEncoder().encode(operation)
        XCTAssertEqual(try JSONDecoder().decode(DeepSeekWebOperation.self, from: saved).deepThink, true)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        legacy.removeValue(forKey: "deepThink")
        let old = try JSONSerialization.data(withJSONObject: legacy)
        XCTAssertNil(try JSONDecoder().decode(DeepSeekWebOperation.self, from: old).deepThink)
    }

    func testWebSearchDefaultsOnAndPersistsPerTopic() async throws {
        let store = Fixtures.makeStore(defaultProvider: .deepseekWeb)
        let key = ChatKey(chatID: -100, threadID: 5)
        let other = ChatKey(chatID: -100, threadID: 6)
        let initial = await store.fetchHelp(chatKey: key)
        XCTAssertTrue(initial.webSearchEnabled)
        _ = await store.setWebSearch(chatKey: key, enabled: false)
        let candidate = await store.webCandidate(
            chatKey: key, operationID: UUID(), updateID: 1, question: "question",
            messageID: 10, telegramThreadID: 5, reply: nil
        )
        let operation = try XCTUnwrap(candidate)
        let data = try JSONEncoder().encode(operation)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "webSearch")
        let old = try JSONSerialization.data(withJSONObject: legacy)
        XCTAssertNil(try JSONDecoder().decode(DeepSeekWebOperation.self, from: old).webSearch)

        await store.clearHistory(chatKey: key)
        let rows = await store.drainDirtyBatch().contexts
        let row = try XCTUnwrap(rows.first { $0.key == key })
        let snapshot = try JSONDecoder().decode(ChatContextSnapshot.self, from: JSONEncoder().encode(row.snapshot))
        var saved = PersistedBotState()
        saved.contexts = [.init(key: key, snapshot: snapshot)]
        let restarted = Fixtures.makeStore(defaultProvider: .deepseekWeb)
        await restarted.restore(from: saved)
        let restored = await restarted.fetchHelp(chatKey: key)
        let otherTopic = await restarted.fetchHelp(chatKey: other)
        XCTAssertFalse(restored.webSearchEnabled)
        XCTAssertTrue(otherTopic.webSearchEnabled)

        _ = await restarted.setWebSearch(chatKey: key, enabled: true)
        XCTAssertEqual(try JSONDecoder().decode(DeepSeekWebOperation.self, from: data).webSearch, false)
        _ = await restarted.changeProvider(chatKey: key, newProvider: .openrouter)
        let stale = await restarted.setWebSearch(chatKey: key, enabled: false)
        XCTAssertFalse(stale)
        _ = await restarted.changeProvider(chatKey: key, newProvider: .deepseekWeb)
        let reselected = await restarted.fetchHelp(chatKey: key)
        XCTAssertTrue(reselected.webSearchEnabled)
    }

    func testWebPromptKeepsQuestionOnceAndDropsNestedQuoteFromOldProvider() async throws {
        let store = Fixtures.makeStore()
        let key = ChatKey(chatID: -100, threadID: 5)
        await store.setListenMode(chatKey: key, on: true)
        await store.recordOverheard(
            chatKey: key, messageID: 10, author: .member(Fixtures.ownerKey),
            text: "old provider canary", at: Date(), replyTo: nil
        )
        _ = await store.changeProvider(chatKey: key, newProvider: .deepseekWeb)
        await store.allowWebListening(chatKey: key)

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

    func testWebPromptSuggestsFormattingAndEmojiInNewAndExistingDialogs() async throws {
        let store = Fixtures.makeStore(defaultProvider: .deepseekWeb)
        let key = ChatKey(chatID: 100, threadID: 0)
        let role = "Отвечай спокойно"
        let question = "Как дела? 🐈"
        _ = await store.setRoleAndResetHistory(chatKey: key, role: role)
        let candidate = await store.webCandidate(
            chatKey: key, operationID: UUID(), updateID: 1, question: question,
            messageID: 1, telegramThreadID: nil, reply: nil
        )
        let snapshot = await store.webState(chatKey: key)
        let operation = try XCTUnwrap(candidate)
        let newDialog = try XCTUnwrap(snapshot)
        var existingDialog = newDialog
        existingDialog.remoteChatID = "existing-chat"

        let core = "Роль бота:\n\"\(role)\"\n\nВопрос:\n\"\(question)\""
        for state in [newDialog, existingDialog] {
            let prompt = try XCTUnwrap(DeepSeekWebPrompt.build(operation: operation, state: state))
            XCTAssertTrue(prompt.text.contains("Оформление ответа в Telegram:"))
            XCTAssertTrue(prompt.text.contains("Используй оформление умеренно"))
            XCTAssertTrue(prompt.text.contains("<tg-spoiler>"))
            XCTAssertTrue(prompt.text.contains("Добавляй обычные эмодзи"))
            XCTAssertTrue(prompt.text.contains("без <tg-emoji>"))
            XCTAssertTrue(prompt.text.hasSuffix("Вопрос:\n\"\(question)\""))

            let withTightBudget = try XCTUnwrap(DeepSeekWebPrompt.build(
                operation: operation, state: state, maxUTF8Bytes: core.utf8.count, maxUTF16Units: core.utf16.count
            ))
            XCTAssertEqual(withTightBudget.text, core)
        }
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
