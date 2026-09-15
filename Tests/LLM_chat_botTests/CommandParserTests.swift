import XCTest
@testable import LLM_chat_bot

/// Command parsing decides what runs before the access gate, so `/buying` must
/// never be read as `/buy`.
final class CommandParserTests: XCTestCase {

    private func parse(_ text: String, bot: String = "testbot", suffix: Int? = nil) -> ParsedBotCommand {
        ParsedBotCommand.parse(from: text, botUsername: bot, suffix: suffix)
    }

    func testPlainCommand() {
        let parsed = parse("/model")
        XCTAssertEqual(parsed.name, .model)
        XCTAssertEqual(parsed.argument, "")
    }

    func testArgumentIsEverythingAfterTheFirstSpace() {
        let parsed = parse("/setrole ты кот  и это важно")
        XCTAssertEqual(parsed.name, .setRole)
        XCTAssertEqual(parsed.argument, "ты кот  и это важно")
    }

    func testCommandAddressedToThisBot() {
        XCTAssertEqual(parse("/menu@testbot").name, .menu)
        XCTAssertEqual(parse("/MENU@TestBot").name, .menu)
    }

    func testCommandAddressedToAnotherBotIsIgnored() {
        XCTAssertEqual(parse("/menu@otherbot").name, .unknown)
    }

    func testPrefixOfAKnownCommandIsNotThatCommand() {
        XCTAssertEqual(parse("/buying").name, .unknown)
        XCTAssertEqual(parse("/startsomething").name, .unknown)
        XCTAssertEqual(parse("/models").name, .unknown)
    }

    func testTestModeSuffix() {
        XCTAssertEqual(parse("/model3", suffix: 3).name, .model)
        // With a suffix configured, the bare command is no longer this instance's.
        XCTAssertEqual(parse("/model", suffix: 3).name, .unknown)
        // Addressing the bot explicitly bypasses the suffix.
        XCTAssertEqual(parse("/model@testbot", suffix: 3).name, .model)
    }

    func testMentionWithoutSlash() {
        XCTAssertEqual(parse("@testbot привет").name, .mention)
    }

    func testNonCommandTextIsUnknown() {
        XCTAssertEqual(parse("привет").name, .unknown)
        XCTAssertEqual(parse("").name, .unknown)
    }

    func testLeadingWhitespaceIsTolerated() {
        XCTAssertEqual(parse("   /help").name, .help)
    }

    /// A newline separates a command from its argument as naturally as a space:
    /// a long role is written on the lines below `/setrole`, and reading that as
    /// one unknown token sent the whole thing to the model as a question.
    func testANewlineSeparatesTheCommandFromItsArgument() {
        let parsed = parse("/setrole\nТы — эксперт.\nОтвечай кратко.")
        XCTAssertEqual(parsed.name, .setRole)
        XCTAssertEqual(parsed.argument, "Ты — эксперт.\nОтвечай кратко.")

        // The suffix and the @-form survive the same treatment.
        XCTAssertEqual(parse("/model3\nopenai/gpt-4o", suffix: 3).name, .model)
        XCTAssertEqual(parse("/setrole@testbot\nкот").argument, "кот")
    }

    /// Addressing the bot by name waives the test-mode suffix, and Telegram does
    /// not promise the case the owner registered the name in.
    func testAddressingTheBotWaivesTheSuffixWhateverTheCase() {
        XCTAssertEqual(parse("/model@TestBot", suffix: 3).name, .model)
        XCTAssertEqual(parse("/model@TESTBOT", suffix: 3).name, .model)
    }

    func testEveryCommandNameResolvesFromItsOwnSpelling() {
        // Guards against two commands claiming the same token after an edit.
        var seen = Set<String>()
        for name in BotCommandName.allCases where name != .unknown && name != .mention {
            let mirror = "\(name)"
            XCTAssertTrue(seen.insert(mirror).inserted, "duplicate case \(mirror)")
        }
        XCTAssertEqual(parse("/ref").name, .referral)
        XCTAssertEqual(parse("/clear_history").name, .clearHistory)
        XCTAssertEqual(parse("/backup_notify").name, .backupNotify)
    }
}
