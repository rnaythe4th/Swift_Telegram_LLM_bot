import XCTest
@testable import LLM_chat_bot

// The Bot API boundary, exercised through the real `TelegramHTTPGateway`
// against a local stand-in. What is under test is the gateway's own contract —
// what it measures before sending, and which of Telegram's refusals are actual
// failures — not the wiring above it.

final class TelegramGatewayTests: XCTestCase {
    private var telegram: FakeTelegram!
    private var gateway: TelegramHTTPGateway!
    private let chatID = ChatID(4_242)

    override func setUp() async throws {
        telegram = FakeTelegram()
        let baseURL = try await telegram.start()
        gateway = TelegramHTTPGateway(
            network: NetworkClient(),
            botToken: "test-token",
            apiBase: baseURL,
            rateLimiter: nil,
            metrics: nil
        )
    }

    override func tearDown() async throws {
        await telegram.stop()
        telegram = nil
        gateway = nil
    }

    // MARK: - Length is measured in what Telegram counts

    /// An answer made of emoji is twice as long to Telegram as it is in
    /// `Character`s, and a family emoji is eleven times as long. Deciding
    /// "does this fit in one message" by counting characters therefore sent
    /// 6 000 code units in one call and lost the whole answer to a 400.
    func testAnEmojiAnswerIsSplitByWhatTelegramCounts() async throws {
        let text = String(repeating: "🙂", count: 3_000)
        XCTAssertLessThanOrEqual(text.count, MessageSplitter.charLimit, "the premise: it looks short enough")
        XCTAssertGreaterThan(text.utf16.count, MessageSplitter.telegramMaxChars, "the premise: it is not")

        _ = try await gateway.sendMessage(
            .init(chatID: chatID, threadID: nil, replyTo: nil, text: text, replyMarkup: nil)
        )

        let calls = await telegram.calls("sendMessage")
        XCTAssertGreaterThan(calls.count, 1, "an answer over the limit must be split, not sent whole")
        for call in calls {
            XCTAssertLessThanOrEqual(
                call.text?.utf16.count ?? 0,
                MessageSplitter.telegramMaxChars,
                "every part has to fit what Telegram measures"
            )
        }
    }

    /// The other side of the same rule: a plain answer that fits must still go
    /// out as one message, footer reserve and all.
    func testAPlainAnswerThatFitsStaysOneMessage() async throws {
        let text = String(repeating: "a", count: MessageSplitter.telegramMaxChars - 1)

        _ = try await gateway.sendMessage(
            .init(chatID: chatID, threadID: nil, replyTo: nil, text: text, replyMarkup: nil)
        )

        let calls = await telegram.calls("sendMessage")
        XCTAssertEqual(calls.count, 1)
    }

    // MARK: - Which refusals are failures

    /// «message is not modified» says the message already reads exactly this —
    /// the caller's postcondition holds. Reporting it as an error threw away
    /// whole answers: the streaming loop rethrows anything that is not a rate
    /// limit, and the handler above replaces the placeholder with an error
    /// message, discarding everything streamed so far. Telegram strips trailing
    /// whitespace before comparing, so a chunk of two newlines arriving after a
    /// pause is enough to reach it.
    func testAnEditThatChangesNothingIsNotAFailure() async throws {
        await telegram.refuse(
            "editMessageText",
            containing: "уже написано",
            description: "Bad Request: message is not modified"
        )

        try await gateway.editMessage(
            .init(chatID: chatID, messageID: 7, text: "уже написано", replyMarkup: nil)
        )
    }

    /// …and every other refusal still is one: swallowing them all would hide a
    /// deleted placeholder or a chat the bot was thrown out of.
    func testAnEditTelegramRefusesForAnyOtherReasonStillThrows() async {
        await telegram.refuse(
            "editMessageText",
            containing: "исчезло",
            description: "Bad Request: message to edit not found"
        )

        do {
            try await gateway.editMessage(
                .init(chatID: chatID, messageID: 7, text: "исчезло", replyMarkup: nil)
            )
            XCTFail("a message that no longer exists is a failure the caller has to see")
        } catch let error as TelegramAPIError {
            XCTAssertFalse(error.isEditWithNothingToChange)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
