import Foundation

struct DeepSeekRequestBody: Codable {
    struct StreamOptions: Codable {
        let include_usage: Bool
    }

    let model: String
    let messages: [ChatMessage]
    let stream: Bool
    let temperature: Float
    let stream_options: StreamOptions?

    init(model: String, messages: [ChatMessage], stream: Bool, temperature: Float, includeUsage: Bool) {
        self.model = model
        self.messages = messages
        self.stream = stream
        self.temperature = temperature
        self.stream_options = stream && includeUsage ? .init(include_usage: true) : nil
    }
}

struct DeepSeekStreamChoice: Decodable {
    struct Delta: Decodable {
        let role: String?
        let content: String?
    }

    let index: Int?
    let delta: Delta?
    let finish_reason: String?
}

struct DeepSeekStreamChunk: Decodable {
    let choices: [DeepSeekStreamChoice]?
    let usage: DeepSeekUsage?
    /// An OpenAI-compatible API can report the failure inside a 200 OK stream.
    let error: ProviderStreamErrorPayload?
}

extension DeepSeekStreamChunk: OpenAICompatibleStreamChunk {
    var streamError: ProviderStreamErrorPayload? { error }

    var deltaText: String? {
        let pieces = choices?.compactMap { $0.delta?.content }.filter { !$0.isEmpty } ?? []
        return pieces.isEmpty ? nil : pieces.joined()
    }

    var finishReasonRaw: String? { choices?.compactMap(\.finish_reason).last }

    var usageSummary: StreamUsageSummary? {
        usage.map { u in
            StreamUsageSummary(
                promptTokens: u.prompt_tokens.map(Double.init),
                completionTokens: u.completion_tokens.map(Double.init),
                totalTokens: u.total_tokens.map(Double.init),
                cacheHitTokens: u.prompt_cache_hit_tokens.map(Double.init),
                cacheWriteTokens: nil,
                cacheMissTokens: u.prompt_cache_miss_tokens.map(Double.init),
                reasoningTokens: u.completion_details?.reasoning_tokens.map(Double.init),
                // DeepSeek prices nothing in the response: the turn is
                // genuinely unpriced, and the footer says «—» rather than
                // inventing a zero.
                cost: nil
            )
        }
    }
}

/// Optional throughout: a required field would let one renamed or omitted
/// counter throw away the whole chunk — text, error payload and all.
struct DeepSeekUsage: Decodable {
    struct CompletionTokenDetails: Decodable {
        let reasoning_tokens: Int?
    }

    let completion_tokens: Int?
    let prompt_tokens: Int?
    let prompt_cache_hit_tokens: Int?
    let prompt_cache_miss_tokens: Int?
    let total_tokens: Int?
    let completion_details: CompletionTokenDetails?
}
