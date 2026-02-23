import Foundation

enum ServiceProvider: String, Sendable {
    case openrouter = "Openrouter"
    case deepseek = "Deepseek"
}

struct StreamUsageSummary: Sendable {
    let promptTokens: Double?
    let completionTokens: Double?
    let totalTokens: Double?
    let cacheHitTokens: Double?
    let cacheWriteTokens: Double?
    let cacheMissTokens: Double?
    let reasoningTokens: Double?
    let cost: Double?
}

struct StreamMeta: Sendable {
    let model: String?
    let usage: StreamUsageSummary?
}

enum ProviderStreamEvent: Sendable {
    case text(String)
    case meta(StreamMeta)
}

enum ProviderStreamRequest {
    case openrouter(RouterRequestBody)
    case deepseek(Prompt)

    var provider: ServiceProvider {
        switch self {
        case .openrouter:
            return .openrouter
        case .deepseek:
            return .deepseek
        }
    }

    func makeStream(routerApiKey: String, deepseekKey: String) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        switch self {
        case .openrouter(let params):
            return OpenRouterAPI.stream(apiKey: routerApiKey, reqBody: params)
        case .deepseek(let params):
            return DeepseekAPI.deepseekStream(apiKey: deepseekKey, reqParams: params)
        }
    }
}
