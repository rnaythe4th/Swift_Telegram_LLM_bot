import Foundation

enum EnvironmentKey: String {
    case telegramToken = "TG_BOT_TOKEN"
    case deepseekKey = "DEEPSEEK_API_KEY"
    case routerApiKey = "ROUTER_API_KEY"
    case companyChatId = "COMPANY_CHAT_ID"
    /// Owner's @invoker. The composition root should not know a person's name.
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
    /// `json` puts one JSON object per line, which hosted log search indexes;
    /// anything else keeps the human-readable form.
    case logFormat = "LOG_FORMAT"
    case maxConcurrentGenerations = "MAX_CONCURRENT_GENERATIONS"
    case telegramAPIBase = "TELEGRAM_API_BASE"
    /// 32 bytes of base64 (`openssl rand -base64 32`). Encrypts the payment
    /// credentials stored in the database (§5.6). Optional, but without it the
    /// card token and the checkout signing words sit in the row as plain text.
    case stateEncryptionKey = "STATE_ENCRYPTION_KEY"
}

enum AppConfigError: LocalizedError {
    case missingEnvironment(EnvironmentKey)
    case badEncryptionKey
    case badWebhookSecret

    var errorDescription: String? {
        switch self {
        case .missingEnvironment(let key):
            return "Missing env: \(key.rawValue)"
        case .badWebhookSecret:
            return """
                \(EnvironmentKey.webhookSecret.rawValue) must be 1–256 characters of A-Z, a-z, 0-9, \
                `_` or `-` — Telegram rejects anything else. Refusing to start: setWebhook would fail, \
                the bot would quietly fall back to long polling, and the only sign would be one line in \
                the log of a bot that otherwise looks healthy.
                """
        case .badEncryptionKey:
            return """
                \(EnvironmentKey.stateEncryptionKey.rawValue) must be 32 bytes of base64 \
                (generate one with `openssl rand -base64 32`). Refusing to start: a key that \
                cannot be read would store payment credentials in the clear without saying so.
                """
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
    let companyChatId: ChatID
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
    let ownerUserID: UserID?
    let maxConcurrentGenerations: Int
    /// Bot API endpoint. Only ever set in tests, which point it at a local
    /// stand-in to assert what the bot actually sends (§19). Unset in
    /// production — the default is Telegram itself.
    let telegramAPIBase: String
    /// See `EnvironmentKey.stateEncryptionKey`.
    let stateEncryptionKey: String?

    static func load() throws -> AppConfig {
        let telegramToken = try env(.telegramToken)
        let deepseekKey = try env(.deepseekKey)
        let routerApiKey = try env(.routerApiKey)
        let companyChatId = ChatID(Int(optionalEnv(.companyChatId) ?? "") ?? 0)

        let healthPort = Int(optionalEnv(.healthPort) ?? "") ?? 8000

        // Railway injects RAILWAY_PUBLIC_DOMAIN for services with a domain;
        // an explicit WEBHOOK_PUBLIC_URL always wins.
        let webhookPublicURL = (optionalEnv(.webhookPublicURL)
            ?? optionalEnv(.railwayPublicDomain).map { "https://\($0)" })
            .map(normalizedOrigin)

        let updateMode = optionalEnv(.updateMode).flatMap { UpdateMode(rawValue: $0.lowercased()) } ?? .auto

        let webhookSecret = optionalEnv(.webhookSecret)
        if let webhookSecret, !isValidWebhookSecret(webhookSecret) {
            throw AppConfigError.badWebhookSecret
        }

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
            webhookSecret: webhookSecret,
            metricsToken: optionalEnv(.metricsToken),
            ownerUserID: optionalEnv(.ownerUserID).flatMap { Int($0) }.flatMap { $0 > 0 ? UserID($0) : nil },
            maxConcurrentGenerations: Int(optionalEnv(.maxConcurrentGenerations) ?? "") ?? 64,
            telegramAPIBase: optionalEnv(.telegramAPIBase) ?? TelegramHTTPGateway.defaultAPIBase,
            stateEncryptionKey: optionalEnv(.stateEncryptionKey)
        )
    }

    /// Origin with no trailing slash, because everything that uses it appends a
    /// path (`…/telegram/webhook`, `…/payments/<vendor>`).
    ///
    /// A pasted URL ending in `/` is an easy mistake with an expensive failure:
    /// `setWebhook` accepts `https://host//telegram/webhook` happily, our router
    /// does not match that path, and Telegram then delivers into a 404 forever.
    /// Nothing looks wrong — `/ready` is 200, the log says "webhook registered"
    /// — the bot simply never hears from anyone again.
    /// Telegram's rule for `secret_token`: 1–256 characters, and only
    /// `A-Z a-z 0-9 _ -`.
    ///
    /// Checked here rather than discovered at `setWebhook`, because the failure
    /// is invisible in exactly the way that matters: the call fails, the bot
    /// falls back to long polling, everything keeps working, and the webhook
    /// the deployment was built around is simply never registered.
    static func isValidWebhookSecret(_ value: String) -> Bool {
        guard (1...256).contains(value.count) else { return false }
        return value.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "_"), UInt8(ascii: "-"):
                return true
            default:
                return false
            }
        }
    }

    static func normalizedOrigin(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        while value.hasSuffix("/") { value.removeLast() }
        return value
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
