import Foundation

struct OpenRouterRequestBody: Codable {
    struct StreamOptions: Codable {
        let include_usage: Bool
    }

    var messages: [ChatMessage]? = nil
    var prompt: String? = nil
    var model: String? = nil
    var stream: Bool? = nil
    var stream_options: StreamOptions? = nil
    var stop: String? = nil
    var max_tokens: Float? = nil
    let temperature: Float
    let reasoning: OpenRouterReasoning?

    var seed: Int? = nil
    var top_p: Float? = nil
    var top_k: Float? = nil
    var frequency_penalty: Float? = nil
    var presence_penalty: Float? = nil
    var repetition_penalty: Float? = nil
    var top_logprobs: Int? = nil
    var min_p: Float? = nil
    var top_a: Float? = nil
    var provider: OpenRouterProviderRouting? = nil
}

struct OpenRouterProviderRouting: Codable {
    var order: [String]? = nil
    var only: [String]? = nil
    var allow_fallbacks: Bool? = nil
}

struct OpenRouterReasoning: Codable {
    var effort: String
    var summary: String
    var enabled: Bool
}

struct OpenRouterResponseUsage: Codable {
    struct PromptTokenDetails: Codable {
        let cachedTokens: Int?
        let cacheWriteTokens: Int?
        let audioTokens: Int?
        let videoTokens: Int?

        enum CodingKeys: String, CodingKey {
            case cachedTokens = "cached_tokens"
            case cacheWriteTokens = "cache_write_tokens"
            case audioTokens = "audio_tokens"
            case videoTokens = "video_tokens"
        }
    }

    struct CompletionTokenDetails: Codable {
        let reasoning_tokens: Int?
        let image_tokens: Int?
    }

    struct CostDetails: Codable {
        let upstream_inference_cost: Double?
        let upstream_inference_prompt_cost: Double?
        let upstream_inference_completions_cost: Double?
    }

    struct ServerToolUse: Codable {
        let web_search_requests: Int?
    }

    // Optional on purpose. These are the fields upstreams disagree about most
    // (some omit `total_tokens`, some send only what they charged for), and a
    // required field turns one missing number into a chunk that decodes as
    // neither usage, nor text, nor error — the answer arrives with a piece
    // missing and the turn is billed as free.
    let prompt_tokens: Float?
    let completion_tokens: Float?
    let total_tokens: Float?
    let prompt_tokens_details: PromptTokenDetails?
    let completion_tokens_details: CompletionTokenDetails?
    let cost: Double?
    let is_byok: Bool?
    let cost_details: CostDetails?
    let server_tool_use: ServerToolUse?
}

struct OpenRouterModelsResponse: Decodable {
    let data: [OpenRouterModelInfo]
}

struct OpenRouterModelInfo: Decodable {
    let id: String
    let pricing: OpenRouterModelPricing?

    var isFree: Bool {
        guard let p = pricing else { return false }
        return p.prompt == "0" && p.completion == "0"
    }
}

struct OpenRouterModelPricing: Decodable {
    let prompt: String
    let completion: String
}

struct OpenRouterStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
            let role: String?
            let reasoning: String?
        }

        let index: Int?
        let delta: Delta?
        let finish_reason: String?
    }

    let choices: [Choice]?
    let usage: OpenRouterResponseUsage?
    /// OpenRouter reports upstream failures inside the stream, with HTTP 200.
    let error: ProviderStreamErrorPayload?
}

extension OpenRouterStreamChunk: OpenAICompatibleStreamChunk {
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
                cacheHitTokens: u.prompt_tokens_details?.cachedTokens.map(Double.init),
                cacheWriteTokens: u.prompt_tokens_details?.cacheWriteTokens.map(Double.init),
                cacheMissTokens: nil,
                reasoningTokens: u.completion_tokens_details?.reasoning_tokens.map(Double.init),
                // `cost` is what OpenRouter bills; the upstream figure is the
                // fallback for models it does not price itself. A zero is a
                // price (free models), not a missing one.
                cost: u.cost ?? u.cost_details?.upstream_inference_cost
            )
        }
    }
}
