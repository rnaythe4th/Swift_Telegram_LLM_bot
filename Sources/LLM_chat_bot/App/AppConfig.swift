import Foundation

enum EnvironmentKey: String {
    case telegramToken = "TG_BOT_TOKEN"
    case deepseekKey = "DEEPSEEK_API_KEY"
    case routerApiKey = "ROUTER_API_KEY"
    case companyChatId = "COMPANY_CHAT_ID"
}

enum AppConfigError: LocalizedError {
    case missingEnvironment(EnvironmentKey)
    case invalidCompanyChatId(String)
    
    var errorDescription: String? {
        switch self {
        case .missingEnvironment(let key):
            return "Missing env: \(key.rawValue)"
        case .invalidCompanyChatId(let rawValue):
            return "COMPANY_CHAT_ID must be Int, got: \(rawValue)"
        }
    }
}


struct AppConfig: Sendable {
    let telegramToken: String
    let deepseekKey: String
    let routerApiKey: String
    let companyChatId: Int
    
    static func load() throws -> AppConfig {
        let telegramToken = try env(.telegramToken)
        let deepseekKey = try env(.deepseekKey)
        let routerApiKey = try env(.routerApiKey)
        let companyChatIdRaw = try env(.companyChatId)
        
        guard let companyChatId = Int(companyChatIdRaw) else {
            throw AppConfigError.invalidCompanyChatId(companyChatIdRaw)
        }
        
        return .init(
            telegramToken: telegramToken,
            deepseekKey: deepseekKey,
            routerApiKey: routerApiKey,
            companyChatId: companyChatId
        )
    }
    
    private static func env(_ key: EnvironmentKey) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[key.rawValue], !value.isEmpty else {
            throw AppConfigError.missingEnvironment(key)
        }
        return value
    }
}
