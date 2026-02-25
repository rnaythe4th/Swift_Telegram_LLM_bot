import Foundation

enum BotCommandName {
    case setRole
    case clearHistory
    case setTemp
    case model
    //case tokensToggle
    case defaultRole
    case historyLength
    case mention
    case unknown
    case showModel
    case showCost
    case showTokens
    case help
    case provider

    init(rawCommand: String, botUsername: String) {
        switch rawCommand {
        case "/setrole":
            self = .setRole
        case "/clear_history", "/clear_history@\(botUsername)":
            self = .clearHistory
        case "/settemp":
            self = .setTemp
        case "/model":
            self = .model
        case "/show_tokens", "/show_tokens@\(botUsername)":
            self = .showTokens
        case "/default_role", "/default_role@\(botUsername)":
            self = .defaultRole
        case "/historylength", "/historylength@\(botUsername)":
            self = .historyLength
        case "@\(botUsername)":
            self = .mention
        case "/show_model", "/show_model@\(botUsername)":
            self = .showModel
        case "/show_cost", "/show_cost@\(botUsername)":
            self = .showCost
        case "/help", "/help@\(botUsername)":
            self = .help
        case "/provider":
            self = .provider
        default:
            self = .unknown
        }
    }
}

struct ParsedBotCommand {
    let name: BotCommandName
    let argument: String

    static func parse(from text: String, botUsername: String) -> ParsedBotCommand {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .map(String.init)

        let command = parts.first ?? ""
        let argument = parts.count > 1 ? parts[1] : ""
        return ParsedBotCommand(name: BotCommandName(rawCommand: command, botUsername: botUsername), argument: argument)
    }
}
