import Foundation

/// One chunk of an OpenAI-compatible completion stream, seen through the only
/// four things this bot reads out of it.
///
/// A protocol rather than two copies of the same loop: both providers speak the
/// same dialect, and the parts that differ are field names, which is exactly
/// what a `Decodable` conformance is for. Adding a third provider means
/// conforming its chunk type — the stream logic below is then already written,
/// and the compiler names what is missing.
protocol OpenAICompatibleStreamChunk: Decodable {
    /// Failure delivered *inside* a 200 OK stream.
    var streamError: ProviderStreamErrorPayload? { get }
    /// Text of this chunk, if it carries any.
    var deltaText: String? { get }
    /// Why the model stopped, in the provider's own vocabulary.
    var finishReasonRaw: String? { get }
    /// Token counts and price, present in the final chunk at most.
    var usageSummary: StreamUsageSummary? { get }
}

/// Folds the payloads of one stream into the events the pipeline consumes.
///
/// Pure and synchronous on purpose: everything that used to make streaming hard
/// to trust — a failure reported with HTTP 200, usage that arrives last or
/// never, a `[DONE]` that never comes — is a decision about one payload, and
/// decisions about one payload can be tested without a network.
struct OpenAIStreamAccumulator<Chunk: OpenAICompatibleStreamChunk> {
    /// What the adapter should do with the payload just handed over.
    enum Step: Equatable {
        /// Nothing to emit: a keep-alive comment, a role-only chunk, a payload
        /// this version does not understand.
        case ignore
        case text(String)
        /// The provider said the stream is over (`[DONE]`).
        case finished
    }

    private let decoder = JSONDecoder()
    private var usage: StreamUsageSummary?
    private var finishReason: StreamFinishReason?

    init() {}

    /// - Throws: `ProviderAdapterError.upstream` when the provider reported a
    ///   failure inside the stream. Swallowing it is what turns a rate limit
    ///   into «Пустой ответ.» with nothing in the logs (§8).
    mutating func accept(_ payload: String, from provider: ServiceProvider) throws -> Step {
        if ProviderStreamPayload.isDone(payload) { return .finished }

        // One decode per payload. Decoding it once per question — error, then
        // usage, then delta — meant a single unexpected field silently
        // discarded the other two answers.
        guard let data = payload.data(using: .utf8),
              let chunk = try? decoder.decode(Chunk.self, from: data) else {
            return .ignore
        }

        if let failure = chunk.streamError {
            throw ProviderAdapterError.upstream(
                provider: provider,
                code: failure.code,
                message: failure.message
            )
        }
        // Kept even when the chunk also carries text: providers put usage in
        // the last chunk, and some put it alongside the final token.
        if let usage = chunk.usageSummary { self.usage = usage }
        if let raw = chunk.finishReasonRaw { finishReason = StreamFinishReason(rawValue: raw) }

        guard let text = chunk.deltaText, !text.isEmpty else { return .ignore }
        return .text(text)
    }

    /// The single `.meta` event that closes the stream. Emitted even when the
    /// provider never sent usage — the model name and the finish reason are
    /// worth saying on their own, and an absent price is not a zero one.
    func meta(model: String?) -> StreamMeta {
        StreamMeta(model: model, usage: usage, finishReason: finishReason)
    }
}
