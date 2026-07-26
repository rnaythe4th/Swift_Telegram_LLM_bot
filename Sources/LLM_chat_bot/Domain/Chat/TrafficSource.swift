import Foundation

/// Deep-link plumbing for paid-traffic attribution: `t.me/<bot>?start=src_<tag>`.
///
/// Without it an ad buy is unmeasurable — the owner sees new users arrive but
/// cannot tell which channel produced them, so CAC (spend ÷ paying customers)
/// cannot be computed per channel and the budget goes to whatever *feels* like
/// it worked. That is the single most expensive mistake in `LAUNCH_ECONOMICS.md`.
enum TrafficSourceLink {
    /// `/start` payload prefix. Deliberately distinct from `inv_` (licence
    /// invite) and `ref_` (referral bonus): this one only labels where a person
    /// came from and never grants or pays anything.
    static let payloadPrefix = "src_"

    /// Tags go into HTML and into counter keys, so the alphabet is closed.
    static let maxTagLength = 32

    static func url(botUsername: String, tag: String) -> String {
        "https://t.me/\(botUsername)?start=\(payloadPrefix)\(tag)"
    }

    /// Campaign tag from a `/start` payload; nil when it is not a `src_` one or
    /// nothing survives sanitising.
    static func tag(payload: String) -> String? {
        guard payload.hasPrefix(payloadPrefix) else { return nil }
        return sanitize(String(payload.dropFirst(payloadPrefix.count)))
    }

    /// Lowercased, `[a-z0-9_-]` only, length-capped. The tag is chosen by
    /// whoever writes the ad copy — that is untrusted text, and it ends up both
    /// in a JSON object key and in a message the bot signs with its own name.
    static func sanitize(_ raw: String) -> String? {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_-")
        let cleaned = String(raw.lowercased().filter { allowed.contains($0) }.prefix(maxTagLength))
        return cleaned.isEmpty ? nil : cleaned
    }
}

/// One attributed person: which campaign brought them and how far they got.
/// Keyed by Telegram userID — the identity that survives a @username change.
struct TrafficSourceAttribution: Codable, Sendable, Equatable {
    var tag: String
    var joinedAt: Date
    /// Set on their first real answer from the bot (activation).
    var activatedAt: Date?
    /// Set the first time they paid for anything.
    var paidAt: Date?
    var payments: Int

    init(
        tag: String,
        joinedAt: Date = Date(),
        activatedAt: Date? = nil,
        paidAt: Date? = nil,
        payments: Int = 0
    ) {
        self.tag = tag
        self.joinedAt = joinedAt
        self.activatedAt = activatedAt
        self.paidAt = paidAt
        self.payments = payments
    }

    enum CodingKeys: String, CodingKey { case tag, joinedAt, activatedAt, paidAt, payments }

    /// Hand-written for the same reason as `ReferralRecord`: a field added later
    /// must be optional on the way in, or one row from an older build takes the
    /// whole ledger down and every attribution is forgotten at once.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            tag: try c.decode(String.self, forKey: .tag),
            joinedAt: try c.decodeIfPresent(Date.self, forKey: .joinedAt) ?? Date(),
            activatedAt: try c.decodeIfPresent(Date.self, forKey: .activatedAt),
            paidAt: try c.decodeIfPresent(Date.self, forKey: .paidAt),
            payments: try c.decodeIfPresent(Int.self, forKey: .payments) ?? 0
        )
    }
}

/// Per-campaign aggregate. Survives attribution pruning, so the numbers a media
/// buy is judged on can never be reset by the ledger outgrowing its row.
struct TrafficSourceTally: Codable, Sendable, Equatable {
    /// People this campaign brought in (attributions created).
    var joined: Int
    /// …of whom got at least one real answer.
    var activated: Int
    /// …of whom paid at least once. This is the CAC denominator.
    var payers: Int
    /// Total payments from this campaign's people (repeat purchases included).
    var payments: Int
    var firstSeenAt: Date
    var lastSeenAt: Date

    init(
        joined: Int = 0,
        activated: Int = 0,
        payers: Int = 0,
        payments: Int = 0,
        firstSeenAt: Date = Date(),
        lastSeenAt: Date = Date()
    ) {
        self.joined = joined
        self.activated = activated
        self.payers = payers
        self.payments = payments
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
    }

    /// Share of arrivals that produced a paying customer.
    var conversionPercent: Double {
        guard joined > 0 else { return 0 }
        return Double(payers) / Double(joined) * 100
    }

    enum CodingKeys: String, CodingKey {
        case joined, activated, payers, payments, firstSeenAt, lastSeenAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            joined: try c.decodeIfPresent(Int.self, forKey: .joined) ?? 0,
            activated: try c.decodeIfPresent(Int.self, forKey: .activated) ?? 0,
            payers: try c.decodeIfPresent(Int.self, forKey: .payers) ?? 0,
            payments: try c.decodeIfPresent(Int.self, forKey: .payments) ?? 0,
            firstSeenAt: try c.decodeIfPresent(Date.self, forKey: .firstSeenAt) ?? Date(),
            lastSeenAt: try c.decodeIfPresent(Date.self, forKey: .lastSeenAt) ?? Date()
        )
    }
}

