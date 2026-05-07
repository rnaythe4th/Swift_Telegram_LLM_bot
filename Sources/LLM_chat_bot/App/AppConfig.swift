import Foundation

enum EnvironmentKey: String {
    case telegramToken = "TG_BOT_TOKEN"
    case deepseekKey = "DEEPSEEK_API_KEY"
    case routerApiKey = "ROUTER_API_KEY"
    case companyChatId = "COMPANY_CHAT_ID"
    case supabaseURL = "SUPABASE_URL"
    case supabaseAnonKey = "SUPABASE_ANON_KEY"
    case healthPort = "PORT"
    case bscscanApiKey = "BSCSCAN_API_KEY"
    case etherscanApiKey = "ETHERSCAN_API_KEY"
    case trongridApiKey = "TRONGRID_API_KEY"
    case tonapiKey = "TONAPI_KEY"
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
    let supabaseURL: String?
    let supabaseAnonKey: String?
    let healthPort: Int
    let bscscanApiKey: String?
    let etherscanApiKey: String?
    let trongridApiKey: String?
    let tonapiKey: String?

    static func load() throws -> AppConfig {
        let telegramToken = try env(.telegramToken)
        let deepseekKey = try env(.deepseekKey)
        let routerApiKey = try env(.routerApiKey)
        let companyChatIdRaw = try env(.companyChatId)

        guard let companyChatId = Int(companyChatIdRaw) else {
            throw AppConfigError.invalidCompanyChatId(companyChatIdRaw)
        }

        let supabaseURL = optionalEnv(.supabaseURL)
        let supabaseAnonKey = optionalEnv(.supabaseAnonKey)
        let healthPort = Int(optionalEnv(.healthPort) ?? "") ?? 8000

        return .init(
            telegramToken: telegramToken,
            deepseekKey: deepseekKey,
            routerApiKey: routerApiKey,
            companyChatId: companyChatId,
            supabaseURL: supabaseURL,
            supabaseAnonKey: supabaseAnonKey,
            healthPort: healthPort,
            bscscanApiKey: optionalEnv(.bscscanApiKey),
            etherscanApiKey: optionalEnv(.etherscanApiKey),
            trongridApiKey: optionalEnv(.trongridApiKey),
            tonapiKey: optionalEnv(.tonapiKey)
        )
    }
    
    private static func env(_ key: EnvironmentKey) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[key.rawValue], !value.isEmpty else {
            throw AppConfigError.missingEnvironment(key)
        }
        return value
    }

    private static func optionalEnv(_ key: EnvironmentKey) -> String? {
        guard let value = ProcessInfo.processInfo.environment[key.rawValue], !value.isEmpty else {
            return nil
        }
        return value
    }
}
