import Foundation

/// Guards against a provider that accepts the connection and then goes quiet
/// (§4.5).
///
/// The adapters set a 300-second timeout on the *whole request*, which is the
/// wrong thing on both ends. A provider that stops sending after the first
/// chunk holds a generation slot (one of 64), the chat's queue (16 messages)
/// and a "💭 Думаю…" on somebody's screen for five minutes — and it breaks the
/// lossless redeploy, because `activeCount` never reaches zero inside the
/// eight-second shutdown window. Meanwhile an honest six-minute reasoning
/// answer gets cut off mid-sentence.
///
/// What matters is not how long the answer takes but how long the silence
/// lasts. So: a gap between events, plus a generous total ceiling.
enum StreamWatchdog {
    /// Longest silence between two stream events before the turn is abandoned.
    /// Comfortably above a slow first token on a reasoning model, far below the
    /// shutdown window it used to blow through.
    static let idleTimeout: Duration = .seconds(75)
    /// Absolute ceiling, for a provider that dribbles one token a minute
    /// forever — each token resets the gap, so only this stops it.
    static let totalTimeout: Duration = .seconds(600)
    /// How often the timer looks. Coarse on purpose: this is a stall detector,
    /// not a stopwatch, and it runs once per live generation.
    static let tick: Duration = .seconds(1)
}

/// Last time one stream produced anything. One instance per stream — a shared
/// clock would let a busy generation keep a stalled one alive.
private actor StreamHeartbeat {
    private var last = ContinuousClock().now
    func beat() { last = ContinuousClock().now }
    var elapsed: Duration { ContinuousClock().now - last }
}

extension AsyncThrowingStream where Element == ProviderStreamEvent, Failure == Error {
    /// Fails the stream if more than `gap` passes between events, or `total`
    /// from the start.
    ///
    /// It fails rather than finishing quietly on purpose: a silent finish makes
    /// an empty accumulator, which the user sees as «Пустой ответ.» and which
    /// leaves nothing in the log — exactly the invisibility the adapters were
    /// taught to avoid when they learned to decode `error` inside SSE (§8). The
    /// turn is not charged either: the `catch` path already refunds the daily
    /// premium unit and cancels the pending turn.
    func withIdleTimeout(
        _ gap: Duration = StreamWatchdog.idleTimeout,
        total: Duration = StreamWatchdog.totalTimeout,
        tick: Duration = StreamWatchdog.tick
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream<ProviderStreamEvent, Error> { continuation in
            let heartbeat = StreamHeartbeat()
            let deadline = ContinuousClock().now + total

            let pump = Task {
                do {
                    for try await event in self {
                        await heartbeat.beat()
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            let timer = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: tick)
                    if Task.isCancelled { return }
                    if await heartbeat.elapsed > gap {
                        pump.cancel()
                        continuation.finish(
                            throwing: ProviderAdapterError.idleTimeout(seconds: gap.wholeSeconds)
                        )
                        return
                    }
                    if ContinuousClock().now > deadline {
                        pump.cancel()
                        continuation.finish(
                            throwing: ProviderAdapterError.idleTimeout(seconds: total.wholeSeconds)
                        )
                        return
                    }
                }
            }

            continuation.onTermination = { _ in
                pump.cancel()
                timer.cancel()
            }
        }
    }
}

extension Duration {
    var wholeSeconds: Int { Int(components.seconds) }
}
