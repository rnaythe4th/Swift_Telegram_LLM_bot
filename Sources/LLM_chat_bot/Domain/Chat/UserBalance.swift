import Foundation

/// Pay-as-you-go wallet of one user (keyed by lowercased @username).
///
/// The balance lives in the *billed* (marked-up) price world: deposits and
/// deductions are what the user sees. `spentRealUsd` keeps the provider's
/// actual cost alongside, so the super-admin can read the margin directly:
/// margin = spentBilledUsd − spentRealUsd.
struct UserBalance: Codable, Sendable, Equatable {
    var balanceUsd: Double
    var spentBilledUsd: Double
    var spentRealUsd: Double
    var updatedAt: Date?
    /// Real money this person has put into the wallet, ever — credit packs only.
    /// Referral bonuses and super-admin grants are deliberately excluded: this
    /// is what separates a proven payer from someone spending free credit, and
    /// only proven payers are worth a lapsed-wallet offer (§7 «Возврат по
    /// балансу»). Also shows the super-admin who actually pays.
    var toppedUpUsd: Double
    /// When the lapsed-wallet offer was last sent, so it goes out once per
    /// lapse. Cleared by the next top-up — coming back opens a new cycle.
    var lapsedNoticeAt: Date?

    static let empty = UserBalance(
        balanceUsd: 0,
        spentBilledUsd: 0,
        spentRealUsd: 0,
        updatedAt: nil,
        toppedUpUsd: 0,
        lapsedNoticeAt: nil
    )

    enum CodingKeys: String, CodingKey {
        case balanceUsd, spentBilledUsd, spentRealUsd, updatedAt, toppedUpUsd, lapsedNoticeAt
    }

    init(
        balanceUsd: Double,
        spentBilledUsd: Double,
        spentRealUsd: Double,
        updatedAt: Date?,
        toppedUpUsd: Double = 0,
        lapsedNoticeAt: Date? = nil
    ) {
        self.balanceUsd = balanceUsd
        self.spentBilledUsd = spentBilledUsd
        self.spentRealUsd = spentRealUsd
        self.updatedAt = updatedAt
        self.toppedUpUsd = toppedUpUsd
        self.lapsedNoticeAt = lapsedNoticeAt
    }

    /// The new fields are optional on the way in, so wallets written by earlier
    /// builds decode unchanged — they simply count as "never topped up", which
    /// keeps them out of the lapsed-wallet audience until they pay again.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            balanceUsd: try c.decodeIfPresent(Double.self, forKey: .balanceUsd) ?? 0,
            spentBilledUsd: try c.decodeIfPresent(Double.self, forKey: .spentBilledUsd) ?? 0,
            spentRealUsd: try c.decodeIfPresent(Double.self, forKey: .spentRealUsd) ?? 0,
            updatedAt: try c.decodeIfPresent(Date.self, forKey: .updatedAt),
            toppedUpUsd: try c.decodeIfPresent(Double.self, forKey: .toppedUpUsd) ?? 0,
            lapsedNoticeAt: try c.decodeIfPresent(Date.self, forKey: .lapsedNoticeAt)
        )
    }
}

/// One lapsed wallet the sweep decided to reach out to (§7 «Возврат по балансу»).
struct WalletWinbackTarget: Sendable {
    /// Storage key — pass back to `markWalletWinbackSent`.
    let key: String
    /// Ready-to-print name.
    let label: String
    /// The person's DM with the bot; a wallet is personal, so this is the only
    /// channel. Never nil — the store only lists reachable wallets.
    let privateChatID: Int
    /// What they have already paid in, for the copy ("вы уже вложили $X").
    let toppedUpUsd: Double
    /// Days since the bot last saw them.
    let idleDays: Int
}

/// One free-tier chat's (or user's) daily "taste" of premium: how many smart
/// answers it has spent, and on which UTC day (roadmap step 6).
///
/// Persisted (`GlobalConfigKey.dailyPremiumUsage`) rather than in-memory: the
/// bot redeploys often, and an in-memory counter hands everyone a fresh
/// allowance on every deploy — the cap is the main conversion driver, so it
/// must not evaporate. Stale days are pruned on write, so the row stays about
/// as large as "free chats active today".
struct DailyPremiumUsage: Codable, Sendable, Equatable {
    /// UTC day number (Unix epoch seconds / 86400).
    var day: Int
    var used: Int
}

/// Why a chat currently has (or lacks) smart models — see
/// `ChatContextStore.chatAccessStatus`. Lets every surface that talks about
/// premium name the payer instead of pitching a purchase to someone who is
/// already covered (roadmap steps 1 and 3).
enum ChatAccessStatus: Sendable, Equatable {
    /// The asker's own subscription pays; nil = open-ended.
    case ownSubscription(until: Date?)
    /// Someone else's subscription opened this chat — its sponsor.
    case sponsored(String)
    /// Guest of an active licence (named user or per-chat guest list).
    case guest(String)
    /// No subscription; the asker's pay-as-you-go balance covers each answer.
    case balance(Double)
    /// Free tier: free models, ads, daily premium taste.
    case free

    /// True when smart models answer without the free-tier daily cap.
    var isCovered: Bool {
        switch self {
        case .free: return false
        default: return true
        }
    }

    /// Username of whoever pays for this chat, when it isn't the asker.
    var payerUsername: String? {
        switch self {
        case .sponsored(let owner), .guest(let owner): return owner
        case .ownSubscription, .balance, .free: return nil
        }
    }
}
