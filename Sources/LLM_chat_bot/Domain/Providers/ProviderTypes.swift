import Foundation

enum ServiceProvider: String, Codable, Sendable, Equatable {
    case openrouter = "Openrouter"
    case deepseek = "Deepseek"
    case yandex = "Yandex"
    
    static func parse(_ rawValue: String) -> Self? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "openrouter":
            return .openrouter
        case "deepseek":
            return .deepseek
        case "yandex":
            return .yandex
        default:
            return nil
        }
    }
    
    var commandValue: String {
        switch self {
        case .openrouter:
            return "openrouter"
        case .deepseek:
            return "deepseek"
        case .yandex:
            return "yandex"
        }
    }
}

struct ProviderCapabilities: Sendable {
    let supportsImageInput: Bool
    let supportsAudioInput: Bool
    let supportsVideoInput: Bool
    let supportsReasoning: Bool
    
    func supports(_ kind: InboundMediaKind) -> Bool {
        switch kind {
        case .image:
            return supportsImageInput
        case .audio:
            return supportsAudioInput
        case .video:
            return supportsVideoInput
        }
    }
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

enum ProviderAdapterError: Error, LocalizedError {
    case invalidRequestType(ServiceProvider)
    
    var errorDescription: String? {
        switch self {
        case .invalidRequestType(let provider):
            return "Invalid request type for \(provider.commandValue) adapter"
        }
    }
}

struct GenerationOptions: Sendable {
    let showStats: Bool
    let showCost: Bool
    let showModel: Bool
    let reasoningEffort: ReasoningEffort?
}

enum ReasoningEffort: String, Codable, Sendable, CaseIterable {
    case low = "low"
    case medium = "medium"
    case high = "high"
}