/// All paid-traffic bookkeeping in one `bot_config` row
/// (`GlobalConfigKey.trafficSources`): attributions + per-campaign aggregates.
struct TrafficSourceLedger: Codable, Sendable {
    /// Keyed by String(userID) — JSON object keys must be strings.
    var attributions: [String: TrafficSourceAttribution]
    /// Keyed by campaign tag.
    var tallies: [String: TrafficSourceTally]
    /// Link opened again by somebody already attributed. Attribution stays with
    /// the campaign that arrived first (first touch), so a channel cannot claim
    /// a customer another channel paid to acquire.
    var repeatOpens: Int
    /// Link opened by somebody who was already using the bot. Not an
    /// acquisition, so it is counted separately instead of inflating `joined` —
    /// otherwise CAC would look better than it is.
    var knownUserOpens: Int

    /// Size guards: this is a single JSON row and must stay bounded.
    static let maxAttributions = 20_000
    static let maxTags = 200
    /// Overflow bucket, so tag 201 is still counted somewhere instead of being
    /// dropped on the floor.
    static let overflowTag = "other"

    static let empty = TrafficSourceLedger()

    init(
        attributions: [String: TrafficSourceAttribution] = [:],
        tallies: [String: TrafficSourceTally] = [:],
        repeatOpens: Int = 0,
        knownUserOpens: Int = 0
    ) {
        self.attributions = attributions
        self.tallies = tallies
        self.repeatOpens = repeatOpens
        self.knownUserOpens = knownUserOpens
    }

    enum CodingKeys: String, CodingKey {
        case attributions, tallies, repeatOpens, knownUserOpens
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            attributions: try c.decodeIfPresent([String: TrafficSourceAttribution].self, forKey: .attributions) ?? [:],
            tallies: try c.decodeIfPresent([String: TrafficSourceTally].self, forKey: .tallies) ?? [:],
            repeatOpens: try c.decodeIfPresent(Int.self, forKey: .repeatOpens) ?? 0,
            knownUserOpens: try c.decodeIfPresent(Int.self, forKey: .knownUserOpens) ?? 0
        )
    }

    var totalJoined: Int { tallies.values.reduce(0) { $0 + $1.joined } }
    var totalActivated: Int { tallies.values.reduce(0) { $0 + $1.activated } }
    var totalPayers: Int { tallies.values.reduce(0) { $0 + $1.payers } }
    var totalPayments: Int { tallies.values.reduce(0) { $0 + $1.payments } }

    /// The tag a new attribution should be filed under: itself, or the overflow
    /// bucket once the campaign list is full.
    func storageTag(for tag: String) -> String {
        if tallies[tag] != nil { return tag }
        return tallies.count >= Self.maxTags ? Self.overflowTag : tag
    }

    /// Campaigns ordered the way a media buyer reads them: paying customers
    /// first — twenty idle arrivals are worth less than two customers.
    func ranked() -> [TrafficSourceRow] {
        tallies
            .map { TrafficSourceRow(tag: $0.key, tally: $0.value) }
            .sorted {
                if $0.tally.payers != $1.tally.payers { return $0.tally.payers > $1.tally.payers }
                if $0.tally.activated != $1.tally.activated { return $0.tally.activated > $1.tally.activated }
                if $0.tally.joined != $1.tally.joined { return $0.tally.joined > $1.tally.joined }
                return $0.tag < $1.tag
            }
    }

    /// Drops the oldest attributions once the row outgrows its budget. Only the
    /// per-person records go — the aggregates they already rolled into stay, so
    /// pruning never rewrites a campaign's history.
    mutating func prune() {
        guard attributions.count > Self.maxAttributions else { return }
        let ordered = attributions.sorted { $0.value.joinedAt < $1.value.joinedAt }
        var overflow = attributions.count - Self.maxAttributions
        for entry in ordered where overflow > 0 {
            attributions.removeValue(forKey: entry.key)
            overflow -= 1
        }
    }
}

struct TrafficSourceRow: Sendable {
    let tag: String
    let tally: TrafficSourceTally
}

/// What happened when somebody opened a `src_` link.
enum TrafficSourceBindOutcome: Sendable, Equatable {
    /// Attribution recorded under this campaign.
    case bound(tag: String)
    /// Already attributed — first touch wins, nothing changes.
    case alreadyAttributed(tag: String)
    /// The person was already using the bot, so this is not an acquisition.
    case knownUser
}

/// Program-wide numbers for the super-admin page.
struct TrafficSourceOverview: Sendable {
    var rows: [TrafficSourceRow]
    var joined: Int
    var activated: Int
    var payers: Int
    var payments: Int
    var repeatOpens: Int
    var knownUserOpens: Int

    var campaigns: Int { rows.count }
    /// Every `src_` open the bot saw, attributed or not.
    var opens: Int { joined + repeatOpens + knownUserOpens }
}
