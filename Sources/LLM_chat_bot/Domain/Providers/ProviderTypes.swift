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

/// Token counts and price of one answer, as reported by the provider.
///
/// Every number here is somebody else's JSON, and it is not decoration: the
/// counts are added into the chat's persisted totals and the price is charged
/// to a wallet. So they are sanitised at construction — `NaN` poisons a
/// cumulative total for good (and `JSONEncoder` refuses to write it, taking the
/// whole row with it), an infinity or an absurd magnitude traps the moment
/// anything converts it to `Int` for display. Nonsense in becomes "unknown"
/// out, which the footer already knows how to render.
struct StreamUsageSummary: Sendable {
    let promptTokens: Double?
    let completionTokens: Double?
    let totalTokens: Double?
    let cacheHitTokens: Double?
    let cacheWriteTokens: Double?
    let cacheMissTokens: Double?
    let reasoningTokens: Double?
    let cost: Double?

    /// A trillion tokens for one answer is already six orders of magnitude
    /// past any real model; past that it is a broken response, not a big one.
    static let maxPlausibleTokens: Double = 1e12

    init(
        promptTokens: Double?,
        completionTokens: Double?,
        totalTokens: Double?,
        cacheHitTokens: Double?,
        cacheWriteTokens: Double?,
        cacheMissTokens: Double?,
        reasoningTokens: Double?,
        cost: Double?
    ) {
        self.promptTokens = Self.plausibleTokens(promptTokens)
        self.completionTokens = Self.plausibleTokens(completionTokens)
        self.totalTokens = Self.plausibleTokens(totalTokens)
        self.cacheHitTokens = Self.plausibleTokens(cacheHitTokens)
        self.cacheWriteTokens = Self.plausibleTokens(cacheWriteTokens)
        self.cacheMissTokens = Self.plausibleTokens(cacheMissTokens)
        self.reasoningTokens = Self.plausibleTokens(reasoningTokens)
        self.cost = Self.plausibleCost(cost)
    }

    private static func plausibleTokens(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(0, value), maxPlausibleTokens)
    }

    /// The price is clamped, not dropped: `Money.usd` saturates on its own, and
    /// a refusal to name a price is what the footer shows as «—».
    private static func plausibleCost(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return max(0, value)
    }
}

/// Why the model stopped. Only the answers that change what the user should do
/// get a case of their own; everything else is upstream vocabulary.
enum StreamFinishReason: Sendable, Equatable {
    /// The model finished on its own.
    case stop
    /// The answer hit the token ceiling and is cut off mid-thought.
    case length
    case contentFilter
    case other(String)

    init(rawValue: String) {
        switch rawValue {
        case "stop", "end_turn": self = .stop
        case "length", "max_tokens": self = .length
        case "content_filter": self = .contentFilter
        default: self = .other(rawValue)
        }
    }
}

struct StreamMeta: Sendable {
    let model: String?
    let usage: StreamUsageSummary?
    /// Absent when the provider never said — which is not the same as `.stop`,
    /// and must not be read as "the answer is complete".
    let finishReason: StreamFinishReason?

    init(model: String?, usage: StreamUsageSummary?, finishReason: StreamFinishReason? = nil) {
        self.model = model
        self.usage = usage
        self.finishReason = finishReason
    }
}

enum ProviderStreamEvent: Sendable {
    case text(String)
    case meta(StreamMeta)
    /// The provider is working but has nothing to show yet — a thinking model,
    /// a keep-alive comment, a chunk this version does not decode. Nothing to
    /// display; it exists so that "slow" is not mistaken for "dead"
    /// (`StreamWatchdog`).
    case keepAlive
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
