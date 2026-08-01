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
///
/// It is a type rather than a `String` because the difference between "a key"
/// and "some text about a person" is invisible to the reader and expensive to
/// get wrong. A username, a display label, a model id and a key used to be one
/// type; the rules that kept them apart lived in prose, and one of them has
/// already been broken once — the handle resolver stopped accepting `#<userID>`
/// and every role gate silently answered "no" to everyone already identified.
/// There is no public `init(String)`: text that arrives from a command, an
/// update field or an unvalidated column cannot become a key by assignment.
struct UserKey: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    static let idPrefix = "#"

    /// Characters a Telegram username is made of. Anything a pending key is
    /// built from has to fit here — the key is not just a label: it is written
    /// into database filters and printed into HTML, and both of those have
    /// syntax of their own that a free-form string could reach into.
    private static let usernameCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789_")

    private let raw: String

    private init(unchecked raw: String) { self.raw = raw }

    /// Key of somebody the bot has actually seen. Rename-proof.
    static func identified(_ userID: UserID) -> UserKey {
        UserKey(unchecked: "\(idPrefix)\(userID)")
    }

    /// A Telegram handle in its one canonical spelling: lowercased, no `@`, and
    /// only if it is actually username-shaped. Separate from the key itself
    /// because a handle is *data* (deep links, denormalised labels) while a key
    /// is an address — the whole point of this type is that the two stopped
    /// being the same `String`.
    static func normalizedHandle(_ username: String?) -> String? {
        guard let raw = username?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else {
            return nil
        }
        let bare = raw.hasPrefix("@") ? String(raw.dropFirst()) : raw
        guard !bare.isEmpty, bare.count <= 32, bare.allSatisfy({ usernameCharacters.contains($0) }) else {
            return nil
        }
        return bare
    }

    /// Key for a person we have not identified yet. Empty username → nil, so a
    /// blank never becomes a key everyone shares.
    ///
    /// Rejects anything that is not username-shaped, so a hand-typed
    /// `/tenant adduser` argument cannot forge an identified key (`#12345`,
    /// which the `#` would otherwise allow) or smuggle punctuation downstream.
    static func pending(_ username: String?) -> UserKey? {
        normalizedHandle(username).map { UserKey(unchecked: $0) }
    }

    /// Last-resort key for text that is not username-shaped: everything outside
    /// the username alphabet is dropped rather than carried into storage. The
    /// result addresses no real record (which is the correct outcome for a
    /// typo), but it is safe to put in a URL filter or a message.
    static func sanitizedPendingFallback(_ raw: String) -> UserKey {
        UserKey(unchecked: String(raw.lowercased().filter { usernameCharacters.contains($0) }.prefix(32)))
    }

    /// Rebuilds a key from something already stored. Deliberately total: a value
    /// that matches neither shape is sanitised rather than rejected, because one
    /// unreadable row must never take a whole restore down with it. The
    /// sanitised result addresses no real record, which is the honest outcome.
    init(storageValue value: String) {
        if let identified = UserKey.parsedUserID(value) {
            self = .identified(UserID(identified))
        } else {
            self = UserKey.pending(value) ?? .sanitizedPendingFallback(value)
        }
    }

    private static func parsedUserID(_ value: String) -> Int? {
        guard value.hasPrefix(idPrefix) else { return nil }
        let digits = value.dropFirst(idPrefix.count)
        // `Int(_:)` accepts a leading `+`/`-`, which would make `#-1` and `#1`
        // two spellings that both parse — keys must have exactly one form.
        guard !digits.isEmpty, digits.allSatisfy({ $0.isNumber }) else { return nil }
        return Int(digits)
    }

    /// The account behind an identified key. `UserID` rather than `Int`, so a
    /// key cannot be mistaken for a chat on the way out.
    var userID: UserID? { UserKey.parsedUserID(raw).map(UserID.init) }

    var isIdentified: Bool { raw.hasPrefix(UserKey.idPrefix) }

    /// The one way out to a `String`, named after the only thing it is for:
    /// a column value or a JSON field. Interface text goes through
    /// `displayLabel(forKey:)` instead — a key is not something a user reads.
    var storageValue: String { raw }

    /// Deliberately *not* the bare key: interpolating a key into a message is a
    /// mistake, and `UserKey(#12345)` in the output says so out loud instead of
    /// looking like an intentional label.
    var description: String { "UserKey(\(raw))" }

    static func < (lhs: UserKey, rhs: UserKey) -> Bool { lhs.raw < rhs.raw }

    init(from decoder: Decoder) throws {
        self.init(storageValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

/// What we last knew about a person behind a `UserKey`.
struct UserIdentity: Codable, Sendable, Equatable {
    /// A Telegram display name is arbitrary user-chosen text, and every label
    /// built from it is pasted into an HTML message the bot signs its own name
    /// to. Left raw, `first_name` = `<a href="…">Поддержка</a>` renders as a
    /// live link inside a bot message — no model, no prompt injection needed.
    /// Escaping here (rather than at each of the ~40 call sites) is what makes
    /// that impossible; the send-time sanitizer passes these entities through
    /// unchanged, so the reader still sees the literal characters.
    static let maxNameLength = 64

    static func sanitizeName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        // Newlines and control characters let a name forge extra lines in a
        // list ("@alice\n@bob · суперадмин").
        let collapsed = raw
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .unicodeScalars
            .filter { $0.value >= 0x20 && $0.value != 0x7F }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
            .trimmingCharacters(in: .whitespaces)
        guard !collapsed.isEmpty else { return nil }
        let clipped = collapsed.count > maxNameLength
            ? String(collapsed.prefix(maxNameLength)) + "…"
            : collapsed
        return clipped
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    var userID: UserID
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
    ///
    /// HTML-safe by construction (see `sanitizeName`): a label goes straight
    /// into message text, so it must never be able to open a tag.
    var displayLabel: String {
        // A username is `a–z0–9_` by Telegram's own rules, so it needs no
        // escaping — but it is stored data, and stored data can predate a rule.
        if let username, !username.isEmpty {
            return "@\(Self.sanitizeName(username) ?? username)"
        }
        if let firstName, !firstName.isEmpty {
            return Self.sanitizeName(firstName) ?? "id \(userID)"
        }
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
    private(set) var identities: [UserID: UserIdentity] = [:]
    private(set) var byUsername: [String: UserID] = [:]
    /// Key of the bot's owner, pinned the first time the person configured as
    /// owner (`ownerKey` in env) talks to the bot. Without this the owner
    /// would be recognised only by their configured @username — and would lose
    /// root the moment they changed it.
    var rootKey: UserKey?

    static let empty = UserDirectory()

    enum CodingKeys: String, CodingKey { case identities, rootKey }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rootKey = try container.decodeIfPresent(UserKey.self, forKey: .rootKey)
        let stored = try container.decodeIfPresent([String: UserIdentity].self, forKey: .identities) ?? [:]
        for (key, identity) in stored {
            let id = Int(key).map(UserID.init) ?? identity.userID
            identities[id] = identity
        }
        rebuildIndex()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var stored: [String: UserIdentity] = [:]
        for (id, identity) in identities { stored[String(id.value)] = identity }
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

    func identity(userID: UserID) -> UserIdentity? { identities[userID] }

    /// Loads one stored row on boot. The username index is maintained here as
    /// on every other write, so a stale duplicate in storage still cannot make
    /// one handle point at two people.
    mutating func restore(_ identity: UserIdentity) {
        identities[identity.userID] = identity
        guard let name = identity.username, !name.isEmpty else { return }
        if let other = byUsername[name], let existing = identities[other], existing.seenAt > identity.seenAt {
            return
        }
        byUsername[name] = identity.userID
    }

    /// Drops the least recently seen identities that hold no state.
    /// `protectedKeys` are the `UserKey`s currently attached to a tenant,
    /// wallet, chat, licence or super-admin role — those are never evicted.
    mutating func prune(protectedKeys: Set<UserKey>) {
        guard identities.count > Self.maxIdentities else { return }
        let droppable = identities
            .filter { !protectedKeys.contains(UserKey.identified($0.key)) }
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

    func userID(forUsername username: String?) -> UserID? {
        guard let name = UserKey.pending(username) else { return nil }
        return byUsername[name.storageValue]
    }

    /// How far `seenAt` has to move before the row is worth rewriting. The
    /// directory is a single JSON row holding up to `maxIdentities` records, so
    /// it cannot be persisted on every message — but if it is persisted *only*
    /// on a new person or a rename, `seenAt` never reaches the database on a
    /// quiet bot and rolls back on restart. Both consumers care about days
    /// (wallet win-back idleness, the retention proxy), so quarter-hour
    /// granularity costs them nothing.
    static let seenAtPersistInterval: TimeInterval = 15 * 60

    /// Records a sighting. Returns the username this person used to hold when
    /// it differs from the new one — the caller re-files anything still stored
    /// under the old label — and whether `seenAt` moved far enough to be worth
    /// writing out.
    @discardableResult
    mutating func record(userID: UserID, username: String?, firstName: String?, now: Date = Date()) -> (changed: Bool, previousUsername: String?, seenAtAdvanced: Bool) {
        let normalized = UserKey.normalizedHandle(username)
        var identity = identities[userID]
            ?? UserIdentity(userID: userID, username: nil, firstName: nil, seenAt: now, firstSeenAt: now)
        let previous = identity.username
        let isNew = identities[userID] == nil
        let seenAtAdvanced = isNew || now.timeIntervalSince(identity.seenAt) >= Self.seenAtPersistInterval
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
        return (isNew || previous != normalized, previous, seenAtAdvanced)
    }

    /// Label for a stored key, for the interface. Identified people are shown
    /// by their current username; a pending record is shown by the username it
    /// was created with.
    func displayLabel(forKey key: UserKey) -> String {
        // A pending key is a handle somebody typed into `/tenant adduser`, so it
        // is no more trustworthy than a display name — escape it the same way.
        guard let userID = key.userID else {
            let handle = key.storageValue
            return "@\(UserIdentity.sanitizeName(handle) ?? handle)"
        }
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
    func username(forKey key: UserKey) -> String? {
        guard let userID = key.userID else { return key.storageValue }
        return identities[userID]?.username
    }
}
