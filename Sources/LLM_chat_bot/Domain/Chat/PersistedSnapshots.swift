import Foundation

/// Running usage totals for one chat or one tenant.
///
/// Tokens stay a `Double` — they are a count nobody bills on. Both costs are
/// `Money`, because they are compared with a spend cap and reconciled against
/// the ledger, and neither works on floating point.
struct CumulativeUsage: Codable, Sendable, Equatable {
    var totalTokens: Double
    /// Real provider cost (what the bot owner actually pays).
    var totalCost: Money
    var generationCount: Int
    /// Marked-up cost shown to and charged from customers.
    var totalBilledCost: Money

    static let zero = CumulativeUsage(totalTokens: 0, totalCost: .zero, generationCount: 0, totalBilledCost: .zero)

    init(totalTokens: Double, totalCost: Money, generationCount: Int, totalBilledCost: Money = .zero) {
        self.totalTokens = totalTokens
        self.totalCost = totalCost
        self.generationCount = generationCount
        self.totalBilledCost = totalBilledCost
    }

    enum CodingKeys: String, CodingKey {
        case totalTokens, totalCost, generationCount, totalBilledCost
    }

    /// Every field optional on the way in. This is the payload of a `jsonb`
    /// column whose default is `'{}'`, and Swift's synthesised decoder would
    /// throw on it — turning a tenant row created by a payment into a row the
    /// next boot cannot read.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            totalTokens: try c.decodeIfPresent(Double.self, forKey: .totalTokens) ?? 0,
            totalCost: try c.decodeIfPresent(Money.self, forKey: .totalCost) ?? .zero,
            generationCount: try c.decodeIfPresent(Int.self, forKey: .generationCount) ?? 0,
            totalBilledCost: try c.decodeIfPresent(Money.self, forKey: .totalBilledCost) ?? .zero
        )
    }

    mutating func add(_ usage: StreamUsageSummary?, markupPercent: Int) {
        totalTokens += usage?.totalTokens ?? 0
        let real = Money.usd(usage?.cost ?? 0)
        totalCost = totalCost + real
        totalBilledCost = totalBilledCost + real.multiplied(byPercent: markupPercent)
        generationCount += 1
    }
}

struct TenantStateSnapshot: Codable, Sendable {
    var ownerKey: UserKey
    var defaultModel: String
    var defaultRole: String
    var defaultHistoryLength: Int
    var modelPresets: [Preset]
    var tempPresets: [Preset]
    var historyLengthPresets: [Preset]
    var rolePresets: [Preset]
    var whitelistedUserIDs: [UserID]
    var adminKeys: [UserKey]
    var licensedKeys: [UserKey]?
    var cumulativeUsage: CumulativeUsage?
    // Subscription fields; absent in pre-subscription rows (=> unlimited)
    var createdAt: Date?
    var paidUntil: Date?
    // Lifecycle outreach (roadmap step 8); absent in pre-reminder rows.
    var noticeCycleUntil: Date?
    var sentNotices: [String]?
    var winbackDiscount: SubscriptionDiscount?
    var remindersOptOut: Bool?
}

struct ChatContextSnapshot: Codable, Sendable {
    var role: String
    var history: [ChatMessage]
    var model: String
    // OpenRouter provider routing pin; absent in pre-routing snapshots
    var modelProvider: String?
    var temp: Float
    var showStats: Bool
    var maxHistory: Int
    var showCost: Bool
    var showModel: Bool
    var provider: ServiceProvider
    var suffix: Int?
    var reasoningEffort: ReasoningEffort?
    var backupNotify: Bool
    var cumulativeUsage: CumulativeUsage?
    var chatModelPresets: [Preset]?
    var chatTempPresets: [Preset]?
    var chatHistoryLengthPresets: [Preset]?
    var chatRolePresets: [Preset]?
    // Ad delivery counters; absent in pre-ads rows
    var adReplyCounter: Int?
    var adLastShownAt: Date?
    // Funnel: whether this chat's first-message activation was already counted;
    // absent in pre-funnel rows (treated as false → re-counted once).
    var funnelCounted: Bool?
    // Paid model parked by the daily-cap fallback, restored once the chat has
    // full access again; absent when nothing was downgraded.
    var downgradedFrom: String?
    // Reference mode the chat currently sits on; absent when its settings were
    // hand-edited or the chat predates modes.
    var activeMode: String?
}

// The whole-state `BotStateSnapshot` blob and its one-time import are gone
// (§2.2): the bot never ran against a live database under that format, and a
// migration path that can never execute is a path where "a stale blob
// overwrote live rows" waits for its chance. Chat contexts and tenant
// documents keep their `Codable` snapshots above — those are the jsonb
// payloads of `bot_chat_context.data` and `bot_tenant.presets`.
