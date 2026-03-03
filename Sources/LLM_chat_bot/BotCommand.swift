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
    case testMode
    case reasoning

    init(rawCommand: String, botUsername: String, suffix: String) {
        switch rawCommand {
        case "/setrole\(suffix)":
            self = .setRole
        case "/clear_history\(suffix)", "/clear_history@\(botUsername)":
            self = .clearHistory
        case "/settemp\(suffix)":
            self = .setTemp
        case "/model\(suffix)":
            self = .model
        case "/show_tokens\(suffix)", "/show_tokens@\(botUsername)":
            self = .showTokens
        case "/default_role\(suffix)", "/default_role@\(botUsername)":
            self = .defaultRole
        case "/historylength\(suffix)", "/historylength@\(botUsername)":
            self = .historyLength
        case "@\(botUsername)":
            self = .mention
        case "/show_model\(suffix)", "/show_model@\(botUsername)":
            self = .showModel
        case "/show_cost\(suffix)", "/show_cost@\(botUsername)":
            self = .showCost
        case "/help\(suffix)", "/help@\(botUsername)":
            self = .help
        case "/provider\(suffix)":
            self = .provider
        case "/testmode\(suffix)", "/testmode@\(botUsername)":
            self = .testMode
        case "/reasoning\(suffix)", "/reasoning@\(botUsername)":
            self = .reasoning
        default:
            self = .unknown
        }
    }
}

struct ParsedBotCommand {
    let name: BotCommandName
    let argument: String

    static func parse(from text: String, botUsername: String, suffix: Int?) -> ParsedBotCommand {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .map(String.init)
        
        let command = parts.first ?? ""
        let argument = parts.count > 1 ? parts[1] : ""
        return ParsedBotCommand(name: BotCommandName(rawCommand: command, botUsername: botUsername, suffix: suffix.map{String($0)} ?? ""), argument: argument)
    }
}
