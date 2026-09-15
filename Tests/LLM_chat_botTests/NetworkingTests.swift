import XCTest
@testable import LLM_chat_bot

/// Zone 12: the framing under every LLM answer, and the form codec under every
/// checkout signature. Both are pure, both were untested, and both fail in ways
/// that look like the provider's fault or the vendor's.
final class ServerSentEventParserTests: XCTestCase {

    private func parser() -> ServerSentEventParser {
        ServerSentEventParser(bufferLimit: 1 << 20)
    }

    /// Only the payloads — keep-alives have their own tests.
    private func payloads(of chunks: [String], bufferLimit: Int = 1 << 20) throws -> [String] {
        try events(of: chunks, bufferLimit: bufferLimit).compactMap {
            guard case .payload(let text) = $0 else { return nil }
            return text
        }
    }

    private func events(of chunks: [String], bufferLimit: Int = 1 << 20) throws -> [ServerSentEventParser.Event] {
        var parser = ServerSentEventParser(bufferLimit: bufferLimit)
        var out: [ServerSentEventParser.Event] = []
        for chunk in chunks {
            out += try parser.consume(Data(chunk.utf8))
        }
        out += parser.finish()
        return out
    }

    func testEventIsCompleteOnlyAfterItsBlankLine() throws {
        var parser = parser()
        XCTAssertEqual(try parser.consume(Data("data: {\"a\":1}\n".utf8)), [])
        XCTAssertEqual(try parser.consume(Data("\n".utf8)), [.payload("{\"a\":1}")])
    }

    /// The one that eats tokens: TCP hands over whatever it has, and the answer
    /// must not depend on where the boundary fell.
    func testPayloadSplitAcrossChunksArrivesWhole() throws {
        XCTAssertEqual(
            try payloads(of: ["data: {\"cho", "ices\":[{\"delta\"", ":{\"content\":\"привет\"}}]}\n\n"]),
            ["{\"choices\":[{\"delta\":{\"content\":\"привет\"}}]}"]
        )
    }

    /// A multi-byte character split down the middle is still one character.
    func testUTF8SequenceSplitAcrossChunksSurvives() throws {
        let bytes = Array("data: привет\n\n".utf8)
        var parser = parser()
        var out: [ServerSentEventParser.Event] = []
        for byte in bytes {
            out += try parser.consume(Data([byte]))
        }
        out += parser.finish()
        XCTAssertEqual(out, [.payload("привет")])
    }

    func testCarriageReturnSplitFromItsNewlineIsStillOneLine() throws {
        XCTAssertEqual(try payloads(of: ["data: hello\r", "\n\r\n"]), ["hello"])
    }

    /// `data:{…}` and `data: {…}` are the same line; a second space is content.
    func testOnlyOneSpaceAfterTheColonBelongsToTheFraming() throws {
        XCTAssertEqual(try payloads(of: ["data:{\"a\":1}\n\n"]), ["{\"a\":1}"])
        XCTAssertEqual(try payloads(of: ["data:  x\n\n"]), [" x"])
    }

    func testCommentsAndOtherFieldsAreIgnored() throws {
        XCTAssertEqual(
            try payloads(of: [": OPENROUTER PROCESSING\n", "event: message\n", "id: 7\n", "data: x\n\n"]),
            ["x"]
        )
    }

    func testMultipleDataLinesJoinWithNewline() throws {
        XCTAssertEqual(try payloads(of: ["data: one\ndata: two\n\n"]), ["one\ntwo"])
    }

    /// Providers close without a trailing blank line, and the last thing they
    /// say is usually `[DONE]`.
    func testLastEventWithoutBlankLineIsStillDelivered() throws {
        XCTAssertEqual(try payloads(of: ["data: a\n\n", "data: [DONE]"]), ["a", "[DONE]"])
    }

