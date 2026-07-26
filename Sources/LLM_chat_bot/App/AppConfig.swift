import Foundation

enum EnvironmentKey: String {
    case telegramToken = "TG_BOT_TOKEN"
    case deepseekKey = "DEEPSEEK_API_KEY"
    case routerApiKey = "ROUTER_API_KEY"
    case companyChatId = "COMPANY_CHAT_ID"
    case supabaseURL = "SUPABASE_URL"
    case supabaseAnonKey = "SUPABASE_ANON_KEY"
    case supabaseServiceKey = "SUPABASE_SERVICE_KEY"
    case healthPort = "PORT"
    case bscscanApiKey = "BSCSCAN_API_KEY"
    case etherscanApiKey = "ETHERSCAN_API_KEY"
    case trongridApiKey = "TRONGRID_API_KEY"
    case tonapiKey = "TONAPI_KEY"
    case updateMode = "UPDATE_MODE"
    case webhookPublicURL = "WEBHOOK_PUBLIC_URL"
    case railwayPublicDomain = "RAILWAY_PUBLIC_DOMAIN"
    case webhookSecret = "TELEGRAM_WEBHOOK_SECRET"
    case metricsToken = "METRICS_TOKEN"
    case ownerUserID = "OWNER_USER_ID"
    case logLevel = "LOG_LEVEL"
    case maxConcurrentGenerations = "MAX_CONCURRENT_GENERATIONS"
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

/// How updates are received from Telegram.
/// `auto` picks webhook when a public URL is available (Railway) and falls
/// back to long polling (local development).
enum UpdateMode: String, Sendable {
    case auto
    case webhook
    case polling
}

struct AppConfig: Sendable {
    let telegramToken: String
    let deepseekKey: String
    let routerApiKey: String
    let companyChatId: Int
    let supabaseURL: String?
    let supabaseAnonKey: String?
    let supabaseServiceKey: String?
    let healthPort: Int
    let bscscanApiKey: String?
    let etherscanApiKey: String?
    let trongridApiKey: String?
    let tonapiKey: String?
    let updateMode: UpdateMode
    let webhookPublicURL: String?
    let webhookSecret: String?
    /// Bearer token guarding `GET /metrics`. The endpoint sits on the same
    /// public domain as the webhook and reports revenue, funnel counts and
    /// subscriber tallies — business intelligence that has no business being
    /// world-readable. Unset → the webhook secret is used instead, so the
    /// endpoint is never open; Railway's healthcheck probes `/ready`, which
    /// stays public.
    let metricsToken: String?
    /// Owner's Telegram userID. Optional but strongly recommended: without it
    /// the bot recognises its owner by the configured @username, and a username
    /// is rented — whoever registers it after the owner drops it inherits root
    /// on their first message. A userID cannot be transferred.
    let ownerUserID: Int?
    let maxConcurrentGenerations: Int

    /// Server-side Supabase key: the service key bypasses RLS and never ships
    /// to clients — preferred. The anon key remains a fallback for setups
    /// created before the split.
    var supabaseKey: String? { supabaseServiceKey ?? supabaseAnonKey }
    var usesAnonSupabaseKey: Bool { supabaseServiceKey == nil && supabaseAnonKey != nil }

    static func load() throws -> AppConfig {
        let telegramToken = try env(.telegramToken)
        let deepseekKey = try env(.deepseekKey)
        let routerApiKey = try env(.routerApiKey)
        let companyChatIdRaw = try env(.companyChatId)

        guard let companyChatId = Int(companyChatIdRaw) else {
            throw AppConfigError.invalidCompanyChatId(companyChatIdRaw)
        }

        let healthPort = Int(optionalEnv(.healthPort) ?? "") ?? 8000

        // Railway injects RAILWAY_PUBLIC_DOMAIN for services with a domain;
        // an explicit WEBHOOK_PUBLIC_URL always wins.
        let webhookPublicURL = optionalEnv(.webhookPublicURL)
            ?? optionalEnv(.railwayPublicDomain).map { "https://\($0)" }

        let updateMode = optionalEnv(.updateMode).flatMap { UpdateMode(rawValue: $0.lowercased()) } ?? .auto

        return .init(
            telegramToken: telegramToken,
            deepseekKey: deepseekKey,
            routerApiKey: routerApiKey,
            companyChatId: companyChatId,
            supabaseURL: optionalEnv(.supabaseURL),
            supabaseAnonKey: optionalEnv(.supabaseAnonKey),
            supabaseServiceKey: optionalEnv(.supabaseServiceKey),
            healthPort: healthPort,
            bscscanApiKey: optionalEnv(.bscscanApiKey),
            etherscanApiKey: optionalEnv(.etherscanApiKey),
            trongridApiKey: optionalEnv(.trongridApiKey),
            tonapiKey: optionalEnv(.tonapiKey),
            updateMode: updateMode,
            webhookPublicURL: webhookPublicURL,
            webhookSecret: optionalEnv(.webhookSecret),
            metricsToken: optionalEnv(.metricsToken),
            ownerUserID: optionalEnv(.ownerUserID).flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil },
            maxConcurrentGenerations: Int(optionalEnv(.maxConcurrentGenerations) ?? "") ?? 64
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
