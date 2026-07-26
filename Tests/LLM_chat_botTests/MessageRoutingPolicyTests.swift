import XCTest
@testable import LLM_chat_bot

/// In a group the bot answers only when addressed; in a DM it always answers.
final class MessageRoutingPolicyTests: XCTestCase {

    private let bot = "testbot"

    private func evaluate(_ message: TelegramMessage) -> MessageRoutingPolicy {
        MessageRoutingPolicy.evaluate(message: message, botUsername: bot)
    }

    func testPrivateChatAlwaysHandled() {
        let policy = evaluate(Fixtures.message(text: "привет", chat: Fixtures.chat(id: 5)))
        XCTAssertTrue(policy.shouldHandle)
        XCTAssertEqual(policy.normalizedText, "привет")
    }

    func testGroupMessageWithoutMentionIsIgnored() {
        let policy = evaluate(Fixtures.message(text: "болтаем", chat: Fixtures.chat(id: -5, type: "supergroup")))
        XCTAssertFalse(policy.shouldHandle)
    }

    func testGroupMentionIsHandledAndStripped() {
        let policy = evaluate(
            Fixtures.message(text: "@testbot что там по погоде", chat: Fixtures.chat(id: -5, type: "group"))
        )
        XCTAssertTrue(policy.shouldHandle)
        XCTAssertTrue(policy.mentionsBot)
        XCTAssertEqual(policy.normalizedText, "что там по погоде")
    }

    func testMentionIsCaseInsensitive() {
        let policy = evaluate(
            Fixtures.message(text: "@TestBot привет", chat: Fixtures.chat(id: -5, type: "group"))
        )
        XCTAssertTrue(policy.shouldHandle)
    }

    func testReplyToBotIsHandledWithoutMention() {
        let botMessage = Fixtures.message(
            id: 7,
            text: "предыдущий ответ",
            from: TelegramUser(id: 42, is_bot: true, first_name: "Bot", username: bot),
            chat: Fixtures.chat(id: -5, type: "group")
        )
        let policy = evaluate(
            Fixtures.message(text: "а подробнее?", chat: Fixtures.chat(id: -5, type: "group"), replyTo: botMessage)
        )
        XCTAssertTrue(policy.shouldHandle)
        XCTAssertTrue(policy.isReplyToBot)
        XCTAssertEqual(policy.normalizedText, "а подробнее?")
    }

    func testReplyToSomeoneElseIsIgnored() {
        let other = Fixtures.message(
            id: 7,
            text: "чужое сообщение",
            from: Fixtures.user(id: 43, username: "someone"),
            chat: Fixtures.chat(id: -5, type: "group")
        )
        let policy = evaluate(
            Fixtures.message(text: "ага", chat: Fixtures.chat(id: -5, type: "group"), replyTo: other)
        )
        XCTAssertFalse(policy.shouldHandle)
    }

    func testCaptionCountsAsText() {
        let policy = evaluate(
            Fixtures.message(caption: "@testbot опиши фото", chat: Fixtures.chat(id: -5, type: "group"))
        )
        XCTAssertTrue(policy.shouldHandle)
        XCTAssertEqual(policy.normalizedText, "опиши фото")
    }

    func testMentionOnlyMessageHasNoTextLeft() {
        let policy = evaluate(
            Fixtures.message(text: "@testbot", chat: Fixtures.chat(id: -5, type: "group"))
        )
        XCTAssertTrue(policy.shouldHandle)
        XCTAssertNil(policy.normalizedText)
    }

    func testBlankTextIsNormalizedToNil() {
        let policy = evaluate(Fixtures.message(text: "   ", chat: Fixtures.chat(id: 5)))
        XCTAssertTrue(policy.shouldHandle)
        XCTAssertNil(policy.normalizedText)
    }
}
