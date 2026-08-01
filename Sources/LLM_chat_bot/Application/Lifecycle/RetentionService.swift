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

    /// One pass. Chats that belong to somebody — a tenant's licence, a
    /// sponsor's group, a paying account's DM — are kept whatever their age:
    /// the person is still a customer, and losing their history would be a
    /// downgrade of something they pay for.
    @discardableResult
    func sweep() async -> Int {
        guard let persistence else { return 0 }
        let protected = await state.chatsWorthKeeping()
        do {
            let removed = try await persistence.pruneChatContexts(
                idleDays: Self.idleDays,
                protecting: protected
            )
            guard !removed.isEmpty else { return 0 }
            await state.dropContexts(removed)
            logger.info("retention: dropped \(removed.count) conversations idle for \(Self.idleDays)+ days")
            return removed.count
        } catch {
            logger.error("retention sweep failed: \(error)")
            return 0
        }
    }
}
