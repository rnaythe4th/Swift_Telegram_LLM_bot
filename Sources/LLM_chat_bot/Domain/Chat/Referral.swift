import Foundation

/// Deep-link plumbing for the two-sided referral (roadmap step 10). The link
/// carries the inviter's Telegram **userID**, which — unlike a @username —
/// never changes, so a link stays valid forever.
enum ReferralLink {
    /// `/start` payload prefix. Deliberately distinct from the admin invite
    /// prefix (`inv_`): those grant licence access, these pay a bonus.
    static let payloadPrefix = "ref_"

    static func url(botUsername: String, userID: Int) -> String {
        "https://t.me/\(botUsername)?start=\(payloadPrefix)\(userID)"
    }

    /// Inviter userID from a `/start` payload; nil when it is not a referral one.
    static func inviterUserID(payload: String) -> Int? {
        guard payload.hasPrefix(payloadPrefix) else { return nil }
        return Int(payload.dropFirst(payloadPrefix.count))
    }

    /// Telegram's native share sheet, pre-filled with the link and a pitch.
    static func shareURL(link: String, text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encodedLink = link.addingPercentEncoding(withAllowedCharacters: allowed) ?? link
        let encodedText = text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return "https://t.me/share/url?url=\(encodedLink)&text=\(encodedText)"
    }
}

/// Super-admin-tunable referral economics. Persisted as one `bot_config` row
/// (`GlobalConfigKey.referrals`) so rewards and the anti-farming cap are
/// changeable live, without a redeploy — nothing here is hardcoded elsewhere.
struct ReferralConfig: Codable, Sendable, Equatable {
    /// Master switch: off means links stop binding and pending rewards wait.
    var enabled: Bool
    /// What the inviter gets, in USD cents, credited to their balance.
    var inviterRewardCents: Int
    /// What the invited friend gets, in USD cents.
    var inviteeRewardCents: Int
    /// Lifetime cap of *rewarded* invites per inviter (0 = no cap). The main
    /// anti-farming knob: beyond it, further invites bind but pay nothing.
    var maxRewardsPerInviter: Int

    static let `default` = ReferralConfig(
        enabled: true,
        inviterRewardCents: 100,
        inviteeRewardCents: 100,
        maxRewardsPerInviter: 20
    )

    // Bounds: a typo must not be able to drain the balance sheet.
    static let rewardRange = 0...5000   // up to $50 per side
    static let capRange = 0...10000

    var inviterRewardUsd: Double { Double(inviterRewardCents) / 100.0 }
    var inviteeRewardUsd: Double { Double(inviteeRewardCents) / 100.0 }
    /// False when both sides are set to zero — the program runs but pays nothing.
    var paysAnything: Bool { inviterRewardCents > 0 || inviteeRewardCents > 0 }

    static func formatUsd(cents: Int) -> String {
        cents % 100 == 0 ? "$\(cents / 100)" : String(format: "$%.2f", Double(cents) / 100.0)
    }

    /// Clamped copy. Every setter and the decoder go through this, so a stored
    /// or hand-typed value can never put the program outside sane bounds.
    var normalized: ReferralConfig {
        var copy = self
        copy.inviterRewardCents = Self.clamp(inviterRewardCents, Self.rewardRange)
        copy.inviteeRewardCents = Self.clamp(inviteeRewardCents, Self.rewardRange)
        copy.maxRewardsPerInviter = Self.clamp(maxRewardsPerInviter, Self.capRange)
        return copy
    }

    private static func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    enum CodingKeys: String, CodingKey {
        case enabled, inviterRewardCents, inviteeRewardCents, maxRewardsPerInviter
    }

    init(enabled: Bool, inviterRewardCents: Int, inviteeRewardCents: Int, maxRewardsPerInviter: Int) {
        self.enabled = enabled
        self.inviterRewardCents = inviterRewardCents
        self.inviteeRewardCents = inviteeRewardCents
        self.maxRewardsPerInviter = maxRewardsPerInviter
    }

