import Foundation

/// Stable storage key for one person.
///
/// A Telegram @username is a *rented label*: it can be dropped, changed, and
/// picked up by somebody else. A numeric user ID never changes. So everything
/// the bot owns for a person — wallet, subscription, licences, chats — is filed
/// under `UserKey`:
///
/// - `#<userID>` once we have actually seen that person (the normal case);
/// - the bare lowercased username while we have only ever been *told* about
///   them (`/tenant adduser @somebody` for a stranger). Such a record is
///   "pending": the first time that person talks to the bot, `identifyUser`
///   re-files it under `#<userID>` and it becomes rename-proof too.
///
/// Usernames cannot contain `#` (Telegram allows a–z, 0–9 and `_`), so the two
/// key shapes can never collide.
enum UserKey {
    static let idPrefix = "#"

    static func forUserID(_ userID: Int) -> String { "\(idPrefix)\(userID)" }

    /// Key for a person we have not identified yet. Empty username → nil, so a
    /// blank never becomes a key everyone shares.
    static func pending(_ username: String?) -> String? {
        guard let raw = username?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else {
            return nil
        }
        return raw.hasPrefix("@") ? String(raw.dropFirst()) : raw
    }

    static func userID(from key: String) -> Int? {
        guard key.hasPrefix(idPrefix) else { return nil }
        return Int(key.dropFirst(idPrefix.count))
    }

    static func isIdentified(_ key: String) -> Bool { key.hasPrefix(idPrefix) }
}

/// What we last knew about a person behind a `UserKey`.
struct UserIdentity: Codable, Sendable, Equatable {
    var userID: Int
    /// Lowercased, without `@`; nil when the person has no username set.
    var username: String?
    var firstName: String?
    var seenAt: Date
    /// Earliest sighting we know of. Optional: rows written before this field
    /// existed have none, and they are backfilled with their last known
    /// sighting on the next update. Feeds the retention proxy (roadmap step 7).
    var firstSeenAt: Date?

    /// Label for the interface. A username when there is one — that is what
    /// people recognise — otherwise the name, otherwise the bare id. The
    /// internal `#<userID>` key is never shown.
    var displayLabel: String {
        if let username, !username.isEmpty { return "@\(username)" }
        if let firstName, !firstName.isEmpty { return firstName }
        return "id \(userID)"
    }
}

/// userID ↔ @username directory: the translation layer between the stable keys
/// the state is filed under and the usernames the interface speaks in.
///
/// Filled from every update the bot sees. `byUsername` is derived from
/// `identities` (not stored) so a username can never point at two people: the
/// index is rebuilt on decode and maintained on every write.
struct UserDirectory: Codable, Sendable {
    private(set) var identities: [Int: UserIdentity] = [:]
    private(set) var byUsername: [String: Int] = [:]
    /// Key of the bot's owner, pinned the first time the person configured as
    /// owner (`ownerUsername` in env) talks to the bot. Without this the owner
    /// would be recognised only by their configured @username — and would lose
    /// root the moment they changed it.
    var rootKey: String?

    static let empty = UserDirectory()

