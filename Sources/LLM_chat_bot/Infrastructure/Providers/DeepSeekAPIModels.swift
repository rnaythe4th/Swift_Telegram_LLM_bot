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
    let choices: [DeepSeekStreamChoice]
    let usage: DeepSeekUsage?
}

struct DeepSeekUsage: Decodable {
    struct CompletionTokenDetails: Decodable {
        let reasoning_tokens: Int
    }

    let completion_tokens: Int
    let prompt_tokens: Int
    let prompt_cache_hit_tokens: Int
    let prompt_cache_miss_tokens: Int
    let total_tokens: Int
    let completion_details: CompletionTokenDetails?
}
