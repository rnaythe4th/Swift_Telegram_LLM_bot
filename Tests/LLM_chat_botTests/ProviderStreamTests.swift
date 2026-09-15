import XCTest
@testable import LLM_chat_bot

/// Zone 14: what the bot reads out of a provider's stream. The adapters had no
/// tests at all, and every rule here is one the pipeline bills money on.
final class ProviderStreamTests: XCTestCase {

    private func step(
        _ payload: String,
        in accumulator: inout OpenAIStreamAccumulator<OpenRouterStreamChunk>
    ) throws -> OpenAIStreamAccumulator<OpenRouterStreamChunk>.Step {
        try accumulator.accept(payload, from: .openrouter)
    }

    private func chunk(_ text: String) -> String {
        #"{"choices":[{"index":0,"delta":{"content":"\#(text)"}}]}"#
    }

    // MARK: - The ordinary stream

    func testTextChunksBecomeTextAndDoneEndsTheStream() throws {
        var accumulator = OpenAIStreamAccumulator<OpenRouterStreamChunk>()
        XCTAssertEqual(try step(chunk("При"), in: &accumulator), .text("При"))
        XCTAssertEqual(try step(chunk("вет"), in: &accumulator), .text("вет"))
        XCTAssertEqual(try step("[DONE]", in: &accumulator), .finished)
    }

