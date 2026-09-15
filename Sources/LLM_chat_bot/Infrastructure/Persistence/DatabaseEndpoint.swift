import Foundation
import Logging
import NIOSSL
import PostgresNIO

/// Where the database is and how to talk to it, parsed from one `DATABASE_URL`.
///
/// `postgres://user:password@host:port/database?sslmode=require`
///
/// **Use the session-mode pooler, not the transaction-mode one.** Supabase
/// offers three addresses and only two of them behave: direct (5432) and the
/// pooler in *session* mode (5432) keep a connection to themselves for its
/// lifetime; the pooler in *transaction* mode (6543) hands it back after every
/// statement. In transaction mode `pg_try_advisory_lock` returns true and then
/// silently drops the lock with the connection — the single-writer guarantee of
/// §3.1 evaporates without a single error in the log. Direct connections at
/// new Supabase projects are IPv6-only, so the session pooler is the practical
/// choice. See DEPLOY.md.
struct DatabaseEndpoint: Sendable {
    let host: String
    let port: Int
    let username: String
    let password: String?
    let database: String
    let requiresTLS: Bool
    /// `sslmode=verify-full` / `verify-ca`. Off for `require`/`prefer`, which
    /// is what those modes mean in libpq: encrypt, do not check who answered.
    let verifiesCertificate: Bool

    /// Parses `DATABASE_URL`. Returns nil for anything that is not a Postgres
    /// URL with a host and a user — the bot then runs memory-only, which is a
    /// supported mode, rather than starting with half a connection string.
    init?(urlString: String) {
        guard let url = URLComponents(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "postgres" || scheme == "postgresql",
              let host = url.host, !host.isEmpty,
              let user = url.user, !user.isEmpty
        else { return nil }

        self.host = host
        self.port = url.port ?? 5432
        self.username = user.removingPercentEncoding ?? user
        self.password = url.password.map { $0.removingPercentEncoding ?? $0 }
        let path = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        self.database = path.isEmpty ? user : path

        // Managed Postgres is TLS-only in practice, and `sslmode=disable` has
        // to be asked for explicitly rather than being what you get by
        // forgetting a query parameter.
        let sslMode = url.queryItems?.first { $0.name.lowercased() == "sslmode" }?.value?.lowercased()
        self.requiresTLS = sslMode != "disable"
        self.verifiesCertificate = sslMode == "verify-full" || sslMode == "verify-ca"
    }

    /// Host and port only — safe to log. The password never appears.
    var displayName: String { "\(host):\(port)/\(database)" }

    /// Pooler addresses in transaction mode use port 6543; nothing else about
    /// the URL gives the mode away, so this is the one check worth making
    /// before the advisory lock quietly stops working.
    var looksLikeTransactionPooler: Bool { port == 6543 }

    func clientConfiguration(maximumConnections: Int) throws -> PostgresClient.Configuration {
        var tls: PostgresClient.Configuration.TLS = .disable
        if requiresTLS {
            var config = TLSConfiguration.makeClientConfiguration()
            // Same meaning the `sslmode` values have in libpq, rather than a
            // blanket opt-out: `require` encrypts without checking who
            // answered, `verify-full` checks. Managed poolers often present a
            // certificate that does not chain to a public root, so defaulting
            // to verification would refuse to start on a working database —
            // but an operator who wants the check now has a way to ask for it.
            config.certificateVerification = verifiesCertificate ? .fullVerification : .none
            tls = .require(config)
        }
        var configuration = PostgresClient.Configuration(
            host: host,
            port: port,
            username: username,
            password: password,
            database: database,
            tls: tls
        )
        configuration.options.maximumConnections = maximumConnections
        // One connection is held for the writer lock for the process lifetime
        // (§3.1), so the pool must never shrink to nothing underneath it.
        configuration.options.minimumConnections = 1
        return configuration
    }
}

/// swift-log sink that forwards to the bot's own logger, so database messages
/// obey `LOG_LEVEL` and pass through `SecretRedactor` like everything else.
struct PostgresLogHandler: LogHandler {
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .notice
    private let sink: LoggerPort

    init(sink: LoggerPort) { self.sink = sink }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        let text = "postgres: \(message)"
        switch level {
        case .critical, .error: sink.error(text)
        case .warning: sink.warning(text)
        // The driver logs connection churn at `notice`; that is routine, and
        // routing it to `warning` would train the owner to ignore warnings.
        default: sink.info(text)
        }
    }
}
