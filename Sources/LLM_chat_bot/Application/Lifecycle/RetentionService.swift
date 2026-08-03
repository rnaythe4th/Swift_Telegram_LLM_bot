import Foundation

/// Conversations do not have to be kept forever (§7.2).
///
/// A product that takes money and stores what people typed into it needs an
/// answer to "how long do you keep this", and "forever, with no way to erase
/// it" is not one. Two answers, then: an idle chat's history ages out on its
/// own, and anyone can erase theirs on demand with `/forget`.
///
/// What is never touched either way: the wallet, the subscription and the money
/// journal. Those are financial records — the user's own evidence in a dispute
/// — and erasing them on request would delete the proof rather than the data.
actor RetentionService {
    /// How long a chat may sit untouched before its conversation is dropped.
    /// Long enough that a seasonal user comes back to a bot that still knows
    /// them, short enough that a chat abandoned two seasons ago is gone.
    static let idleDays = 180
    /// Sweeps run daily; the first one waits out the noisy part of boot.
    static let interval: Duration = .seconds(24 * 3600)
    private static let firstDelay: Duration = .seconds(300)

    private let state: ChatContextStore
    private let persistence: StatePersistencePort?
    private let logger: LoggerPort

    init(state: ChatContextStore, persistence: StatePersistencePort?, logger: LoggerPort) {
        self.state = state
        self.persistence = persistence
        self.logger = logger
    }

    func run() async {
        try? await Task.sleep(for: Self.firstDelay)
        while !Task.isCancelled {
            await sweep()
            try? await Task.sleep(for: Self.interval)
        }
    }

    /// What one pass removed. Two independent numbers rather than one total:
    /// they answer different questions ("whose conversation aged out" and "how
    /// much bookkeeping did we stop carrying"), and one failing must not hide
    /// the other's result.
    struct SweepOutcome: Sendable, Equatable {
        var conversations = 0
        var funnelDays = 0
    }

    /// One pass. Chats that belong to somebody — a tenant's licence, a
    /// sponsor's group, a paying account's DM — are kept whatever their age:
    /// the person is still a customer, and losing their history would be a
    /// downgrade of something they pay for.
    ///
    /// The two halves are deliberately independent: a failure pruning
    /// conversations must not leave the funnel table growing forever, and vice
    /// versa. Neither is urgent enough to retry inside the pass — the sweep
    /// comes back tomorrow.
    @discardableResult
    func sweep() async -> SweepOutcome {
        guard let persistence else { return SweepOutcome() }
        var outcome = SweepOutcome()

        let protected = await state.chatsWorthKeeping()
        do {
            let removed = try await persistence.pruneChatContexts(
                idleDays: Self.idleDays,
                protecting: protected
            )
            if !removed.isEmpty {
                await state.dropContexts(removed)
                logger.info("retention: dropped \(removed.count) conversations idle for \(Self.idleDays)+ days")
                outcome.conversations = removed.count
            }
        } catch {
            logger.error("retention sweep failed: \(error)")
        }

        // Daily funnel buckets outside the window the loader reads. They stop
        // being read the moment they leave the window, but nothing ever stopped
        // them accumulating — ~30 rows a day, forever.
        do {
            let pruned = try await persistence.pruneFunnelDays(before: FunnelDailyLog.oldestLoadedDay())
            if pruned > 0 {
                logger.info("retention: dropped \(pruned) funnel buckets outside the \(FunnelDailyLog.windowDays)-day window")
                outcome.funnelDays = pruned
            }
        } catch {
            logger.error("retention: funnel prune failed: \(error)")
        }

        return outcome
    }
}
