import Foundation

struct ProviderGenerationPlan: Sendable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Float
    let includeUsage: Bool
    let reasoningEnabled: Bool
}

protocol ProviderGatewayPort: Sendable {
    var provider: ServiceProvider { get }
    var capabilities: ProviderCapabilities { get }
    func makeRequest(_ plan: ProviderGenerationPlan) -> ProviderGatewayRequest
    func stream(_ request: ProviderGatewayRequest) -> AsyncThrowingStream<ProviderStreamEvent, Error>
    func fallbackModel(for plan: ProviderGenerationPlan) -> String
}

enum ProviderGatewayRequest: Sendable {
    case openrouter(OpenRouterRequestBody)
    case deepseek(DeepSeekRequestBody)
}
