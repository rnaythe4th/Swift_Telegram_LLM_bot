import Foundation

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