    enum CodingKeys: String, CodingKey { case identities, rootKey }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rootKey = try container.decodeIfPresent(String.self, forKey: .rootKey)
        let stored = try container.decodeIfPresent([String: UserIdentity].self, forKey: .identities) ?? [:]
        for (key, identity) in stored {
            let id = Int(key) ?? identity.userID
            identities[id] = identity
        }
        rebuildIndex()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var stored: [String: UserIdentity] = [:]
        for (id, identity) in identities { stored[String(id)] = identity }
        try container.encode(stored, forKey: .identities)
        try container.encodeIfPresent(rootKey, forKey: .rootKey)
    }

    private mutating func rebuildIndex() {
        byUsername = [:]
        for (id, identity) in identities {
            guard let name = identity.username, !name.isEmpty else { continue }
            // Two people cannot hold one username at the same time; if stale
            // data says otherwise, the more recent sighting wins.
            if let other = byUsername[name], let existing = identities[other], existing.seenAt > identity.seenAt {
                continue
            }
            byUsername[name] = id
        }
    }

    /// The directory is one JSON row, so it has to stay bounded. Entries whose
    /// person owns nothing are the only ones ever dropped, oldest sighting
    /// first — losing one costs a re-identification on their next message.
    static let maxIdentities = 10_000

    func identity(userID: Int) -> UserIdentity? { identities[userID] }

    /// Drops the least recently seen identities that hold no state.
    /// `protectedKeys` are the `UserKey`s currently attached to a tenant,
    /// wallet, chat, licence or super-admin role — those are never evicted.
    mutating func prune(protectedKeys: Set<String>) {
        guard identities.count > Self.maxIdentities else { return }
        let droppable = identities
            .filter { !protectedKeys.contains(UserKey.forUserID($0.key)) }
            .sorted { $0.value.seenAt < $1.value.seenAt }
        var overflow = identities.count - Self.maxIdentities
        for entry in droppable where overflow > 0 {
            identities.removeValue(forKey: entry.key)
            if let name = entry.value.username, byUsername[name] == entry.key {
                byUsername.removeValue(forKey: name)
            }
            overflow -= 1
        }
    }

    func userID(forUsername username: String?) -> Int? {
        guard let name = UserKey.pending(username) else { return nil }
        return byUsername[name]
    }

    /// Records a sighting. Returns the username this person used to hold when
    /// it differs from the new one — the caller re-files anything still stored
    /// under the old label.
    @discardableResult
    mutating func record(userID: Int, username: String?, firstName: String?, now: Date = Date()) -> (changed: Bool, previousUsername: String?) {
        let normalized = UserKey.pending(username)
        var identity = identities[userID]
            ?? UserIdentity(userID: userID, username: nil, firstName: nil, seenAt: now, firstSeenAt: now)
        let previous = identity.username
        let isNew = identities[userID] == nil
        identity.username = normalized
        if let firstName, !firstName.isEmpty { identity.firstName = firstName }
        // Backfill for rows written before the field existed: the earliest
        // sighting we can honestly claim is the one already on record.
        if identity.firstSeenAt == nil { identity.firstSeenAt = identity.seenAt }
        identity.seenAt = now
        identities[userID] = identity

        if previous != normalized {
            if let previous, byUsername[previous] == userID { byUsername.removeValue(forKey: previous) }
        }
        if let normalized {
            // Telegram usernames are unique at any instant, so a live sighting
            // proves whoever else held this label has let it go: drop their
            // claim to it, or lists would show two people as `@name`.
            if let formerHolder = byUsername[normalized], formerHolder != userID {
                identities[formerHolder]?.username = nil
            }
            byUsername[normalized] = userID
        }
        return (isNew || previous != normalized, previous)
    }

    /// Label for a stored key, for the interface. Identified people are shown
    /// by their current username; a pending record is shown by the username it
    /// was created with.
    func displayLabel(forKey key: String) -> String {
        guard let userID = UserKey.userID(from: key) else { return "@\(key)" }
        return identities[userID]?.displayLabel ?? "id \(userID)"
    }

    /// Retention proxy (roadmap step 7). A person counts into a cohort once
    /// enough time has passed since their first sighting to have been able to
    /// return; they count as retained if the bot has seen them at least that
    /// long after arriving. Not textbook D1/D7 (that needs per-day activity),
    /// but it answers the question the owner actually asks — возвращаются ли.
    func retention(now: Date = Date()) -> RetentionSnapshot {
        var snapshot = RetentionSnapshot()
        for identity in identities.values {
            guard let first = identity.firstSeenAt else { continue }
            let age = now.timeIntervalSince(first)
            let gap = identity.seenAt.timeIntervalSince(first)
            if age >= 86_400 {
                snapshot.cohortD1 += 1
                if gap >= 86_400 { snapshot.returnedD1 += 1 }
            }
            if age >= 7 * 86_400 {
                snapshot.cohortD7 += 1
                if gap >= 7 * 86_400 { snapshot.returnedD7 += 1 }
            }
        }
        return snapshot
    }

    /// Bare username (no `@`) behind a key, when there is one. Used where a
    /// username is needed as data — deep links, mentions in prompts.
    func username(forKey key: String) -> String? {
        guard let userID = UserKey.userID(from: key) else { return key }
        return identities[userID]?.username
    }
}