    /// Missing fields fall back to the defaults, so a row written by an older
    /// build still decodes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ReferralConfig.default
        self.init(
            enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? fallback.enabled,
            inviterRewardCents: try c.decodeIfPresent(Int.self, forKey: .inviterRewardCents) ?? fallback.inviterRewardCents,
            inviteeRewardCents: try c.decodeIfPresent(Int.self, forKey: .inviteeRewardCents) ?? fallback.inviteeRewardCents,
            maxRewardsPerInviter: try c.decodeIfPresent(Int.self, forKey: .maxRewardsPerInviter) ?? fallback.maxRewardsPerInviter
        )
        self = self.normalized
    }
}

/// One invited user: who brought them and whether the pair was already paid.
/// Keyed by the *invited* userID — that is the identity the anti-fraud rules
/// key on ("one attribution per person, ever").
struct ReferralRecord: Codable, Sendable, Equatable {
    var inviterUserID: Int
    /// Lowercased @username of the inviter, resolved when the link was used —
    /// balances are keyed by username, so it is captured up front.
    var inviterUsername: String
    /// Lowercased @username of the invited user, when they have one.
    var invitedUsername: String?
    var boundAt: Date
    /// Set once the pair is resolved (paid or refused) — makes payout
    /// idempotent no matter how often the invited user writes.
    var rewardedAt: Date?
    var inviterRewardUsd: Double
    var inviteeRewardUsd: Double
    /// The payout was refused by the anti-farming cap (kept for monitoring).
    var blocked: Bool

    init(
        inviterUserID: Int,
        inviterUsername: String,
        invitedUsername: String?,
        boundAt: Date = Date(),
        rewardedAt: Date? = nil,
        inviterRewardUsd: Double = 0,
        inviteeRewardUsd: Double = 0,
        blocked: Bool = false
    ) {
        self.inviterUserID = inviterUserID
        self.inviterUsername = inviterUsername
        self.invitedUsername = invitedUsername
        self.boundAt = boundAt
        self.rewardedAt = rewardedAt
        self.inviterRewardUsd = inviterRewardUsd
        self.inviteeRewardUsd = inviteeRewardUsd
        self.blocked = blocked
    }

    var isPending: Bool { rewardedAt == nil }
}

/// Per-inviter aggregate. Survives record pruning, so the anti-farming cap can
/// never be reset by the ledger growing past its size limit.
struct ReferralTally: Codable, Sendable, Equatable {
    var username: String
    var invited: Int
    var rewarded: Int
    var blocked: Int
    var earnedUsd: Double

    init(username: String, invited: Int = 0, rewarded: Int = 0, blocked: Int = 0, earnedUsd: Double = 0) {
        self.username = username
        self.invited = invited
        self.rewarded = rewarded
        self.blocked = blocked
        self.earnedUsd = earnedUsd
    }
}

/// The whole referral bookkeeping in one `bot_config` row
/// (`GlobalConfigKey.referralLedger`): attributions + per-inviter aggregates.
struct ReferralLedger: Codable, Sendable {
    /// Keyed by String(invited userID) — JSON object keys must be strings.
    var records: [String: ReferralRecord]
    /// Keyed by String(inviter userID).
    var tallies: [String: ReferralTally]
    /// Running total of everything the program has paid out, both sides. Stored
    /// rather than summed over records so pruning never rewrites history.
    var paidOutUsd: Double

    /// Size guards: this is a single JSON row, so it must stay bounded. Only
    /// *resolved* records are ever dropped — a paid user is no longer "new", so
    /// the "not a new user" rule already blocks re-attribution without them.
    static let maxRecords = 5000
    static let maxTallies = 5000

    static let empty = ReferralLedger()

    init(
        records: [String: ReferralRecord] = [:],
        tallies: [String: ReferralTally] = [:],
        paidOutUsd: Double = 0
    ) {
        self.records = records
        self.tallies = tallies
        self.paidOutUsd = paidOutUsd
    }

