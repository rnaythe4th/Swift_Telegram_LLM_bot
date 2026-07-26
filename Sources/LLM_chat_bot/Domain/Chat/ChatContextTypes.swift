import Foundation

// Value types owned by ChatContextStore: one tenant, one chat's memory and
// the snapshots handed out to callers.

enum SimulatedRole: String, Sendable, CaseIterable {
    case admin
    case regularUser = "user"
}

struct TenantState: Sendable {
    var ownerUsername: String
    var defaultModel: String
    var defaultRole: String
    var defaultHistoryLength: Int
    var modelPresets: [Preset]
    var tempPresets: [Preset]
    var historyLengthPresets: [Preset]
    var rolePresets: [Preset]
    var whitelistedUserIDs: Set<Int>
    var adminUsernames: Set<String>
    var licensedUsernames: Set<String>
    var cumulativeUsage: CumulativeUsage
    var createdAt: Date?
    /// Subscription end. nil = unlimited (root owner, manually added tenants).
    var paidUntil: Date?
    /// Lifecycle notices already delivered for the cycle ending at this date
    /// (roadmap step 8). A renewal moves `paidUntil`, which drops the set — so
    /// every subscription cycle gets its own reminder exactly once.
    var noticeCycleUntil: Date?
    var sentNotices: Set<String> = []
    /// Winback discount granted after expiry; consumed by the next purchase.
    var winbackDiscount: SubscriptionDiscount?
    /// Sponsor asked not to be reminded (toggle in their admin panel).
    var remindersOptOut: Bool = false

    var isActive: Bool {
        guard let paidUntil else { return true }
        return paidUntil > Date()
    }
}

/// Outcome of a paid activation — drives the confirmation message wording.
enum SubscriptionActivation: Sendable {
    case started(until: Date)
    case extended(until: Date)
    case alreadyUnlimited
}

struct TenantStatsRow: Sendable {
    /// Storage key — pass back to the store; `label` is what people read.
    let username: String
    let label: String
    let usage: CumulativeUsage
    let chatCount: Int
    let licensedUserCount: Int
    let isSuperAdmin: Bool
    let paidUntil: Date?
    let isActive: Bool
}

struct ChatContext: Sendable {
    enum PendingTurnState: Sendable {
        case pending
        case completed(String)
        case cancelled
    }

    struct PendingTurn: Sendable {
        let generationID: GenerationID
        let userMessage: ChatMessage
        var state: PendingTurnState
    }

    var role: String
    var history: [ChatMessage]
    var pendingTurns: [PendingTurn]
    var model: String
    // OpenRouter upstream provider pin for the current model (provider routing).
    var modelProviderRouting: String?
    var temp: Float
    var showStats: Bool
    var maxHistory: Int
    var showCost: Bool
    var showModel: Bool
    var provider: ServiceProvider
    var suffix: Int?
    var reasoningEffort: ReasoningEffort?
    var backupNotify: Bool
    var cumulativeUsage: CumulativeUsage
    var chatModelPresets: [Preset]
    var chatTempPresets: [Preset]
    var chatHistoryLengthPresets: [Preset]
    var chatRolePresets: [Preset]
    /// Bot replies in this chat since the last ad impression.
    var adReplyCounter: Int = 0
    var adLastShownAt: Date? = nil
    /// Funnel analytics: set once this chat produces its first LLM turn, so the
    /// `firstMessage` (activation) event is counted at most once per chat.
    var funnelFirstMessageCounted: Bool = false
    /// Paid model the daily-cap gate swapped out for a free one (roadmap step
    /// 6). Without it a purchase looks like it changed nothing: the chat would
    /// keep answering on the fallback model until someone reopened the model
    /// menu. Cleared the moment the model is chosen again, by anyone.
    var downgradedFromModel: String? = nil
}

struct GenerationSnapshot: Sendable {
    let provider: ServiceProvider
    let model: String
    let providerRouting: String?
    let temperature: Float
    let options: GenerationOptions
    let messages: [ChatMessage]
}

struct HelpData: Sendable {
    let model: String
    let modelProviderRouting: String?
    let role: String
    let temp: Float
    let maxHistory: Int
    let showTokens: Bool
    let showCost: Bool
    let showModel: Bool
    let defaultRole: String
    let provider: ServiceProvider
    let reasoningEffort: ReasoningEffort?
    let testModeSuffix: Int?
    let backupNotify: Bool
    let cumulativeUsage: CumulativeUsage
}
