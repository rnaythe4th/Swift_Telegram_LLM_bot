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
    /// One-off bonus to the inviter the first time their friend actually pays
    /// (subscription or credit pack), in USD cents. 0 = off.
    ///
    /// The signup reward buys registrations; this one buys customers. It is
    /// deliberately *not* subject to `maxRewardsPerInviter`: that cap exists to
    /// make farming free signups pointless, and a friend who moved real money
    /// is the opposite of a farmed account.
    var payingFriendBonusCents: Int

    static let `default` = ReferralConfig(
        enabled: true,
        inviterRewardCents: 100,
        inviteeRewardCents: 100,
        maxRewardsPerInviter: 20,
        payingFriendBonusCents: 200
    )

    // Bounds: a typo must not be able to drain the balance sheet.
    static let rewardRange = 0...5000   // up to $50 per side
    static let capRange = 0...10000

    var inviterRewardUsd: Double { Double(inviterRewardCents) / 100.0 }
    var inviteeRewardUsd: Double { Double(inviteeRewardCents) / 100.0 }
    var payingFriendBonusUsd: Double { Double(payingFriendBonusCents) / 100.0 }
    /// False when every reward is set to zero — the program runs but pays nothing.
    var paysAnything: Bool {
        inviterRewardCents > 0 || inviteeRewardCents > 0 || payingFriendBonusCents > 0
    }
    /// False when nothing lands at signup — the bind-time copy must not promise
    /// money in that case, even though the paid bonus may still be live.
    var paysOnSignup: Bool { inviterRewardCents > 0 || inviteeRewardCents > 0 }

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
        copy.payingFriendBonusCents = Self.clamp(payingFriendBonusCents, Self.rewardRange)
        return copy
    }

    private static func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    enum CodingKeys: String, CodingKey {
        case enabled, inviterRewardCents, inviteeRewardCents, maxRewardsPerInviter
        case payingFriendBonusCents
    }

    init(
        enabled: Bool,
        inviterRewardCents: Int,
        inviteeRewardCents: Int,
        maxRewardsPerInviter: Int,
        payingFriendBonusCents: Int
    ) {
        self.enabled = enabled
        self.inviterRewardCents = inviterRewardCents
        self.inviteeRewardCents = inviteeRewardCents
        self.maxRewardsPerInviter = maxRewardsPerInviter
        self.payingFriendBonusCents = payingFriendBonusCents
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
            maxRewardsPerInviter: try c.decodeIfPresent(Int.self, forKey: .maxRewardsPerInviter) ?? fallback.maxRewardsPerInviter,
            payingFriendBonusCents: try c.decodeIfPresent(Int.self, forKey: .payingFriendBonusCents) ?? fallback.payingFriendBonusCents
        )
        self = self.normalized
    }
}

/// One invited user: who brought them and whether the pair was already paid.
/// Keyed by the *invited* userID — that is the identity the anti-fraud rules
/// key on ("one attribution per person, ever").
struct ReferralRecord: Codable, Sendable, Equatable {
    var inviterUserID: Int
    /// Display label of the inviter at the time of the last write. Wallets are
    /// keyed by userID (`UserKey`), so this is shown, never paid to — it is
    /// refreshed whenever the person is seen with a new @username.
    var inviterUsername: String
    /// Display label of the invited user, when they have a @username.
    var invitedUsername: String?
    var boundAt: Date
    /// Set once the pair is resolved (paid or refused) — makes payout
    /// idempotent no matter how often the invited user writes.
    var rewardedAt: Date?
    var inviterRewardUsd: Double
    var inviteeRewardUsd: Double
    /// The payout was refused by the anti-farming cap (kept for monitoring).
    var blocked: Bool
    /// Set the first time this friend paid for anything and the inviter's
    /// bonus was credited — makes the bonus one-per-pair, ever.
    var paidBonusAt: Date?
    var paidBonusUsd: Double

    init(
        inviterUserID: Int,
        inviterUsername: String,
        invitedUsername: String?,
        boundAt: Date = Date(),
        rewardedAt: Date? = nil,
        inviterRewardUsd: Double = 0,
        inviteeRewardUsd: Double = 0,
        blocked: Bool = false,
        paidBonusAt: Date? = nil,
        paidBonusUsd: Double = 0
    ) {
        self.inviterUserID = inviterUserID
        self.inviterUsername = inviterUsername
        self.invitedUsername = invitedUsername
        self.boundAt = boundAt
        self.rewardedAt = rewardedAt
        self.inviterRewardUsd = inviterRewardUsd
        self.inviteeRewardUsd = inviteeRewardUsd
        self.blocked = blocked
        self.paidBonusAt = paidBonusAt
        self.paidBonusUsd = paidBonusUsd
    }