    enum CodingKeys: String, CodingKey {
        case records, tallies, paidOutUsd
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            records: try c.decodeIfPresent([String: ReferralRecord].self, forKey: .records) ?? [:],
            tallies: try c.decodeIfPresent([String: ReferralTally].self, forKey: .tallies) ?? [:],
            paidOutUsd: try c.decodeIfPresent(Double.self, forKey: .paidOutUsd) ?? 0
        )
    }

    var pendingCount: Int { records.values.filter(\.isPending).count }
    var rewardedCount: Int { records.values.filter { !$0.isPending && !$0.blocked }.count }
    var blockedCount: Int { records.values.filter(\.blocked).count }

    func topInviters(limit: Int) -> [ReferralTopInviter] {
        tallies
            .compactMap { key, tally -> ReferralTopInviter? in
                guard let userID = Int(key) else { return nil }
                return ReferralTopInviter(userID: userID, tally: tally)
            }
            .sorted {
                if $0.tally.rewarded != $1.tally.rewarded { return $0.tally.rewarded > $1.tally.rewarded }
                return $0.tally.invited > $1.tally.invited
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Drops the oldest resolved records / least active tallies once the row
    /// outgrows its budget. Pending records are never dropped — they still owe
    /// somebody money.
    mutating func prune() {
        if records.count > Self.maxRecords {
            let resolved = records
                .filter { !$0.value.isPending }
                .sorted { ($0.value.rewardedAt ?? $0.value.boundAt) < ($1.value.rewardedAt ?? $1.value.boundAt) }
            var overflow = records.count - Self.maxRecords
            for entry in resolved where overflow > 0 {
                records.removeValue(forKey: entry.key)
                overflow -= 1
            }
        }
        if tallies.count > Self.maxTallies {
            let ordered = tallies.sorted {
                if $0.value.rewarded != $1.value.rewarded { return $0.value.rewarded > $1.value.rewarded }
                return $0.value.invited > $1.value.invited
            }
            tallies = Dictionary(uniqueKeysWithValues: ordered.prefix(Self.maxTallies).map { ($0.key, $0.value) })
        }
    }
}

struct ReferralTopInviter: Sendable {
    let userID: Int
    let tally: ReferralTally
}

/// What happened when someone opened a referral link.
enum ReferralBindOutcome: Sendable, Equatable {
    /// Attribution recorded; the reward lands after the friend's first answer.
    /// `needsUsername` — the invited side has no @username, so only the inviter
    /// can be credited until they set one.
    case bound(inviter: String, inviteeRewardUsd: Double, needsUsername: Bool)
    case selfInvite
    /// Already attributed (to this or another inviter) — one per person, ever.
    case alreadyBound(inviter: String)
    /// The person already used the bot before the link — not a new user.
    case notNewUser
    /// The inviter has never talked to the bot in private, so their @username
    /// (and therefore their wallet) is unknown.
    case unknownInviter
    case disabled
}

/// A resolved pair, ready to be announced to both sides.
struct ReferralPayout: Sendable {
    let inviterUserID: Int
    let inviterUsername: String
    let inviterRewardUsd: Double
    let invitedUsername: String?
    let inviteeRewardUsd: Double
    /// Total rewarded invites of this inviter after this payout.
    let inviterRewardedTotal: Int
}

/// Personal referral state for the `/ref` page.
struct ReferralUserStats: Sendable {
    var invited: Int
    var rewarded: Int
    var pending: Int
    var earnedUsd: Double
    /// Remaining rewarded invites under the cap; nil = uncapped.
    var capRemaining: Int?
    /// Set when *this* user arrived through someone's link.
    var incoming: ReferralRecord?
}

/// Program-wide numbers for the super-admin page and `/metrics`.
struct ReferralOverview: Sendable {
    var bound: Int
    var pending: Int
    var rewarded: Int
    var blocked: Int
    var paidOutUsd: Double
    var inviters: Int
    var top: [ReferralTopInviter]
}
