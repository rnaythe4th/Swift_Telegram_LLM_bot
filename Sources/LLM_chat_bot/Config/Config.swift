import Foundation

enum EnvironmentKeys: String {
    case telegramToken = "TG_BOT_TOKEN"
    case deepseekKey   = "DEEPSEEK_API_KEY"
    case companyChatId = "COMPANY_CHAT_ID"
    case routerApiKey = "ROUTER_API_KEY"
}

enum Config {
    static func env(_ key: EnvironmentKeys) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[key.rawValue], !value.isEmpty else {
            throw NSError(domain: "Config", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing env: \(key.rawValue)"])
        }
        return value
    }

    static var telegramBaseURL: String {
        (try? env(.telegramToken)).map { "https://api.telegram.org/bot\($0)" } ?? ""
    }
}

struct AppConfig {
    let telegramToken: String
    let deepseekKey: String
    let routerApiKey: String
    let companyChatId: Int

    var telegramUrl: String {
        "https://api.telegram.org/bot\(telegramToken)"
    }

    static func load() throws -> AppConfig {
        let telegramToken = try Config.env(.telegramToken)
        let deepseekKey = try Config.env(.deepseekKey)
        let routerApiKey = try Config.env(.routerApiKey)
        let companyChatIdRaw = try Config.env(.companyChatId)

        guard let companyChatId = Int(companyChatIdRaw) else {
            throw NSError(
                domain: "Config",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "COMPANY_CHAT_ID must be Int, got: \(companyChatIdRaw)"]
            )
        }

        return AppConfig(
            telegramToken: telegramToken,
            deepseekKey: deepseekKey,
            routerApiKey: routerApiKey,
            companyChatId: companyChatId
        )
    }
}
