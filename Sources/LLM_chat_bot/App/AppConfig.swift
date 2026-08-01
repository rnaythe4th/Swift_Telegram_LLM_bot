import Foundation

enum EnvironmentKey: String {
    case telegramToken = "TG_BOT_TOKEN"
    case deepseekKey = "DEEPSEEK_API_KEY"
    case routerApiKey = "ROUTER_API_KEY"
    case companyChatId = "COMPANY_CHAT_ID"
    /// Owner's @username. The composition root should not know a person's name.
    case ownerUsername = "OWNER_USERNAME"
    /// `postgres://user:password@host:5432/database` — the **session** pooler
    /// or a direct connection, never the transaction pooler on 6543 (§1).
    case databaseURL = "DATABASE_URL"
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
    case telegramAPIBase = "TELEGRAM_API_BASE"
}

enum AppConfigError: LocalizedError {
    case missingEnvironment(EnvironmentKey)

    var errorDescription: String? {
        switch self {
        case .missingEnvironment(let key):
            return "Missing env: \(key.rawValue)"
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
    /// Legacy operational chat id. Optional: it feeds one unused member list,
    /// and a required variable that does nothing is one more way to fail to
    /// start for no reason.
    let companyChatId: Int
    /// Owner's @username, without the `@`.
    let ownerUsername: String
    let databaseURL: String?
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
    /// Bot API endpoint. Only ever set in tests, which point it at a local
    /// stand-in to assert what the bot actually sends (§19). Unset in
    /// production — the default is Telegram itself.
    let telegramAPIBase: String

    static func load() throws -> AppConfig {
        let telegramToken = try env(.telegramToken)
        let deepseekKey = try env(.deepseekKey)
        let routerApiKey = try env(.routerApiKey)
        let companyChatId = Int(optionalEnv(.companyChatId) ?? "") ?? 0

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
            ownerUsername: (optionalEnv(.ownerUsername) ?? "maythe4th")
                .trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
                .lowercased(),
            databaseURL: optionalEnv(.databaseURL),
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
            maxConcurrentGenerations: Int(optionalEnv(.maxConcurrentGenerations) ?? "") ?? 64,
            telegramAPIBase: optionalEnv(.telegramAPIBase) ?? TelegramHTTPGateway.defaultAPIBase
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
