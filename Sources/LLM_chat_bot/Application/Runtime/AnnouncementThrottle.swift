import Foundation

/// "Say it once, then not again for a while" — for signals whose *source*
/// flaps but whose *audience* is a person.
///
/// Every background loop in the bot watches a condition it does not control: an
/// upstream catalogue, a database connection, a lock held by another instance.
/// Those conditions do not fail once, they oscillate, and a loop that speaks on
/// every observation turns one incident into a stream the owner mutes — after
/// which the next real incident is silent too. The bound therefore has to live
/// with the notification, not with the observation.
///
/// The map is bounded by construction: a subject that has gone quiet for longer
/// than the interval can no longer suppress anything, so it is forgotten on the
/// next claim rather than kept as a growing record of everything that ever
/// happened.
struct AnnouncementThrottle<Subject: Hashable & Sendable>: Sendable {
    private var lastClaimedAt: [Subject: Date] = [:]
    let interval: TimeInterval

    init(interval: TimeInterval) {
        self.interval = interval
    }

    /// Books the right to speak about `subject`. True at most once per
    /// `interval`; the caller may only send when it gets `true`.
    ///
    /// It counts *attempts*, not deliveries, on purpose: a channel that is
    /// failing must not be retried faster than a channel that works, or an
    /// outage becomes its own flood.
    mutating func claim(_ subject: Subject, now: Date = Date()) -> Bool {
        lastClaimedAt = lastClaimedAt.filter { now.timeIntervalSince($0.value) < interval }
        guard lastClaimedAt[subject] == nil else { return false }
        lastClaimedAt[subject] = now
        return true
    }

    /// Forgets one subject, so the next claim succeeds immediately. For the
    /// case where the thing being announced genuinely changed rather than
    /// flapped.
    mutating func forget(_ subject: Subject) {
        lastClaimedAt.removeValue(forKey: subject)
    }
}
