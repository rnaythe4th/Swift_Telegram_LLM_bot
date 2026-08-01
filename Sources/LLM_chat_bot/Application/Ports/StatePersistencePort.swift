import Foundation

/// Keys of singleton configuration values stored one-per-row in `bot_config`.
///
/// What is left here is what a `bot_config` row is *for*: a document that is
/// always read and written whole and that nobody ever searches inside. Anything
/// that grows with the number of users — the directory, wallets, chat metadata,
/// referral records, traffic attributions, processed payments — is a table now
/// (§2.1), because a single JSON row rewritten on every new person is a
/// scaling limit dressed up as a config value.
enum GlobalConfigKey: String, CaseIterable, Sendable {
    case starsPrice = "stars_price"
    case starsPerUsd = "stars_per_usd"
    case freeModels = "free_models"
    case crypto = "crypto"
    case card = "card"
    case superAdmins = "super_admins"
    case pollingOffset = "polling_offset"
    case ads = "ads"
    case markup = "markup"
    case funnel = "funnel"
    case dailyPremiumLimit = "daily_premium_limit"
    case selfPromo = "self_promo"
    case modes = "modes"
    case reminders = "reminders"
    case onboarding = "onboarding"
    case referrals = "referrals"
    /// Program-wide referral counters (payout total, refusal reasons). The
    /// records and per-inviter tallies behind them are tables.
    case referralTotals = "referral_totals"
    /// Campaign-level `src_` aggregates; the per-person attributions are a table.
    case trafficTotals = "traffic_totals"
    /// Hosted checkout: merchant credentials and prices. The open orders are a
    /// table — an order is a payment in flight, not a setting.
    case externalPayments = "external_payments"
    /// Spending ceilings (§4.1): the only thing standing between a subscriber
    /// with a heavy group and an unbounded provider bill.
    case spendPolicy = "spend_policy"
}

// MARK: - Rows

struct ChatContextRow: Sendable {
    let key: ChatKey
    let snapshot: ChatContextSnapshot
}

struct TenantRow: Sendable {
    let username: String
    let snapshot: TenantStateSnapshot
}

/// One person: the directory entry plus the DM the bot can reach them at.
/// `bot_user` is the table every other per-person table points at.
struct UserRow: Sendable {
    let identity: UserIdentity
}

/// One chat: its human-readable identity and which tenant's licence covers it.
/// Metadata and ownership used to be two config documents; they are one row
/// because they describe one thing and are read together everywhere.
struct ChatRow: Sendable {
    let chatID: Int
    let meta: ChatMetaInfo?
    let ownerKey: String?
}

struct InviteRow: Sendable {
    let token: String
    let record: InviteRecord
}

/// One free-tier chat's (or user's) daily premium allowance.
struct PremiumUsageRow: Sendable {
    let subject: String
    let usage: DailyPremiumUsage
}

/// One referral attribution.
struct ReferralRow: Sendable {
    let invitedUserID: Int
    let record: ReferralRecord
}

/// Per-inviter aggregates. Deliberately a row of their own: they outlive the
/// records they were computed from, so pruning attributions can never reset an
/// inviter's reward cap or their "friends who paid" count.
struct ReferralTallyRow: Sendable {
    let inviterUserID: Int
    let tally: ReferralTally
}

/// One `src_` attribution: who arrived from which campaign and how far they got.
struct TrafficAttributionRow: Sendable {
    let userID: Int
    let attribution: TrafficSourceAttribution
}

/// One conversion-funnel counter for one day.
struct FunnelDayRow: Sendable {
    let day: Int
    let event: String
    let count: Int
}

struct CryptoInvoiceRow: Sendable {
    let invoice: CryptoInvoice
}

struct ExternalOrderRow: Sendable {
    let order: ExternalPaymentOrder
}

// MARK: - Config values

enum GlobalConfigValue: Sendable {
    case starsPrice(Int?)
    /// Stars charged per $1 for credit-pack purchases.
    case starsPerUsd(Int)
    case freeModels([String])
    case crypto(CryptoConfigSnapshot)
    case card(CardPaymentConfig)
    case superAdmins([String])
    case pollingOffset(Int)
    case ads([AdCampaign])
    /// Markup percent applied to provider prices for customers.
    case markup(Int)
    /// Conversion-funnel event counters, keyed by FunnelEvent.rawValue.
    case funnel([String: Int])
    /// Daily free-premium "taste" allowance per free-tier chat/user.
    case dailyPremiumLimit(Int)
    /// Built-in self-promo filling the free-tier ad slot.
    case selfPromo(SelfPromoConfig)
    /// Reference modes: the settings bundles a user picks in one tap.
    case modes(ModePresetConfig)
    /// Renewal-reminder / winback schedule.
    case reminders(SubscriptionReminderConfig)
    /// Greeting example prompts + their tap counters.
    case onboarding(OnboardingConfig)
    /// Two-sided referral economics.
    case referrals(ReferralConfig)
    /// Program-wide referral counters.
    case referralTotals(ReferralTotals)
    /// Campaign-level `src_` aggregates.
    case trafficTotals(TrafficSourceTotals)
    /// Third-party hosted checkout: credentials and prices.
    case externalPayments(ExternalPaymentConfig)
    /// Provider spending ceilings.
    case spendPolicy(SpendPolicy)

