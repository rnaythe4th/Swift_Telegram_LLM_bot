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
    var whitelistedUserIDs: [Int]
    var adminUsernames: [String]
    var defaultModel: String
    var defaultRole: String
    var defaultHistoryLength: Int
    var telegramUpdateOffset: Int
    var modelPresets: [Preset]
    var tempPresets: [Preset]
    var historyLengthPresets: [Preset]
    var rolePresets: [Preset]

    var isEmpty: Bool {
        contexts.isEmpty && whitelistedUserIDs.isEmpty && adminUsernames == ["maythe4th"]
    }
}
