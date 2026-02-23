import Foundation

enum BotCommandName {
    case setRole
    case clearHistory
    case setTemp
    case model
    case tokensToggle
    case defaultRole
    case historyLength
    case mention
    case unknown

    init(rawCommand: String) {
        switch rawCommand {
        case "/setrole":
            self = .setRole
        case "/clear_history", "/clear_history@SwiftPT_bot":
            self = .clearHistory
        case "/settemp":
            self = .setTemp
        case "/model":
            self = .model
        case "/tokens_toggle", "/tokens_toggle@SwiftPT_bot":
            self = .tokensToggle
        case "/default_role", "/default_role@SwiftPT_bot":
            self = .defaultRole
        case "/historylength", "/historylength@SwiftPT_bot":
            self = .historyLength
        case "@SwiftPT_bot":
            self = .mention
        default:
            self = .unknown
        }
    }
}

struct ParsedBotCommand {
    let name: BotCommandName
    let argument: String

    static func parse(from text: String) -> ParsedBotCommand {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .map(String.init)

        let command = parts.first ?? ""
        let argument = parts.count > 1 ? parts[1] : ""
        return ParsedBotCommand(name: BotCommandName(rawCommand: command), argument: argument)
    }
}
