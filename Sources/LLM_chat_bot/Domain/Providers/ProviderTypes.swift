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
    /// The provider ended the generation from inside the SSE stream (HTTP 200
    /// with an `error` payload): rate limit, exhausted credit, moderation.
    /// Carries the upstream detail for the logs; the user-facing wording is
    /// built by `UserFacingError`.
    case upstream(provider: ServiceProvider, code: Int?, message: String?)
    /// The provider accepted the connection and then stopped sending (§4.5).
    /// A distinct case because it is not the provider refusing — it is nobody
    /// saying anything, which needs a different message and a different fix.
    case idleTimeout(seconds: Int)

    var errorDescription: String? {
        switch self {
        case .invalidRequestType(let provider):
            return "Invalid request type for \(provider.commandValue) adapter"
        case .upstream(let provider, let code, let message):
            let codePart = code.map { " \($0)" } ?? ""
            let detail = message.map { ": \($0)" } ?? ""
            return "Upstream error from \(provider.commandValue)\(codePart)\(detail)"
        case .idleTimeout(let seconds):
            return "Provider stopped sending for \(seconds)s"
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

    /// Label shown to users. The raw value stays the API wire format.
    var displayName: String {
        switch self {
        case .low: return "быстро"
        case .medium: return "средне"
        case .high: return "глубоко"
        }
    }

    /// Accepts both the API value and the Russian label users see in the menu,
    /// so `/reasoning глубоко` works as well as `/reasoning high`.
    init?(userInput: String) {
        let normalized = userInput.trimmingCharacters(in: .whitespaces).lowercased()
        if let effort = ReasoningEffort(rawValue: normalized) {
            self = effort
            return
        }
        switch normalized {
        case "быстро": self = .low
        case "средне", "средний": self = .medium
        case "глубоко": self = .high
        default: return nil
        }
    }
}

extension ServiceProvider: CaseIterable {
    public static var allCases: [ServiceProvider] {
        [.openrouter, .deepseek, .yandex]
    }
}
