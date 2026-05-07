import Foundation

struct CumulativeUsage: Codable, Sendable {
    var totalTokens: Double
    var totalCost: Double
    var generationCount: Int

    static let zero = CumulativeUsage(totalTokens: 0, totalCost: 0, generationCount: 0)

    mutating func add(_ usage: StreamUsageSummary?) {
        totalTokens += usage?.totalTokens ?? 0
        totalCost += usage?.cost ?? 0
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
}

struct ChatContextSnapshot: Codable, Sendable {
    var role: String
    var history: [ChatMessage]
    var model: String
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
