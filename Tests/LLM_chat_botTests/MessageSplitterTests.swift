import XCTest
@testable import LLM_chat_bot

/// Splitting is what stands between a long answer and a 400 from Telegram:
/// the budget is counted in *rendered* characters, the cut never lands inside
/// markup, and formatting is re-opened in the continuation.
final class MessageSplitterTests: XCTestCase {

    func testShortTextIsNotSplit() {
        let (done, rest) = MessageSplitter.splitRendered("hello")
        XCTAssertEqual(done, "hello")
        XCTAssertEqual(rest, "")
    }

    func testSplitPrefersNewlineThenSpace() {
        let text = String(repeating: "a", count: 60) + "\n" + String(repeating: "b", count: 60)
        let (done, rest) = MessageSplitter.split(text, limit: 80)
        XCTAssertEqual(done, String(repeating: "a", count: 60))
        XCTAssertEqual(rest, String(repeating: "b", count: 60))

        let spaced = String(repeating: "a", count: 60) + " " + String(repeating: "b", count: 60)
        let (spacedDone, spacedRest) = MessageSplitter.split(spaced, limit: 80)
        XCTAssertEqual(spacedDone, String(repeating: "a", count: 60))
        XCTAssertEqual(spacedRest, String(repeating: "b", count: 60))
    }

    func testSplitFallsBackToHardCutWhenNoBreakLateEnough() {
        // The only space sits in the first half, which `split` refuses to use —
        // cutting there would waste most of the message.
        let text = "a " + String(repeating: "b", count: 100)
        let (done, rest) = MessageSplitter.split(text, limit: 40)
        XCTAssertEqual(done.count, 40)
        XCTAssertEqual(done + rest, text)
    }

    func testRenderedLengthCountsEscaping() {
        XCTAssertEqual(MessageSplitter.renderedLength("a&b"), 1 + 5 + 1)
        XCTAssertEqual(MessageSplitter.renderedLength("<>"), 4 + 4)
        XCTAssertEqual(MessageSplitter.renderedLength("plain"), 5)
    }

    /// The regression the rendered budget exists for: raw length fits, escaped
    /// length does not.
    func testSplitRenderedKeepsEscapedChunkInsideLimit() {
        let text = String(repeating: "&", count: 50)
        let (done, rest) = MessageSplitter.splitRendered(text, limit: 100)
        XCTAssertLessThanOrEqual(MessageSplitter.renderedLength(done), 100)
        XCTAssertFalse(rest.isEmpty)
        XCTAssertEqual(done + rest, text)
    }

    func testSplitRenderedNeverCutsInsideATag() {
        let head = String(repeating: "x", count: 30)
        let text = head + "<a href=\"https://example.com/very/long/path\">link</a>" + String(repeating: "y", count: 40)
        let (done, _) = MessageSplitter.splitRendered(text, limit: 45)
        // A chunk that ends mid-tag would carry an unterminated `<`.
        if let bracket = done.lastIndex(of: "<") {
            XCTAssertTrue(done[bracket...].contains(">"), "chunk ends inside a tag: \(done)")
        }
    }

    func testSplitRenderedNeverCutsInsideAnEntity() {
        let text = String(repeating: "x", count: 28) + "&amp;" + String(repeating: "y", count: 40)
        let (done, rest) = MessageSplitter.splitRendered(text, limit: 30)
        XCTAssertFalse(done.hasSuffix("&am"))
        XCTAssertEqual(done + rest, text)
    }

    func testOpenTagMarkupReopensUnclosedFormatting() {
        XCTAssertEqual(MessageSplitter.openTagMarkup(in: "<b>bold text"), "<b>")
        XCTAssertEqual(MessageSplitter.openTagMarkup(in: "<b>bold</b> done"), "")
        XCTAssertEqual(
            MessageSplitter.openTagMarkup(in: "<blockquote><b>quoted"),
            "<blockquote><b>"
        )
        // Attributes are copied verbatim — the continuation is sanitized later.
        XCTAssertEqual(
            MessageSplitter.openTagMarkup(in: "text <a href=\"https://x.test\">link"),
            "<a href=\"https://x.test\">"
        )
    }

    func testClosingTagMarkupClosesInnermostFirst() {
        XCTAssertEqual(MessageSplitter.closingTagMarkup(in: "<pre><code>x"), "</code></pre>")
        XCTAssertEqual(MessageSplitter.closingTagMarkup(in: "plain"), "")
    }

    /// `<script>`/`<style>` swallow their content in the formatter, so re-opening
    /// one would eat the whole continuation.
    func testScriptAndStyleAreNeverReopened() {
        XCTAssertEqual(MessageSplitter.openTagMarkup(in: "<script>alert(1)"), "")
        XCTAssertEqual(MessageSplitter.openTagMarkup(in: "<style>body{}"), "")
    }

    func testUnknownTagsAreNotReopened() {
        XCTAssertEqual(MessageSplitter.openTagMarkup(in: "<div><b>x"), "<b>")
    }

    func testBareComparisonIsNotTreatedAsMarkup() {
        XCTAssertEqual(MessageSplitter.openTagMarkup(in: "if 2 < 3 then"), "")
    }

    func testSplitRenderedReopensFormattingInTheContinuation() {
        let text = "<b>" + String(repeating: "z", count: 200) + "</b>"
        let (done, rest) = MessageSplitter.splitRendered(text, limit: 60)
        XCTAssertTrue(done.hasPrefix("<b>"))
        XCTAssertTrue(rest.hasPrefix("<b>"), "continuation lost its formatting: \(rest.prefix(20))")
    }

    func testSelfClosingAndBreakTagsDoNotStayOnTheStack() {
        XCTAssertEqual(MessageSplitter.openTagMarkup(in: "line<br>next"), "")
        XCTAssertEqual(MessageSplitter.openTagMarkup(in: "<b/>text"), "")
    }

    func testCharLimitLeavesRoomForTheFooter() {
        XCTAssertEqual(MessageSplitter.charLimit, MessageSplitter.telegramMaxChars - MessageSplitter.footerReserve)
        XCTAssertLessThan(MessageSplitter.charLimit, 4096)
    }
}
