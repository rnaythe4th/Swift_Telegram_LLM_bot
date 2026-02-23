import Foundation

enum ServiceProvider: String, Sendable {
    case openrouter = "Openrouter"
    case deepseek = "Deepseek"
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

    func makeStream(routerApiKey: String, deepseekKey: String, showStats: Bool) -> AsyncThrowingStream<String, Error> {
        switch self {
        case .openrouter(let params):
            return OpenRouterAPI.stream(apiKey: routerApiKey, reqBody: params, showStats: showStats)
        case .deepseek(let params):
            return DeepseekAPI.deepseekStream(apiKey: deepseekKey, reqParams: params, showStats: showStats)
        }
    }
}