    var isPending: Bool { rewardedAt == nil }
    /// The friend turned into a paying customer.
    var converted: Bool { paidBonusAt != nil }

    enum CodingKeys: String, CodingKey {
        case inviterUserID, inviterUsername, invitedUsername, boundAt, rewardedAt
        case inviterRewardUsd, inviteeRewardUsd, blocked, paidBonusAt, paidBonusUsd
    }

    /// Hand-written so that fields added later are optional on the way in — a
    /// record written by an earlier build must keep decoding, otherwise the
    /// whole ledger row fails and every attribution is forgotten at once.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            inviterUserID: try c.decode(Int.self, forKey: .inviterUserID),
            inviterUsername: try c.decodeIfPresent(String.self, forKey: .inviterUsername) ?? "",
            invitedUsername: try c.decodeIfPresent(String.self, forKey: .invitedUsername),
            boundAt: try c.decodeIfPresent(Date.self, forKey: .boundAt) ?? Date(),
            rewardedAt: try c.decodeIfPresent(Date.self, forKey: .rewardedAt),
            inviterRewardUsd: try c.decodeIfPresent(Double.self, forKey: .inviterRewardUsd) ?? 0,
            inviteeRewardUsd: try c.decodeIfPresent(Double.self, forKey: .inviteeRewardUsd) ?? 0,
            blocked: try c.decodeIfPresent(Bool.self, forKey: .blocked) ?? false,
            paidBonusAt: try c.decodeIfPresent(Date.self, forKey: .paidBonusAt),
            paidBonusUsd: try c.decodeIfPresent(Double.self, forKey: .paidBonusUsd) ?? 0
        )
    }
}

/// Per-inviter aggregate. Survives record pruning, so the anti-farming cap can
/// never be reset by the ledger growing past its size limit.
struct ReferralTally: Codable, Sendable, Equatable {
    /// Display label only; the tally is keyed by the inviter's userID.
    var username: String
    var invited: Int
    var rewarded: Int
    var blocked: Int
    var earnedUsd: Double
    /// Friends of this inviter who went on to pay — the number that says
    /// whether their invites are worth anything.
    var paidConversions: Int

    init(
        username: String,
        invited: Int = 0,
        rewarded: Int = 0,
        blocked: Int = 0,
        earnedUsd: Double = 0,
        paidConversions: Int = 0
    ) {
        self.username = username
        self.invited = invited
        self.rewarded = rewarded
        self.blocked = blocked
        self.earnedUsd = earnedUsd
        self.paidConversions = paidConversions
    }

    enum CodingKeys: String, CodingKey {
        case username, invited, rewarded, blocked, earnedUsd, paidConversions
    }

