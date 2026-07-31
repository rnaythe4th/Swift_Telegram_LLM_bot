import XCTest
@testable import LLM_chat_bot

/// Byte-for-byte expected output for `HTMLCorpus`, captured from the
/// single-function sanitizer before it was split into tokenizer / sanitizer /
/// renderer.
///
/// Its job is narrow and worth stating: it does not claim the outputs below are
/// ideal, only that the split did not change any of them. Sanitizer behaviour
/// that *should* hold is asserted by name in `TelegramHTMLFormatterTests`;
/// this file is the net that made a 375-line rewrite safe to do at all.
final class TelegramHTMLFormatterGoldenTests: XCTestCase {

    func testCorpusRendersExactlyAsBefore() {
        XCTAssertEqual(HTMLCorpus.cases.count, Self.expected.count, "corpus and goldens are out of step")
        for (input, want) in zip(HTMLCorpus.cases, Self.expected) {
            XCTAssertEqual(
                TelegramHTMLFormatter.helper(text: input),
                want,
                "input: \(input.debugDescription)"
            )
        }
    }

    /// A trailing "<" used to trap: the bounds check looked at the current
    /// index instead of the next one, so a message ending in a lone angle
    /// bracket — a truncated code block does it — crashed the process rather
    /// than escaping the character.
    func testTrailingAngleBracketIsEscapedRatherThanFatal() {
        XCTAssertEqual(TelegramHTMLFormatter.helper(text: "<"), "&lt;")
        XCTAssertEqual(TelegramHTMLFormatter.helper(text: "код: 2 <"), "код: 2 &lt;")
        XCTAssertEqual(TelegramHTMLFormatter.helper(text: "<b>x</b><"), "<b>x</b>&lt;")
    }

    private static let expected: [String] = [
        "просто текст",
        "2 &lt; 3 и 5 &gt; 4 &amp; 7",
        "",
        "&lt;",
        "&gt;",
        "&amp;",
        "a &lt; ",
        "<b>bold</b>",
        "<strong>x</strong><em>y</em><ins>z</ins><del>w</del>",
        "<tg-spoiler>секрет</tg-spoiler>",
        "<span class=\"tg-spoiler\">секрет</span>",
        "без класса",
        "<span class=\"tg-spoiler\">одинарные кавычки</span>",
        "<blockquote expandable>цитата</blockquote>",
        "<blockquote expandable>цитата</blockquote>",
        "<tg-emoji emoji-id=\"5368324170671202286\">👍</tg-emoji>",
        "без id",
        "<a href=\"https://example.com\">ok</a>",
        "bad",
        "bad",
        "protocol relative",
        "<a href=\"tg://user?id=1\">tg</a>",
        "<a href=\"mailto:a@b.c\">mail</a>",
        "<a href=\"/relative/path\">rel</a>",
        "smuggled",
        "без href",
        "<a href=\"x\">extra attrs</a>",
        "<a href=\"x&quot; onclick=&quot;y\">quote break</a>",
        "<pre><code class=\"language-swift\">let x = 1</code></pre>",
        "<code>вне pre</code>",
        "<code>x</code>",
        "<pre>plain pre</pre>",
        "inner",
        "после",
        "alert(1)",
        "после",
        "",
        "\nперенос",
        "\nперенос",
        "",
        "<b>не закрыт</b>",
        "<b><i>перекрёстно",
        "лишний закрывающий",
        "<b>a</b>",
        "&lt; b&gt;пробел после угла",
        "&lt;3 сердечко",
        "текст",
        "текст",
        "текст",
        "&lt;!-- без конца",
        "&lt;b",
        "&lt;b attr",
        "&lt;&gt;&amp;&quot;",
        "&amp;copy;",
        "&#1234;",
        "&#x1Af;",
        "&amp;#;",
        "&amp;#xZZ;",
        "&amp;noSemicolon",
        "&amp;amp;",
        "<blockquote expandable>два пробела</blockquote>",
        "<a href=\"https://x.y\">пробелы вокруг равно</a>",
        "<a href=\"https://x.y\">без кавычек</a>",
        "<a href=\"unterminated\">текст</a>",
        "<code>верхний регистр</code>",
        "<b><i><u>тройная вложенность</u></i></b>",
        "<blockquote><b>цитата с жирным</b></blockquote>",
        "<pre><code>a &lt; b</code></pre>",
        "Вот пример:\n<pre><code class=\"language-swift\">if a &lt; b { print(\"&amp;\") }</code></pre>\nи <b>вывод</b>.",
    ]
}
