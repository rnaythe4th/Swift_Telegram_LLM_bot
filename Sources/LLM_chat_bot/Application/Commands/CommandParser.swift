import Foundation

enum BotCommandName: CaseIterable, Equatable {
    case setRole
    case clearHistory
    case setTemp
    case model
    case defaultRole
    case historyLength
    case mention
    case showModel
    case showCost
    case showTokens
    case help
    case provider
    case testMode
    case reasoning
    case menu
    case reset
    case whitelist
    case defaults
    case chats
    case users
    case unknown
    
    private var baseCommand: String {
        switch self {
        case .setRole:
            return "setrole"
        case .clearHistory:
            return "clear_history"
        case .setTemp:
            return "settemp"
        case .model:
            return "model"
        case .defaultRole:
            return "default_role"
        case .historyLength:
            return "historylength"
        case .showModel:
            return "show_model"
        case .showCost:
            return "show_cost"
        case .showTokens:
            return "show_tokens"
        case .help:
            return "help"
        case .provider:
            return "provider"
        case .testMode:
            return "testmode"
        case .reasoning:
            return "reasoning"
        case .menu:
            return "menu"
        case .reset:
            return "reset"
        case .whitelist:
            return "whitelist"
        case .defaults:
            return "defaults"
        case .chats:
            return "chats"
        case .users:
            return "users"
        case .mention, .unknown:
            return ""
        }
    }
    
    static func resolve(rawCommand: String, botUsername: String, suffix: String) -> Self {
        if rawCommand.caseInsensitiveCompare("@\(botUsername)") == .orderedSame {
            return .mention
        }
        
        guard rawCommand.hasPrefix("/") else {
            return .unknown
        }
        
        let commandBody = rawCommand.dropFirst()
        let parts = commandBody.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        let commandToken = String(parts[0]).lowercased()
        
        if let targetUsername = parts.dropFirst().first,
           String(targetUsername).caseInsensitiveCompare(botUsername) != .orderedSame {
            return .unknown
        }
        
        let effectiveSuffix = (parts.count > 1 && parts[1] == botUsername) ? "" : suffix
        
        return allCases.first { $0.matches(commandToken: commandToken, suffix: effectiveSuffix) } ?? .unknown
    }
    
    private func matches(commandToken: String, suffix: String) -> Bool {
        guard !baseCommand.isEmpty else {
            return false
        }
        
        let expectedToken = suffix.isEmpty ? baseCommand : baseCommand + suffix
        return commandToken == expectedToken
    }
}

struct ParsedBotCommand {
    let name: BotCommandName
    let argument: String
    
    static func parse(from text: String, botUsername: String, suffix: Int?) -> ParsedBotCommand {
        let parts = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .map(String.init)
        
        let command = parts.first ?? ""
        let argument = parts.count > 1 ? parts[1] : ""
        
        return .init(
            name: BotCommandName.resolve(
                rawCommand: command,
                botUsername: botUsername,
                suffix: suffix.map(String.init) ?? ""
            ),
            argument: argument
        )
    }
}
