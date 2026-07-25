import Foundation

struct CumulativeUsage: Codable, Sendable {
    var totalTokens: Double
    /// Real provider cost (what the bot owner actually pays).
    var totalCost: Double
    var generationCount: Int
    /// Marked-up cost shown to and charged from customers. 0 in rows written
    /// before markup existed — display falls back to totalCost × multiplier.
    var totalBilledCost: Double

    static let zero = CumulativeUsage(totalTokens: 0, totalCost: 0, generationCount: 0, totalBilledCost: 0)

    init(totalTokens: Double, totalCost: Double, generationCount: Int, totalBilledCost: Double = 0) {
        self.totalTokens = totalTokens
        self.totalCost = totalCost
        self.generationCount = generationCount
        self.totalBilledCost = totalBilledCost
    }

    enum CodingKeys: String, CodingKey {
        case totalTokens, totalCost, generationCount, totalBilledCost
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalTokens = try container.decode(Double.self, forKey: .totalTokens)
        totalCost = try container.decode(Double.self, forKey: .totalCost)
        generationCount = try container.decode(Int.self, forKey: .generationCount)
        totalBilledCost = try container.decodeIfPresent(Double.self, forKey: .totalBilledCost) ?? 0
    }

    mutating func add(_ usage: StreamUsageSummary?, priceMultiplier: Double = 1.0) {
        totalTokens += usage?.totalTokens ?? 0
        let real = usage?.cost ?? 0
        totalCost += real
        totalBilledCost += real * priceMultiplier
        generationCount += 1
    }
}

struct TenantStateSnapshot: Codable, Sendable {
    var ownerUsername: String
    var defaultModel: String
    var defaultRole: String
    var defaultHistoryLength: Int
    var modelPresets: [Preset]
    var tempPresets: [Preset]
    var historyLengthPresets: [Preset]
    var rolePresets: [Preset]
    var whitelistedUserIDs: [Int]
    var adminUsernames: [String]
    var licensedUsernames: [String]?
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
}

struct BotStateSnapshot: Codable, Sendable {
    var contexts: [String: ChatContextSnapshot]
    var tenants: [String: TenantStateSnapshot]?
    var chatOwnership: [String: String]?
    var telegramUpdateOffset: Int
    var starsPrice: Int?
    var freeModelIDs: [String]?
    var crypto: CryptoConfigSnapshot?
    var superAdminUsernames: [String]?

    // Legacy fields — present in pre-tenant snapshots, absent in new ones
    var whitelistedUserIDs: [Int]?
    var adminUsernames: [String]?
    var defaultModel: String?
    var defaultRole: String?
    var defaultHistoryLength: Int?
    var modelPresets: [Preset]?
    var tempPresets: [Preset]?
    var historyLengthPresets: [Preset]?
    var rolePresets: [Preset]?
}