    var key: GlobalConfigKey {
        switch self {
        case .starsPrice: return .starsPrice
        case .starsPerUsd: return .starsPerUsd
        case .freeModels: return .freeModels
        case .crypto: return .crypto
        case .card: return .card
        case .superAdmins: return .superAdmins
        case .pollingOffset: return .pollingOffset
        case .ads: return .ads
        case .markup: return .markup
        case .funnel: return .funnel
        case .dailyPremiumLimit: return .dailyPremiumLimit
        case .selfPromo: return .selfPromo
        case .modes: return .modes
        case .reminders: return .reminders
        case .onboarding: return .onboarding
        case .referrals: return .referrals
        case .referralTotals: return .referralTotals
        case .trafficTotals: return .trafficTotals
        case .externalPayments: return .externalPayments
        case .spendPolicy: return .spendPolicy
        }
    }
}

/// One incremental write: only entities that changed since the previous drain.
/// A flush stays O(changed), not O(all chats), no matter how many chats the bot
/// serves.
///
/// Money is **not** here. Wallets, the ledger and payment idempotency keys are
/// written through `LedgerPort` inside a transaction and are durable before the
/// caller is told the payment worked (§3.2). What travels in this batch is
/// everything whose loss for two seconds is survivable.
struct PersistenceBatch: Sendable {
    var users: [UserRow] = []
    var contexts: [ChatContextRow] = []
    var deletedContexts: [ChatKey] = []
    var tenants: [TenantRow] = []
    var deletedTenants: [String] = []
    var chats: [ChatRow] = []
    var deletedChats: [Int] = []
    var invites: [InviteRow] = []
    var deletedInvites: [String] = []
    var premiumUsage: [PremiumUsageRow] = []
    var deletedPremiumUsage: [String] = []
    var referrals: [ReferralRow] = []
    var deletedReferrals: [Int] = []
    var referralTallies: [ReferralTallyRow] = []
    var deletedReferralTallies: [Int] = []
    var trafficAttributions: [TrafficAttributionRow] = []
    var deletedTrafficAttributions: [Int] = []
    var funnelDays: [FunnelDayRow] = []
    var cryptoInvoices: [CryptoInvoiceRow] = []
    var deletedCryptoInvoices: [String] = []
    var externalOrders: [ExternalOrderRow] = []
    var deletedExternalOrders: [String] = []
    var configs: [GlobalConfigValue] = []

    var isEmpty: Bool { entityCount == 0 }

    var entityCount: Int {
        users.count + contexts.count + deletedContexts.count
            + tenants.count + deletedTenants.count
            + chats.count + deletedChats.count
            + invites.count + deletedInvites.count
            + premiumUsage.count + deletedPremiumUsage.count
            + referrals.count + deletedReferrals.count
            + referralTallies.count + deletedReferralTallies.count
            + trafficAttributions.count + deletedTrafficAttributions.count
            + funnelDays.count
            + cryptoInvoices.count + deletedCryptoInvoices.count
            + externalOrders.count + deletedExternalOrders.count
            + configs.count
    }

