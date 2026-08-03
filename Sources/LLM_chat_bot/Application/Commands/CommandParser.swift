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
    case history
    case whitelist
    case defaults
    case chats
    case users
    case presets
    case backupNotify
    case start
    case tenant
    case superadmin
    case buy
    case simulate
    case resetStats
    case chatid
    /// Erases this chat's conversation on request (§7.2).
    case forget
    case inspect
    case ads
    case balance
    case reminders
    case examples
    case referral
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
        case .history:
            return "history"
        case .whitelist:
            return "whitelist"
        case .defaults:
            return "defaults"
        case .chats:
            return "chats"
        case .users:
            return "users"
        case .presets:
            return "presets"
        case .backupNotify:
            return "backup_notify"
        case .start:
            return "start"
        case .tenant:
            return "tenant"
        case .superadmin:
            return "superadmin"
        case .buy:
            return "buy"
        case .simulate:
            return "simulate"
        case .resetStats:
            return "reset_stats"
        case .chatid:
            return "chatid"
        case .forget:
            return "forget"
        case .inspect:
            return "inspect"
        case .ads:
            return "ads"
        case .balance:
            return "balance"
        case .reminders:
            return "reminders"
        case .examples:
            return "examples"
        case .referral:
            return "ref"
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
        
        // Addressing the bot by name is what waives the test-mode suffix, and
        // Telegram's own autocomplete does not promise the case the owner
        // registered — the check above is already case-insensitive, so this one
        // has to be too, or `/model@MyBot` in a suffixed chat resolves to
        // nothing at all.
        let addressedByName = parts.count > 1
            && String(parts[1]).caseInsensitiveCompare(botUsername) == .orderedSame
        let effectiveSuffix = addressedByName ? "" : suffix
        
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
        // The command ends at the first *whitespace*, not at the first space.
        // A newline separates a command from its argument as naturally as a
        // space does — `/setrole` followed by a multi-line description is the
        // ordinary way to write a long role — and splitting on " " alone read
        // `/setrole\nТы…` as one unknown token, so the command silently became
        // a question for the model instead.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let command: String
        let argument: String
        if let breakIndex = trimmed.firstIndex(where: \.isWhitespace) {
            command = String(trimmed[..<breakIndex])
            argument = String(trimmed[breakIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            command = trimmed
            argument = ""
        }

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
