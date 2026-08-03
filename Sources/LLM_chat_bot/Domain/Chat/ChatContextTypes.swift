import Foundation

// Value types owned by ChatContextStore: one tenant, one chat's memory and
// the snapshots handed out to callers.

enum SimulatedRole: String, Sendable, CaseIterable {
    case admin
    case regularUser = "user"
}

struct TenantState: Sendable {
    var ownerKey: UserKey
    var defaultModel: String
    var defaultRole: String
    var defaultHistoryLength: Int
    var modelPresets: PresetList
    var tempPresets: PresetList
    var historyLengthPresets: PresetList
    var rolePresets: PresetList
    var whitelistedUserIDs: Set<UserID>
    var adminKeys: Set<UserKey>
    var licensedKeys: Set<UserKey>
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

/// Outcome of a manual "+N days" (super-admin button or `/tenant extend`).
///
/// Three cases rather than `Date?`, because "no such sponsor" and "this
/// sponsor has open-ended access" call for opposite answers: the first is a
/// typo, the second is a request that must be refused rather than granted.
enum SubscriptionExtensionOutcome: Sendable, Equatable {
    case extended(until: Date)
    /// Open-ended access; adding days would replace it with an end date.
    case alreadyUnlimited
    case unknownTenant
}

struct TenantStatsRow: Sendable {
    /// Storage key — pass back to the store; `label` is what people read.
    let key: UserKey
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
    var chatModelPresets: PresetList
    var chatTempPresets: PresetList
    var chatHistoryLengthPresets: PresetList
    var chatRolePresets: PresetList
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
    /// Reference mode this chat was last switched into. Cleared by any manual
    /// edit of a setting the mode owns, so the settings page can honestly say
    /// whether the chat still matches the mode or has drifted off it.
    var activeModeID: String? = nil
}

extension ChatContext {
    /// What a chat's memory and answer style may be set to — whatever the value
    /// came from: a command, a button, a mode, a row restored from an older
    /// build. The store clamps to these itself, so a caller that forgets to
    /// validate cannot widen them. They used to be six copies of `1...50` and
    /// `0.0...2.0` spelled out at the call sites, and a bound kept in six
    /// places is a bound that drifts.
    static let historyRange = 1...50
    static let tempRange: ClosedRange<Float> = 0.0...2.0

    /// Ceiling on the conversation carried into a request, on top of the
    /// message count. A model answer has no size limit of its own, and every
    /// remembered message is re-sent on *every* turn — so without this one
    /// runaway answer keeps being paid for, on every turn, and the chat's
    /// `jsonb` row is rewritten at that size twice a second while the chat is
    /// busy. Measured in UTF-8 bytes because that is what both the wire and the
    /// column charge for; the system message is outside the budget (it is the
    /// role, and dropping it changes who the bot is).
    static let historyByteBudget = 200_000
}

extension ClosedRange {
    /// The nearest value inside the range. Bounds belong to the domain, so the
    /// store clamps rather than trusting the number it was handed.
    func clamping(_ value: Bound) -> Bound {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
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

    // The model id and the role are arbitrary text somebody typed — «✏️ Своя
    // модель» and «✏️ Своя роль» are open to every member of a chat — and both
    // are printed straight into HTML on the settings pages. Stored raw (the
    // role is what the model is told, the id is what the provider is asked
    // for), escaped where they turn into markup, exactly like `Preset`:
    // an unescaped `<` does not garble a page, it makes Telegram refuse the
    // whole message, so the menu stops opening until somebody fixes it by
    // command.
    var escapedModel: String { MessageText.escaped(model) }
    var escapedRole: String { MessageText.escaped(role) }
    var escapedModelProviderRouting: String? { modelProviderRouting.map(MessageText.escaped) }
}
