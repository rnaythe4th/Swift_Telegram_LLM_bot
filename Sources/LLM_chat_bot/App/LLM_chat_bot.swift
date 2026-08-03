import Foundation
import Dispatch

enum AppBootstrapError: LocalizedError {
    case missingBotUsername
    case webhookModeWithoutPublicURL

    var errorDescription: String? {
        switch self {
        case .missingBotUsername:
            return "Telegram getMe returned a bot without username"
        case .webhookModeWithoutPublicURL:
            return "UPDATE_MODE=webhook requires WEBHOOK_PUBLIC_URL (or RAILWAY_PUBLIC_DOMAIN)"
        }
    }
}

@main
struct BlueprintBotApp {
    // Keeps signal sources alive for the process lifetime. `DispatchSourceSignal`
    // is not `Sendable` on Linux (it is on Darwin), so a `LockedValue` of them
    // does not compile for the platform this actually ships to. Unsafe is honest
    // here: the array is written once, from `main`, and never read — holding a
    // reference so the sources are not deallocated is its only job.
    nonisolated(unsafe) private static var signalSources: [any DispatchSourceSignal] = []

    /// The startup sequence, nothing else: the dependency graph is assembled in
    /// `AppAssembly` (which also owns the bot's defaults — owner, system prompt).
    static func main() async throws {
        let config = try AppConfig.load()

        // Before the first log line: see AppAssembly.registerSecrets.
        AppAssembly.registerSecrets(config)

        let logger = ConsoleLogger.fromEnvironment()
        let app = try await AppAssembly.build(config: config, logger: logger)

        let server = app.makeHTTPServer(port: config.healthPort)
        try await server.start()
        logger.info("HTTP server started on port \(config.healthPort) (/health, /ready, /metrics, webhook)")

        // The connection pool runs for the process lifetime; nothing can be
        // read or written until it does.
        let pool = app.storage.startPool()
        defer { pool?.cancel() }

        // Throws only for a database newer than this binary: a storage problem
        // that cannot be survived by degrading, so it stops the deploy here
        // rather than at the first silently-dropped write.
        let persistenceHealthy = try await app.orchestrator.bootstrapState(storage: app.storage)

        installShutdownHandlers(orchestrator: app.orchestrator, logger: logger)

        logger.info("Bot started as @\(app.botUsername)")
        await app.orchestrator.run(mode: app.mode, intake: app.intake, persistenceHealthy: persistenceHealthy)

        // run() returns only when draining began; the signal task finishes the
        // flush and exits the process.
        while true {
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    /// Railway sends SIGTERM before stopping a deployment; flushing state in
    /// that grace window is what makes redeploys lossless.
    private static func installShutdownHandlers(orchestrator: BotOrchestrator, logger: LoggerPort) {
        var sources: [any DispatchSourceSignal] = []
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                Task {
                    await orchestrator.shutdown()
                    exit(0)
                }
            }
            source.resume()
            sources.append(source)
        }
        signalSources = sources
    }
}
