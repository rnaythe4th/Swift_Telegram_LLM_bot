import Foundation

/// Pay-as-you-go wallet of one user (keyed by `UserKey`, so it survives a
/// rename — see `UserDirectory`).
///
/// The balance lives in the *billed* (marked-up) price world: deposits and
/// deductions are what the user sees. `spentReal` keeps the provider's actual
/// cost alongside, so the super-admin can read the margin directly:
/// margin = spentBilled − spentReal.
///
/// Every amount is `Money` (integer nanodollars) rather than `Double`: a
/// balance is compared against zero to decide access, and a float balance has
/// no zero. See `Money`.
struct UserBalance: Sendable, Equatable {
    var balance: Money
    var spentBilled: Money
    var spentReal: Money
    var updatedAt: Date?
    /// Real money this person has put into the wallet, ever — credit packs only.
    /// Referral bonuses and super-admin grants are deliberately excluded: this
    /// is what separates a proven payer from someone spending free credit, and
    /// only proven payers are worth a lapsed-wallet offer (§7 «Возврат по
    /// балансу»). Also shows the super-admin who actually pays.
    var toppedUp: Money
    /// When the lapsed-wallet offer was last sent, so it goes out once per
    /// lapse. Cleared by the next top-up — coming back opens a new cycle.
    var lapsedNoticeAt: Date?

    static let empty = UserBalance(
        balance: .zero,
        spentBilled: .zero,
        spentReal: .zero,
        updatedAt: nil,
        toppedUp: .zero,
        lapsedNoticeAt: nil
    )

    init(
        balance: Money,
        spentBilled: Money = .zero,
        spentReal: Money = .zero,
        updatedAt: Date? = nil,
        toppedUp: Money = .zero,
        lapsedNoticeAt: Date? = nil
    ) {
        self.balance = balance
        self.spentBilled = spentBilled
        self.spentReal = spentReal
        self.updatedAt = updatedAt
        self.toppedUp = toppedUp
        self.lapsedNoticeAt = lapsedNoticeAt
    }

    /// Margin the owner earned on this wallet: what was charged minus what the
    /// providers actually cost.
    var margin: Money { spentBilled - spentReal }
}

/// One lapsed wallet the sweep decided to reach out to (§7 «Возврат по балансу»).
struct WalletWinbackTarget: Sendable {
    /// Storage key — pass back to `markWalletWinbackSent`.
    let key: UserKey
    /// Ready-to-print name.
    let label: String
    /// The person's DM with the bot; a wallet is personal, so this is the only
    /// channel. Never nil — the store only lists reachable wallets.
    let privateChatID: ChatID
    /// What they have already paid in, for the copy ("вы уже вложили $X").
    let toppedUp: Money
    /// Days since the bot last saw them.
    let idleDays: Int
}

/// One free-tier chat's (or user's) daily "taste" of premium: how many smart
/// answers it has spent, and on which UTC day (roadmap step 6).
///
/// Persisted (`bot_premium_usage`) rather than in-memory: the
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
    case balance(Money)
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