    func testRoleOnlyAndEmptyDeltasAreIgnored() throws {
        var accumulator = OpenAIStreamAccumulator<OpenRouterStreamChunk>()
        XCTAssertEqual(
            try step(#"{"choices":[{"index":0,"delta":{"role":"assistant"}}]}"#, in: &accumulator),
            .ignore
        )
        XCTAssertEqual(try step(chunk(""), in: &accumulator), .ignore)
        XCTAssertEqual(try step("not json at all", in: &accumulator), .ignore)
    }

    func testUsageArrivesInItsOwnChunkAndEndsUpInMeta() throws {
        var accumulator = OpenAIStreamAccumulator<OpenRouterStreamChunk>()
        _ = try step(chunk("hi"), in: &accumulator)
        _ = try step(
            #"{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15,"cost":0.0004}}"#,
            in: &accumulator
        )
        let meta = accumulator.meta(model: "openai/gpt-5")
        XCTAssertEqual(meta.usage?.totalTokens, 15)
        XCTAssertEqual(meta.usage?.cost, 0.0004)
        XCTAssertEqual(meta.model, "openai/gpt-5")
    }

    /// The price of a model OpenRouter does not bill itself.
    func testCostFallsBackToTheUpstreamFigure() throws {
        var accumulator = OpenAIStreamAccumulator<OpenRouterStreamChunk>()
        _ = try step(
            #"{"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2,"cost_details":{"upstream_inference_cost":0.25}}}"#,
            in: &accumulator
        )
        XCTAssertEqual(accumulator.meta(model: "m").usage?.cost, 0.25)
    }

    /// A stream that stops before the usage chunk is an unpriced turn, not a
    /// zero-priced one: the footer says «—» and nothing is charged.
    func testStreamCutBeforeUsageLeavesNoPrice() throws {
        var accumulator = OpenAIStreamAccumulator<OpenRouterStreamChunk>()
        _ = try step(chunk("half an answer"), in: &accumulator)
        let meta = accumulator.meta(model: "m")
        XCTAssertNil(meta.usage)
        XCTAssertNil(meta.usage?.cost)
    }

    // MARK: - Failure inside a 200 OK stream

    func testErrorPayloadThrowsInsteadOfEndingEmpty() throws {
        var accumulator = OpenAIStreamAccumulator<OpenRouterStreamChunk>()
        XCTAssertThrowsError(
            try step(#"{"error":{"code":429,"message":"rate limited"}}"#, in: &accumulator)
        ) { error in
            guard case .upstream(let provider, let code, let message)? = error as? ProviderAdapterError else {
                return XCTFail("expected .upstream, got \(error)")
            }
            XCTAssertEqual(provider, .openrouter)
            XCTAssertEqual(code, 429)
            XCTAssertEqual(message, "rate limited")
            // And the user is told the reason, in Russian, without the
            // provider's own wording.
            XCTAssertTrue(UserFacingError.message(error).contains("429"))
            XCTAssertFalse(UserFacingError.message(error).contains("rate limited"))
        }
    }

    func testErrorCodeIsReadAsANumberOrAsAString() throws {
        var accumulator = OpenAIStreamAccumulator<OpenRouterStreamChunk>()
        XCTAssertThrowsError(try step(#"{"error":{"code":"402","message":"no credit"}}"#, in: &accumulator)) {
            guard case .upstream(_, let code, _)? = $0 as? ProviderAdapterError else {
                return XCTFail("expected .upstream")
            }
            XCTAssertEqual(code, 402)
        }
    }

    /// An error in the same chunk as a delta still ends the turn: text that
    /// arrives with a refusal attached is not an answer.
    func testErrorWinsOverTextInTheSameChunk() throws {
        var accumulator = OpenAIStreamAccumulator<OpenRouterStreamChunk>()
        XCTAssertThrowsError(
            try step(
                #"{"choices":[{"delta":{"content":"partial"}}],"error":{"code":500,"message":"boom"}}"#,
                in: &accumulator
            )
        )
    }

    // MARK: - Fields the providers disagree about

    /// One missing counter used to throw away the whole chunk — text, error
    /// and all — because usage, delta and error were decoded from the same
    /// object three separate times.
    func testChunkWithPartialUsageStillYieldsItsText() throws {
        var accumulator = OpenAIStreamAccumulator<OpenRouterStreamChunk>()
        let payload = #"{"choices":[{"delta":{"content":"ответ"}}],"usage":{"prompt_tokens":7}}"#
        XCTAssertEqual(try step(payload, in: &accumulator), .text("ответ"))
        XCTAssertEqual(accumulator.meta(model: "m").usage?.promptTokens, 7)
        XCTAssertNil(accumulator.meta(model: "m").usage?.totalTokens)
    }

    func testDeepSeekSpeaksTheSameDialect() throws {
        var accumulator = OpenAIStreamAccumulator<DeepSeekStreamChunk>()
        XCTAssertEqual(
            try accumulator.accept(#"{"choices":[{"delta":{"content":"да"}}]}"#, from: .deepseek),
            .text("да")
        )
        _ = try accumulator.accept(#"{"usage":{"prompt_tokens":3,"total_tokens":4}}"#, from: .deepseek)
        XCTAssertEqual(accumulator.meta(model: "deepseek-chat").usage?.totalTokens, 4)
        XCTAssertThrowsError(try accumulator.accept(#"{"error":{"code":401}}"#, from: .deepseek))
    }

    // MARK: - Finish reason

    func testTruncatedAnswerIsReportedToTheUser() throws {
        var accumulator = OpenAIStreamAccumulator<OpenRouterStreamChunk>()
        _ = try step(chunk("длинный ответ"), in: &accumulator)
        _ = try step(#"{"choices":[{"index":0,"delta":{},"finish_reason":"length"}]}"#, in: &accumulator)
        let meta = accumulator.meta(model: "m")
        XCTAssertEqual(meta.finishReason, .length)

        // Even with every statistic switched off: "this is not the whole
        // answer" is not a statistic.
        let footer = ResponseFooterFormatter.formatFooter(
            meta: meta,
            fallbackModel: "m",
            showTokens: false,
            showCost: false,
            showModel: false
        )
        XCTAssertNotNil(footer)
        XCTAssertTrue(footer?.contains("обрезан") == true)
    }

    func testNormalStopSaysNothingExtra() throws {
        var accumulator = OpenAIStreamAccumulator<OpenRouterStreamChunk>()
        _ = try step(#"{"choices":[{"delta":{"content":"всё"},"finish_reason":"stop"}]}"#, in: &accumulator)
        let meta = accumulator.meta(model: "m")
        XCTAssertEqual(meta.finishReason, .stop)
        XCTAssertNil(ResponseFooterFormatter.formatFooter(
            meta: meta, fallbackModel: "m", showTokens: false, showCost: false, showModel: false
        ))
    }

    func testUnknownFinishReasonIsKeptVerbatimAndNotTreatedAsTruncation() {
        XCTAssertEqual(StreamFinishReason(rawValue: "tool_calls"), .other("tool_calls"))
        XCTAssertEqual(StreamFinishReason(rawValue: "max_tokens"), .length)
        XCTAssertEqual(StreamFinishReason(rawValue: "end_turn"), .stop)
    }

    // MARK: - Numbers from somebody else's JSON

    /// A count the bot cannot represent used to trap on the way to the screen —
    /// and take the process with it, on every render of that chat.
    func testAbsurdTokenCountsAreClampedAtTheBoundary() throws {
        var accumulator = OpenAIStreamAccumulator<OpenRouterStreamChunk>()
        _ = try step(
            #"{"usage":{"prompt_tokens":1e30,"completion_tokens":-5,"total_tokens":1e30,"cost":-1}}"#,
            in: &accumulator
        )
        let usage = accumulator.meta(model: "m").usage
        XCTAssertEqual(usage?.totalTokens, StreamUsageSummary.maxPlausibleTokens)
        XCTAssertEqual(usage?.completionTokens, 0)
        XCTAssertEqual(usage?.cost, 0)

        // And the footer renders it instead of dying.
        let footer = ResponseFooterFormatter.formatFooter(
            meta: accumulator.meta(model: "m"),
            fallbackModel: "m",
            showTokens: true,
            showCost: true,
            showModel: false
        )
        XCTAssertNotNil(footer)
    }

    func testNonFiniteNumbersNeverReachTheDomain() {
        let usage = StreamUsageSummary(
            promptTokens: .nan,
            completionTokens: .infinity,
            totalTokens: -.infinity,
            cacheHitTokens: nil,
            cacheWriteTokens: nil,
            cacheMissTokens: nil,
            reasoningTokens: nil,
            cost: .nan
        )
        XCTAssertNil(usage.promptTokens)
        XCTAssertNil(usage.completionTokens)
        XCTAssertNil(usage.totalTokens)
        XCTAssertNil(usage.cost)

        // A NaN in the totals is not a wrong number on a screen: it survives
        // every addition and `JSONEncoder` refuses to write it, which would
        // take the whole chat row down with it.
        var totals = CumulativeUsage.zero
        totals.add(usage, markupPercent: 30)
        XCTAssertTrue(totals.totalTokens.isFinite)
        XCTAssertNoThrow(try JSONEncoder().encode(totals))
    }

    // MARK: - The watchdog

    /// What kills a turn is silence, not slowness. A model that thinks for
    /// minutes is sending keep-alives the whole time, and cutting it off wastes
    /// thinking the owner has already paid the provider for.
    func testKeepAlivesHoldTheStreamOpenPastTheIdleGap() async throws {
        let source = AsyncThrowingStream<ProviderStreamEvent, Error> { continuation in
            Task {
                for _ in 0..<8 {
                    try? await Task.sleep(for: .milliseconds(40))
                    continuation.yield(.keepAlive)
                }
                continuation.yield(.text("наконец-то"))
                continuation.finish()
            }
        }

        var text = ""
        for try await event in source.withIdleTimeout(.milliseconds(120), total: .seconds(5), tick: .milliseconds(20)) {
            if case .text(let chunk) = event { text += chunk }
        }
        XCTAssertEqual(text, "наконец-то")
    }

    /// And a provider that says nothing at all still loses the slot.
    func testSilenceFailsTheStream() async throws {
        let source = AsyncThrowingStream<ProviderStreamEvent, Error> { continuation in
            Task {
                try? await Task.sleep(for: .seconds(3))
                continuation.finish()
            }
        }

        do {
            for try await _ in source.withIdleTimeout(.milliseconds(100), total: .seconds(5), tick: .milliseconds(20)) {}
            XCTFail("a silent provider must not hold the generation slot")
        } catch {
            guard case .idleTimeout? = error as? ProviderAdapterError else {
                return XCTFail("expected .idleTimeout, got \(error)")
            }
        }
    }

    func testTokenFormattingSurvivesWhateverItIsGiven() {
        XCTAssertEqual(ResponseFooterFormatter.formatTokenValue(1500), "1500")
        XCTAssertEqual(ResponseFooterFormatter.formatTokenValue(.nan), "—")
        XCTAssertEqual(ResponseFooterFormatter.formatTokenValue(.infinity), "—")
        XCTAssertFalse(ResponseFooterFormatter.formatTokenValue(1e30).isEmpty)
    }
}