    /// Same reasoning as `ReferralRecord`: later fields must be optional on the
    /// way in, or one old aggregate takes the whole ledger row down with it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            username: try c.decodeIfPresent(String.self, forKey: .username) ?? "",
            invited: try c.decodeIfPresent(Int.self, forKey: .invited) ?? 0,
            rewarded: try c.decodeIfPresent(Int.self, forKey: .rewarded) ?? 0,
            blocked: try c.decodeIfPresent(Int.self, forKey: .blocked) ?? 0,
            earnedUsd: try c.decodeIfPresent(Double.self, forKey: .earnedUsd) ?? 0,
            paidConversions: try c.decodeIfPresent(Int.self, forKey: .paidConversions) ?? 0
        )
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
    /// Link opens that produced no attribution, by reason. Without these a
    /// super-admin cannot tell "nobody clicks the link" from "everybody clicks
    /// it and the rules throw them out" — two problems with opposite fixes.
    var refusedSelf: Int
    var refusedRepeat: Int
    var refusedNotNew: Int
    var refusedUnknown: Int

    /// Every refused open, whatever the reason.
    var refusedTotal: Int { refusedSelf + refusedRepeat + refusedNotNew + refusedUnknown }

    /// Size guards: this is a single JSON row, so it must stay bounded. Only
    /// *resolved* records are ever dropped — a paid user is no longer "new", so
    /// the "not a new user" rule already blocks re-attribution without them.
    static let maxRecords = 5000
    static let maxTallies = 5000

    static let empty = ReferralLedger()

    init(
        records: [String: ReferralRecord] = [:],
        tallies: [String: ReferralTally] = [:],
        paidOutUsd: Double = 0,
        refusedSelf: Int = 0,
        refusedRepeat: Int = 0,
        refusedNotNew: Int = 0,
        refusedUnknown: Int = 0
    ) {
        self.records = records
        self.tallies = tallies
        self.paidOutUsd = paidOutUsd
        self.refusedSelf = refusedSelf
        self.refusedRepeat = refusedRepeat
        self.refusedNotNew = refusedNotNew
        self.refusedUnknown = refusedUnknown
    }

    enum CodingKeys: String, CodingKey {
        case records, tallies, paidOutUsd
        case refusedSelf, refusedRepeat, refusedNotNew, refusedUnknown
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            records: try c.decodeIfPresent([String: ReferralRecord].self, forKey: .records) ?? [:],
            tallies: try c.decodeIfPresent([String: ReferralTally].self, forKey: .tallies) ?? [:],
            paidOutUsd: try c.decodeIfPresent(Double.self, forKey: .paidOutUsd) ?? 0,
            refusedSelf: try c.decodeIfPresent(Int.self, forKey: .refusedSelf) ?? 0,
            refusedRepeat: try c.decodeIfPresent(Int.self, forKey: .refusedRepeat) ?? 0,
            refusedNotNew: try c.decodeIfPresent(Int.self, forKey: .refusedNotNew) ?? 0,
            refusedUnknown: try c.decodeIfPresent(Int.self, forKey: .refusedUnknown) ?? 0
        )
    }

    var pendingCount: Int { records.values.filter(\.isPending).count }
    var rewardedCount: Int { records.values.filter { !$0.isPending && !$0.blocked }.count }
    var blockedCount: Int { records.values.filter(\.blocked).count }
    /// Counted on the aggregates, not on the records: a converted friend's
    /// record is resolved and may eventually be pruned, but the number of
    /// customers an inviter brought must never shrink.
    var paidConversionCount: Int { tallies.values.reduce(0) { $0 + $1.paidConversions } }

    func topInviters(limit: Int) -> [ReferralTopInviter] {
        tallies
            .compactMap { key, tally -> ReferralTopInviter? in
                guard let userID = Int(key) else { return nil }
                return ReferralTopInviter(userID: userID, tally: tally)
            }
            // Paying friends first: an inviter who brought two customers is
            // worth more than one who brought twenty idle signups.
            .sorted {
                if $0.tally.paidConversions != $1.tally.paidConversions {
                    return $0.tally.paidConversions > $1.tally.paidConversions
                }
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
    /// Neither side needs a @username — wallets are keyed by userID.
    case bound(inviter: String, inviteeRewardUsd: Double)
    /// Attribution recorded, but the inviter has already used up their reward
    /// cap, so this pair will not pay. Reported separately so the greeting can
    /// stay honest instead of promising money that never arrives.
    case boundWithoutReward(inviter: String)
    case selfInvite
    /// Already attributed (to this or another inviter) — one per person, ever.
    case alreadyBound(inviter: String)
    /// The person already used the bot before the link — not a new user.
    case notNewUser
    /// The link carries a userID the bot has never seen — nothing to attribute
    /// it to, so it is refused rather than paid into the void.
    case unknownInviter
    case disabled
}

/// A resolved pair, ready to be announced to both sides.
struct ReferralPayout: Sendable {
    let inviterUserID: Int
    let inviterUsername: String
    let inviterRewardUsd: Double
    let invitedUsername: String?
    /// Ready-to-print name of the friend: `@ник` / имя / `id 12345`. Works for
    /// someone who never set a @username, unlike `invitedUsername`.
    let invitedLabel: String
    let inviteeRewardUsd: Double
    /// Total rewarded invites of this inviter after this payout.
    let inviterRewardedTotal: Int
}

/// An invited friend paid for the first time and their inviter earned the
/// conversion bonus (§7 «Реферал»).
struct ReferralPaymentBonus: Sendable {
    let inviterUserID: Int
    let inviterLabel: String
    let friendLabel: String
    let amountUsd: Double
    /// How many paying friends this inviter has brought in total.
    let inviterPaidTotal: Int
}

/// Personal referral state for the `/ref` page.
struct ReferralUserStats: Sendable {
    var invited: Int
    var rewarded: Int
    var pending: Int
    var earnedUsd: Double
    /// Invited friends who went on to pay.
    var paidConversions: Int
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
    /// Invited friends who became paying customers — the number that says
    /// whether the program earns its payouts back.
    var paidConversions: Int = 0
    /// Refused link opens by reason — see `ReferralLedger`.
    var refusedSelf: Int = 0
    var refusedRepeat: Int = 0
    var refusedNotNew: Int = 0
    var refusedUnknown: Int = 0

    var refusedTotal: Int { refusedSelf + refusedRepeat + refusedNotNew + refusedUnknown }
    /// Every link open the bot saw: the ones that stuck plus the ones refused.
    var opens: Int { bound + refusedTotal }
}
