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

    let prompt_tokens: Float
    let completion_tokens: Float
    let total_tokens: Float
    let prompt_tokens_details: PromptTokenDetails?
    let completion_tokens_details: CompletionTokenDetails?
    let cost: Double?
    let is_byok: Bool?
    let cost_details: CostDetails?
    let server_tool_use: ServerToolUse?
}

struct OpenRouterStreamChunk: Codable {
    struct Choice: Codable {
        struct Delta: Codable {
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
}
