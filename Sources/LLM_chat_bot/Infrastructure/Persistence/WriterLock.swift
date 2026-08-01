import Foundation
import Logging
import PostgresNIO

/// The right to write state, held for as long as the process lives (§3.1).
///
/// Railway keeps the old instance running while the new one starts — that is
/// how a deploy stays lossless, not an accident — and nothing stops an operator
/// setting `replicas = 2`. Two instances both loading state into memory and
/// both writing it back is how a renewal disappears, a sweep sends every
/// reminder twice, and a crypto poller credits the same transfer from two
/// directions.
///
/// `pg_try_advisory_lock` is strictly stronger than a lease with a TTL: the
/// lock lives exactly as long as the connection holding it, and Postgres
/// releases it the moment that connection dies. There is no expiry to guess, no
/// heartbeat to miss, and no window in which two processes both believe they
/// are the writer.
///
/// **Requires a session-mode connection** (§1). In transaction mode the pooler
/// returns the connection after every statement and takes the lock with it —
/// `pg_try_advisory_lock` answers `true` and the guarantee is gone, silently.
actor WriterLock {
    /// 'LLMB' — one lock id for the whole bot. Two deployments sharing a
    /// database on purpose would need different ids; sharing one by accident is
    /// exactly what this prevents.
    static let lockID: Int64 = 0x4C4C4D42

    private let client: PostgresClient
    private let logger: LoggerPort
    private let queryLogger: Logger
    private var holder: Task<Void, Never>?
    private var lost: (@Sendable () -> Void)?
    private var held = false

    init(client: PostgresClient, logger: LoggerPort) {
        self.client = client
        self.logger = logger
        self.queryLogger = Logger(label: "postgres.writerlock") { _ in PostgresLogHandler(sink: logger) }
    }

    /// Tries to become the writer. `false` means another instance holds it and
    /// this one must stay read-only: no persistence loop, no background sweeps,
    /// and `/ready` left at 503 so the platform never routes traffic here.
    ///
    /// On success a task keeps the connection — and therefore the lock — for the
    /// process lifetime, and calls `onLost` if it ever goes away.
    func acquire(onLost: @escaping @Sendable () -> Void) async -> Bool {
        guard holder == nil else { return held }

        let acquired = AsyncStreamBox()
        let client = self.client
        let log = queryLogger
        let logger = self.logger

        holder = Task {
            do {
                try await client.withConnection { connection in
                    let rows = try await connection.query(
                        "select pg_try_advisory_lock(\(WriterLock.lockID)) as locked",
                        logger: log
                    )
                    var locked = false
                    for try await row in rows {
                        locked = try PostgresRandomAccessRow(row)["locked"].decode(Bool.self)
                    }
                    await acquired.send(locked)
                    guard locked else { return }

                    // Hold the connection — and with it the lock — until the
                    // process ends or the connection breaks. The keep-alive is
                    // cheap and turns a silently dead TCP session into a thrown
                    // error we can react to.
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(20))
                        try await connection.query("select 1", logger: log)
                    }
                }
            } catch {
                await acquired.send(false)
                if !Task.isCancelled {
                    logger.error("writer lock lost: \(error)")
                }
            }
            // `onLost` means "the lock we were holding is gone", never "this
            // attempt did not get it". The box records which of the two
            // happened, and a losing attempt must stay silent: the waiting
            // instance retries every two seconds, and one stale callback
            // arriving after a later attempt succeeded would step the process
            // down seconds after it became the writer.
            if await acquired.value, !Task.isCancelled { onLost() }
        }

        held = await acquired.value
        if !held {
            holder?.cancel()
            holder = nil
        }
        return held
    }

    var isHeld: Bool { held }

    /// Releases the lock by dropping the connection that holds it. Called at the
    /// end of `shutdown()`, after the final flush, so the next instance can
    /// start writing immediately instead of waiting for a lease to expire.
    func release() {
        holder?.cancel()
        holder = nil
        held = false
    }
}

/// One-shot handover of the acquire result out of the holder task.
private actor AsyncStreamBox {
    private var value_: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func send(_ value: Bool) {
        guard value_ == nil else { return }
        value_ = value
        for waiter in waiters { waiter.resume(returning: value) }
        waiters.removeAll()
    }

    var value: Bool {
        get async {
            if let value_ { return value_ }
            return await withCheckedContinuation { waiters.append($0) }
        }
    }
}