    func testDoneSentinelIsRecognisedWhateverThePadding() {
        XCTAssertTrue(ProviderStreamPayload.isDone("[DONE]"))
        XCTAssertTrue(ProviderStreamPayload.isDone(" [DONE] "))
        XCTAssertFalse(ProviderStreamPayload.isDone("{\"choices\":[]}"))
    }

    /// A stream that never ends a line must not be allowed to eat the process.
    func testEndlessLineFailsInsteadOfGrowingForever() {
        var parser = ServerSentEventParser(bufferLimit: 64)
        XCTAssertThrowsError(
            try parser.consume(Data(String(repeating: "x", count: 200).utf8))
        ) { error in
            XCTAssertEqual((error as? ServerSentEventParser.BufferOverflow)?.limit, 64)
        }
    }

    /// Silence is what the pipeline reads as death, so a provider that is
    /// thinking out loud in comments must not read as silent — the answer used
    /// to be cut off at 75 seconds with the thinking already paid for.
    func testCommentsAndUnknownFieldsCountAsSignsOfLife() throws {
        let events = try events(of: [": OPENROUTER PROCESSING\n", "event: ping\n"])
        XCTAssertEqual(events, [.keepAlive, .keepAlive])
    }

    /// The cap is on *pending* bytes, not on how much the stream may deliver:
    /// a long answer arrives as many complete lines.
    func testManyCompleteLinesDoNotTripTheCap() throws {
        let line = "data: " + String(repeating: "y", count: 40) + "\n\n"
        var parser = ServerSentEventParser(bufferLimit: 64)
        var count = 0
        for _ in 0..<50 {
            count += try parser.consume(Data(line.utf8)).filter { $0 != .keepAlive }.count
        }
        XCTAssertEqual(count, 50)
    }
}

final class URLFormTests: XCTestCase {

    func testPlusDecodesToSpaceBeforePercentDecoding() {
        // `%2B` is a plus the vendor signed; `+` is a space. Getting this
        // backwards fails the signature check, not the parse.
        let parsed = URLForm.parse("a=hello+world&b=2%2B2&c=%D0%BE%D0%BF%D0%BB%D0%B0%D1%82%D0%B0")
        XCTAssertEqual(parsed["a"], "hello world")
        XCTAssertEqual(parsed["b"], "2+2")
        XCTAssertEqual(parsed["c"], "оплата")
    }

    func testEmptyValueAndMissingEqualsBothParseAsEmpty() {
        let parsed = URLForm.parse("a=&b&=ignored&c=1")
        XCTAssertEqual(parsed["a"], "")
        XCTAssertEqual(parsed["b"], "")
        XCTAssertNil(parsed[""])
        XCTAssertEqual(parsed["c"], "1")
    }

    func testDuplicateKeyKeepsTheLastValue() {
        XCTAssertEqual(URLForm.parse("SIGN=aaa&SIGN=bbb")["SIGN"], "bbb")
    }

    /// Separators inside a value would silently change which fields the vendor
    /// sees — and the signature is computed over those fields.
    func testEncodeEscapesSeparatorsAndNonASCII() {
        let query = URLForm.encode([
            (name: "o", value: "a&b=c"),
            (name: "d", value: "2+2"),
            (name: "n", value: "оплата"),
        ])
        XCTAssertEqual(query, "o=a%26b%3Dc&d=2%2B2&n=%D0%BE%D0%BF%D0%BB%D0%B0%D1%82%D0%B0")
    }

    func testEncodeKeepsTheGivenOrder() {
        let query = URLForm.encode([(name: "z", value: "1"), (name: "a", value: "2")])
        XCTAssertEqual(query, "z=1&a=2")
    }

    func testRoundTrip() {
        let items = [(name: "m", value: "SBP · перевод"), (name: "id", value: "ext:freekassa:42")]
        let parsed = URLForm.parse(URLForm.encode(items))
        XCTAssertEqual(parsed["m"], "SBP · перевод")
        XCTAssertEqual(parsed["id"], "ext:freekassa:42")
    }
}
