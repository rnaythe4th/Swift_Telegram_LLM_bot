import XCTest
@testable import LLM_chat_bot

/// The sanitizer decides what a bot message may contain. Its invariants are
/// security ones: no unlisted tag survives, no attribute can be broken out of,
/// no link scheme outside the allow-list is kept.
final class TelegramHTMLFormatterTests: XCTestCase {

    private func render(_ text: String) -> String {
        TelegramHTMLFormatter.helper(text: text)
    }

    func testPlainTextSurvivesUnchanged() {
        XCTAssertEqual(render("просто текст"), "просто текст")
    }

    func testAllowedTagsAreKept() {
        XCTAssertEqual(render("<b>bold</b>"), "<b>bold</b>")
        XCTAssertEqual(render("<i>it</i>"), "<i>it</i>")
        XCTAssertEqual(render("<code>x</code>"), "<code>x</code>")
    }

    func testBareAngleBracketsAreEscaped() {
        XCTAssertEqual(render("2 < 3"), "2 &lt; 3")
        XCTAssertTrue(render("a > b").contains("&gt;"))
    }

    func testUnknownTagIsDroppedButItsTextRemains() {
        let out = render("<div>inner</div>")
        XCTAssertTrue(out.contains("inner"))
        XCTAssertFalse(out.contains("<div"))
    }

    func testDanglingTagIsClosed() {
        let out = render("<b>unclosed")
        XCTAssertTrue(out.hasSuffix("</b>"), out)
    }

    func testOrphanClosingTagDoesNotLeak() {
        XCTAssertFalse(render("text</b>").contains("</b>"))
    }

    func testJavascriptLinksAreRefused() {
        let out = render("<a href=\"javascript:alert(1)\">tap</a>")
        XCTAssertFalse(out.lowercased().contains("javascript"))
        XCTAssertTrue(out.contains("tap"))
    }

    func testDataLinksAreRefused() {
        let out = render("<a href=\"data:text/html;base64,PHN2Zz4=\">x</a>")
        XCTAssertFalse(out.lowercased().contains("data:"))
    }

    func testProtocolRelativeLinksAreRefused() {
        let out = render("<a href=\"//evil.test\">x</a>")
        XCTAssertFalse(out.contains("//evil.test"))
    }

    func testAllowedSchemesSurvive() {
        XCTAssertTrue(render("<a href=\"https://x.test/a\">x</a>").contains("https://x.test/a"))
        XCTAssertTrue(render("<a href=\"tg://user?id=1\">x</a>").contains("tg://user?id=1"))
        XCTAssertTrue(render("<a href=\"mailto:a@b.test\">x</a>").contains("mailto:a@b.test"))
    }

    /// A quote inside an attribute value closes it and injects a second one;
    /// Telegram then rejects the whole message and the answer never arrives.
    func testAttributeValueCannotBreakOutOfItsQuotes() {
        let out = render("<a href=\"https://x.test/?a=1\" onclick=\"evil()\">x</a>")
        XCTAssertFalse(out.contains("onclick"))
        let injected = render("<tg-emoji emoji-id=\"5\" x=\"y\">🙂</tg-emoji>")
        XCTAssertFalse(injected.contains(" x="))
    }

    func testScriptContentIsSwallowed() {
        let out = render("before<script>alert('x')</script>after")
        XCTAssertFalse(out.contains("alert"))
        XCTAssertTrue(out.contains("before"))
        XCTAssertTrue(out.contains("after"))
    }

    func testCommentsAreDropped() {
        XCTAssertEqual(render("a<!-- hidden -->b"), "ab")
    }

    func testAmpersandIsEscapedButExistingEntitiesPassThrough() {
        XCTAssertTrue(render("Tom & Jerry").contains("&amp;"))
        // Labels are escaped at their source (`UserIdentity.sanitizeName`), so
        // re-escaping here would show the reader `&amp;lt;`.
        XCTAssertFalse(render("&lt;name&gt;").contains("&amp;lt;"))
    }

    func testNestedAllowedTagsKeepTheirOrder() {
        XCTAssertEqual(render("<b><i>x</i></b>"), "<b><i>x</i></b>")
    }

    /// Telegram accepts a language hint only on a `<code>` inside `<pre>`, and
    /// the sanitizer follows that: elsewhere the class is dropped.
    func testCodeLanguageClassIsKeptOnlyInsidePre() {
        XCTAssertTrue(
            render("<pre><code class=\"language-swift\">x</code></pre>").contains("language-swift")
        )
        XCTAssertFalse(render("<code class=\"language-swift\">x</code>").contains("language-swift"))
        XCTAssertFalse(render("<pre><code class=\"evil\">x</code></pre>").contains("evil"))
    }
}
