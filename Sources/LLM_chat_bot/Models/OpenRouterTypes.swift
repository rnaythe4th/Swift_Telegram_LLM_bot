//
//  OpenRouter.swift
//  LLM_chat_bot
//
//  Created by Vladislav on 21.02.26.
//


// https://openrouter.ai/docs/api/reference/parameters

struct RouterRequestMessage: Codable {
    let role: String //'user' | 'assistant' | 'system'
    let content: String
    var name: String? = nil
}

struct RouterRequestBody: Codable {
    struct StreamOptions: Codable {
        let include_usage: Bool
    }

    // Either "messages" or "prompt" is required
    var messages: [ChatMessage]? = nil
    var prompt: String? = nil
    var model: String? = nil
    var stream: Bool? = nil
    var stream_options: StreamOptions? = nil
    var stop: String? = nil
    var max_tokens: Float? = nil
    let temperature: Float // 0.0 - 2.0
    let reasoning: RouterReasoning?
    //let tools: [ORTool?]
    //let tool_choice: ORToolChoice?
    //let response_format: ORResponseFormat?
    //let plugins: ORPlugin?

    // Advanced optional parameters
    var seed: Int? = nil // Integer only
    var top_p: Float? = nil // 0.0 to 1.0
    var top_k: Float? = nil // Range: [1, Infinity) Not available for OpenAI models
    var frequency_penalty: Float? = nil // Range: [-2, 2]
    var presence_penalty: Float? = nil // Range: [-2, 2]
    var repetition_penalty: Float? = nil // Range: (0, 2]
   // let logit_bias: { [key: number]: number };
    var top_logprobs: Int? = nil // Integer only
    var min_p: Float? = nil // Range: [0, 1]
    var top_a: Float? = nil // Range: [0, 1]

    // Reduce latency by providing the model with a predicted output
      //https://platform.openai.com/docs/guides/latency-optimization#use-predicted-outputs
    //prediction?: { type: 'content'; content: string };
      // OpenRouter-only parameters
      // See "Prompt Transforms" section: openrouter.ai/docs/guides/features/message-transforms
    //transforms?: string[];
      // See "Model Routing" section: openrouter.ai/docs/guides/features/model-routing
    //models?: string[];
    //route?: 'fallback';
      // See "Provider Routing" section: openrouter.ai/docs/guides/routing/provider-selection
    //provider?: ProviderPreferences;
    //user?: string; // A stable identifier for your end-users. Used to help detect and prevent abuse.

}

struct RouterResponse: Codable {
    let id: String?
    let provider: String?
    // пока принудительно стриминг
    let choices: [RouterStreamingChoice]?
    let created: Float? // Unix timestamp
    let model: String?
    let object: String?
    let system_fingerprint: String? // Only present if the provider supports it
    // Usage data is always returned for non-streaming.
      // When streaming, usage is returned exactly once in the final chunk
      // before the [DONE] message, with an empty choices array.
    let usage: RouterResponseUsage?
}

struct RouterStreamingChoice: Codable {
    let index: Float?
    let finish_reason: String?
    let native_finish_reason: String?
    let delta: RouterStreamingDelta?
    let error: RouterErrorResponse?
}

struct RouterStreamingDelta: Codable {
    let content: String?
    let role: String?
    let reasoning: String?
    let reasoning_details: [String]?
    let tool_calls: RouterToolCall?
}

struct RouterNonChatChoice: Codable {
    let finish_reason: String?
    let text: String
    let error: RouterErrorResponse?
}

struct RouterNonStreamingChoice: Codable {
    let finish_reason: String?
    let native_finish_reason: String?
    let message: RouterResponseMessage
    let error: RouterErrorResponse?
}

struct RouterResponseMessage: Codable {
    let content: String?
    let role: String
    let tool_calls: RouterToolCall?
}

struct RouterToolCall: Codable {

    let id: String
    var type = "function"
    let function: RouterFunctionCall?
}

struct RouterFunctionCall: Codable {
    let name: String
}

struct RouterErrorResponse: Codable {
    let code: Int
    let message: String
    let metadata: [String: String?]? //[String: Any] в оригинале
}

enum RouterResponseObject: String,Codable {
    case chatCompletion = "chat.completion"
    case chatCompletionChunk = "chat.completion.chunk"
}

struct RouterResponseUsage: Codable {
    struct RouterPromptTokensDetails: Codable {
        let cachedTokens: Int?
        let cacheWriteTokens: Int?
        let audioTokens: Int?
        let videoTokens: Int?
// спросить можно ли в структуре сразу написать имена переменных как ключи и будет ли это нормально работать при декодировании
        enum CodingKeys: String, CodingKey {
            case cachedTokens = "cached_tokens"
            case cacheWriteTokens = "cache_write_tokens"
            case audioTokens = "audio_tokens"
            case videoTokens = "video_tokens"
        }
    }

    struct RouterCompletionTokenDetails: Codable {
        let reasoning_tokens: Int?
        let image_tokens: Int?
    }

    struct RouterCostDetails: Codable {
        let upstream_inference_cost: Double?
        let upstream_inference_prompt_cost: Double?
        let upstream_inference_completions_cost: Double?

    }

    struct RouterServerToolUse: Codable {
        let web_search_requests: Int?
    }

    let prompt_tokens: Float
    let completion_tokens: Float
    let total_tokens: Float
    let prompt_tokens_details: RouterPromptTokensDetails?
    let completion_tokens_details: RouterCompletionTokenDetails?
    let cost: Double?
    let is_byok: Bool?
    let cost_details: RouterCostDetails?
    let server_tool_use: RouterServerToolUse?
}

struct RouterStreamChunk: Codable {
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
    let usage: RouterResponseUsage?
}

// --------------- REASONING ---------------

struct RouterReasoning: Codable {
    var effort: String
    var summary: String
    var enabled: Bool
}
