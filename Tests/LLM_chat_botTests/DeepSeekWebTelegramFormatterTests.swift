import XCTest
@testable import LLM_chat_bot

final class DeepSeekWebTelegramFormatterTests: XCTestCase {
    func testTelegramHTMLUsesNativeEntities() throws {
        let source = """
        😀 <b><i><u><s>nested</s></u></i></b>
        <strong>strong</strong> <em>em</em> <ins>ins</ins> <strike>strike</strike> <del>del</del>
        <span class="tg-spoiler">hidden</span> <tg-spoiler>also hidden</tg-spoiler>
        <code>&lt;tg-emoji emoji-id="123"&gt;😀&lt;/tg-emoji&gt;</code>
        <pre>line 1
        line 2</pre>
        <pre><code class="language-python">print("hello")</code></pre>
        <a href="https://telegram.org/?a=1&amp;b=2">Telegram</a>
        <blockquote>quote</blockquote>
        <blockquote expandable>expand</blockquote>
        &lt; &gt; &amp; <tg-emoji emoji-id="123456789">😀</tg-emoji>
        """
        let part = try XCTUnwrap(DeepSeekWebTelegramFormatter.parts(source).only)
        let text = part.text as NSString
        let expected: [(String, String)] = [
            ("bold", "nested"), ("italic", "nested"), ("strikethrough", "nested"), ("underline", "nested"),
            ("bold", "strong"), ("italic", "em"), ("underline", "ins"), ("strikethrough", "strike"),
            ("strikethrough", "del"), ("spoiler", "hidden"), ("spoiler", "also hidden"),
            ("code", "<tg-emoji emoji-id=\"123\">😀</tg-emoji>"), ("pre", "line 1\nline 2"),
            ("pre", "print(\"hello\")"), ("text_link", "Telegram"), ("blockquote", "quote"),
            ("expandable_blockquote", "expand"), ("custom_emoji", "😀"),
        ]
        XCTAssertEqual(part.entities.map(\.type), expected.map(\.0))
        XCTAssertEqual(part.entities.map {
            text.substring(with: NSRange(location: $0.offset, length: $0.length))
        }, expected.map(\.1))
        XCTAssertEqual(part.entities.first?.offset, 3)
        XCTAssertEqual(part.entities.first { $0.url != nil }?.url, "https://telegram.org/?a=1&b=2")
        XCTAssertEqual(part.entities.first { $0.language != nil }?.language, "python")
        XCTAssertEqual(part.entities.last?.customEmojiID, "123456789")
        XCTAssertTrue(part.text.contains("< > & 😀"))
    }

    func testCodeKeepsItsContentsAndMalformedFormattingPreservesTheAnswer() throws {
        let source = """
        ```swift
        print("<b>&amp;</b>")
        ```
        `<i>literal</i>`
        <a href="javascript&#58;alert(1)">unsafe link</a>
        <b><i>crossed</b></i> <unsupported>literal</unsupported>
        """
        let part = try XCTUnwrap(DeepSeekWebTelegramFormatter.parts(source).only)
        XCTAssertTrue(part.text.contains("print(\"<b>&amp;</b>\")"))
        XCTAssertTrue(part.text.contains("<i>literal</i>"))
        XCTAssertTrue(part.text.contains("unsafe link"))
        XCTAssertTrue(part.text.contains("crossed <unsupported>literal</unsupported>"))
        XCTAssertEqual(part.entities.map(\.type), ["pre", "code", "bold", "italic"])
        XCTAssertEqual(part.entities.first?.language, "swift")
    }

    func testLongFormattedAnswerKeepsTextAndFormattingAcrossUTF16Chunks() {
        let text = "a" + String(repeating: "😀", count: 2_100) + " & <"
        let parts = DeepSeekWebTelegramFormatter.parts("<b>a" + String(repeating: "😀", count: 2_100) + " &amp; &lt;</b>")

        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts.map(\.text).joined(), text)
        for part in parts {
            XCTAssertLessThanOrEqual(part.text.utf16.count, 4_096)
            XCTAssertEqual(part.entities, [.init(type: "bold", offset: 0, length: part.text.utf16.count)])
        }
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