    /// Combines a batch that failed to flush with a freshly drained one.
    /// Rows from `newer` win — they were exported from the store later — and a
    /// delete in `newer` cancels an older write of the same key (and the other
    /// way round), so a retry can never resurrect something that was removed.
    static func merged(older: PersistenceBatch, newer: PersistenceBatch) -> PersistenceBatch {
        var result = PersistenceBatch()
        result.users = Self.mergeUpserts(older.users, newer.users, by: \.identity.userID)
        (result.contexts, result.deletedContexts) = Self.merge(
            older.contexts, older.deletedContexts, newer.contexts, newer.deletedContexts, by: \.key
        )
        (result.tenants, result.deletedTenants) = Self.merge(
            older.tenants, older.deletedTenants, newer.tenants, newer.deletedTenants, by: \.username
        )
        (result.chats, result.deletedChats) = Self.merge(
            older.chats, older.deletedChats, newer.chats, newer.deletedChats, by: \.chatID
        )
        (result.invites, result.deletedInvites) = Self.merge(
            older.invites, older.deletedInvites, newer.invites, newer.deletedInvites, by: \.token
        )
        (result.premiumUsage, result.deletedPremiumUsage) = Self.merge(
            older.premiumUsage, older.deletedPremiumUsage,
            newer.premiumUsage, newer.deletedPremiumUsage, by: \.subject
        )
        (result.referrals, result.deletedReferrals) = Self.merge(
            older.referrals, older.deletedReferrals, newer.referrals, newer.deletedReferrals, by: \.invitedUserID
        )
        (result.referralTallies, result.deletedReferralTallies) = Self.merge(
            older.referralTallies, older.deletedReferralTallies,
            newer.referralTallies, newer.deletedReferralTallies, by: \.inviterUserID
        )
        (result.trafficAttributions, result.deletedTrafficAttributions) = Self.merge(
            older.trafficAttributions, older.deletedTrafficAttributions,
            newer.trafficAttributions, newer.deletedTrafficAttributions, by: \.userID
        )
        result.funnelDays = Self.mergeUpserts(older.funnelDays, newer.funnelDays) { FunnelDayKey(day: $0.day, event: $0.event) }
        (result.cryptoInvoices, result.deletedCryptoInvoices) = Self.merge(
            older.cryptoInvoices, older.deletedCryptoInvoices,
            newer.cryptoInvoices, newer.deletedCryptoInvoices, by: \.invoice.id
        )
        (result.externalOrders, result.deletedExternalOrders) = Self.merge(
            older.externalOrders, older.deletedExternalOrders,
            newer.externalOrders, newer.deletedExternalOrders, by: \.order.id
        )

        var configsByKey: [GlobalConfigKey: GlobalConfigValue] = [:]
        for value in older.configs { configsByKey[value.key] = value }
        for value in newer.configs { configsByKey[value.key] = value }
        result.configs = Array(configsByKey.values)
        return result
    }

    private struct FunnelDayKey: Hashable { let day: Int; let event: String }

    private static func mergeUpserts<Row, Key: Hashable>(
        _ older: [Row], _ newer: [Row], by key: (Row) -> Key
    ) -> [Row] {
        var byKey: [Key: Row] = [:]
        for row in older { byKey[key(row)] = row }
        for row in newer { byKey[key(row)] = row }
        return Array(byKey.values)
    }

    private static func mergeUpserts<Row, Key: Hashable>(
        _ older: [Row], _ newer: [Row], by keyPath: KeyPath<Row, Key>
    ) -> [Row] {
        mergeUpserts(older, newer) { $0[keyPath: keyPath] }
    }

    private static func merge<Row, Key: Hashable>(
        _ olderRows: [Row], _ olderDeletes: [Key],
        _ newerRows: [Row], _ newerDeletes: [Key],
        by keyPath: KeyPath<Row, Key>
    ) -> ([Row], [Key]) {
        var rows: [Key: Row] = [:]
        for row in olderRows { rows[row[keyPath: keyPath]] = row }
        var deletes = Set(olderDeletes)
        for key in newerDeletes {
            deletes.insert(key)
            rows.removeValue(forKey: key)
        }
        for row in newerRows {
            let key = row[keyPath: keyPath]
            rows[key] = row
            deletes.remove(key)
        }
        return (Array(rows.values), Array(deletes))
    }
}

// MARK: - Load

struct PersistedGlobalConfigs: Sendable {
    var starsPrice: Int?
    var starsPerUsd: Int?
    var freeModelIDs: [String]?
    var crypto: CryptoConfigSnapshot?
    var card: CardPaymentConfig?
    var superAdmins: [String]?
    var pollingOffset: Int?
    var ads: [AdCampaign]?
    var markup: Int?
    var funnel: [String: Int]?
    var dailyPremiumLimit: Int?
    var selfPromo: SelfPromoConfig?
    var modes: ModePresetConfig?
    var reminders: SubscriptionReminderConfig?
    var onboarding: OnboardingConfig?
    var referrals: ReferralConfig?
    var referralTotals: ReferralTotals?
    var trafficTotals: TrafficSourceTotals?
    var externalPayments: ExternalPaymentConfig?
    var spendPolicy: SpendPolicy?
}

struct PersistedBotState: Sendable {
    var users: [UserRow] = []
    var contexts: [ChatContextRow] = []
    var tenants: [TenantRow] = []
    var chats: [ChatRow] = []
    var invites: [InviteRow] = []
    var premiumUsage: [PremiumUsageRow] = []
    var referrals: [ReferralRow] = []
    var referralTallies: [ReferralTallyRow] = []
    var trafficAttributions: [TrafficAttributionRow] = []
    var funnelDays: [FunnelDayRow] = []
    var cryptoInvoices: [CryptoInvoiceRow] = []
    var externalOrders: [ExternalOrderRow] = []
    /// Wallets come from the money tables (`LedgerPort`), but they are restored
    /// into the same store, so the boot path carries them together.
    var wallets: [String: UserBalance] = [:]
    var configs: PersistedGlobalConfigs = PersistedGlobalConfigs()
}

protocol StatePersistencePort: Sendable {
    func loadEverything() async throws -> PersistedBotState
    func apply(_ batch: PersistenceBatch) async throws
}
