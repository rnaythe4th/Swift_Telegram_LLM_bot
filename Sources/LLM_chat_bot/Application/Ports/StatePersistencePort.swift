import Foundation

/// Keys of singleton configuration values stored one-per-row in `bot_config`.
enum GlobalConfigKey: String, CaseIterable, Sendable {
    case starsPrice = "stars_price"
    case starsPerUsd = "stars_per_usd"
    case freeModels = "free_models"
    case crypto = "crypto"
    case card = "card"
    case superAdmins = "super_admins"
    case processedPayments = "processed_payments"
    case pollingOffset = "polling_offset"
    case chatMeta = "chat_meta"
    case invites = "invites"
    case ads = "ads"
    case markup = "markup"
    case balances = "balances"
    case funnel = "funnel"
    case funnelDaily = "funnel_daily"
    case dailyPremiumLimit = "daily_premium_limit"
    case dailyPremiumUsage = "daily_premium_usage"
    case selfPromo = "self_promo"
    case reminders = "reminders"
    case onboarding = "onboarding"
    case referrals = "referrals"
    case referralLedger = "referral_ledger"
    case userDirectory = "user_directory"
}

struct ChatContextRow: Sendable {
    let key: ChatKey
    let snapshot: ChatContextSnapshot
}

struct TenantRow: Sendable {
    let username: String
    let snapshot: TenantStateSnapshot
}

struct OwnershipRow: Sendable {
    let chatID: Int
    let owner: String
}

enum GlobalConfigValue: Sendable {
    case starsPrice(Int?)
    /// Stars charged per $1 for credit-pack purchases.
    case starsPerUsd(Int)
    case freeModels([String])
    case crypto(CryptoConfigSnapshot)
    case card(CardPaymentConfig)
    case superAdmins([String])
    case processedPayments([String])
    case pollingOffset(Int)
    /// Keyed by String(chatID) — JSON object keys must be strings.
    case chatMeta([String: ChatMetaInfo])
    /// Invite token → record.
    case invites([String: InviteRecord])
    case ads([AdCampaign])
    /// Markup percent applied to provider prices for customers.
    case markup(Int)
    /// Keyed by `UserKey` (`#<userID>`, or a bare username while pending).
    case balances([String: UserBalance])
    /// Conversion-funnel event counters, keyed by FunnelEvent.rawValue.
    case funnel([String: Int])
    /// The same counters bucketed per day, for period views (roadmap step 7).
    case funnelDaily(FunnelDailyLog)
    /// Daily free-premium "taste" allowance per free-tier chat/user (roadmap step 6).
    case dailyPremiumLimit(Int)
    /// How much of today's allowance each free-tier chat/user has spent (step 6).
    case dailyPremiumUsage([String: DailyPremiumUsage])
    /// Built-in self-promo filling the free-tier ad slot (roadmap step 5).
    case selfPromo(SelfPromoConfig)
    /// Renewal-reminder / winback schedule (roadmap step 8).
    case reminders(SubscriptionReminderConfig)
    /// Greeting example prompts + their tap counters (roadmap step 9).
    case onboarding(OnboardingConfig)
    /// Two-sided referral economics (roadmap step 10).
    case referrals(ReferralConfig)
    /// Referral attributions + per-inviter aggregates (roadmap step 10).
    case referralLedger(ReferralLedger)
    /// userID ↔ @username directory behind every `UserKey`.
    case userDirectory(UserDirectory)

    var key: GlobalConfigKey {
        switch self {
        case .starsPrice: return .starsPrice
        case .starsPerUsd: return .starsPerUsd
        case .freeModels: return .freeModels
        case .crypto: return .crypto
        case .card: return .card
        case .superAdmins: return .superAdmins
        case .processedPayments: return .processedPayments
        case .pollingOffset: return .pollingOffset
        case .chatMeta: return .chatMeta
        case .invites: return .invites
        case .ads: return .ads
        case .markup: return .markup
        case .balances: return .balances
        case .funnel: return .funnel
        case .funnelDaily: return .funnelDaily
        case .dailyPremiumLimit: return .dailyPremiumLimit
        case .dailyPremiumUsage: return .dailyPremiumUsage
        case .selfPromo: return .selfPromo
        case .reminders: return .reminders
        case .onboarding: return .onboarding
        case .referrals: return .referrals
        case .referralLedger: return .referralLedger
        case .userDirectory: return .userDirectory
        }
    }
}

/// One incremental write: only entities that changed since the previous drain.
/// Replaces the old whole-state snapshot, so a flush stays O(changed), not
/// O(all chats), no matter how many chats the bot serves.
struct PersistenceBatch: Sendable {
    var contexts: [ChatContextRow] = []
    var tenants: [TenantRow] = []
    var deletedTenants: [String] = []
    var ownership: [OwnershipRow] = []
    var deletedOwnership: [Int] = []
    var configs: [GlobalConfigValue] = []

    var isEmpty: Bool {
        contexts.isEmpty && tenants.isEmpty && deletedTenants.isEmpty
            && ownership.isEmpty && deletedOwnership.isEmpty && configs.isEmpty
    }

    var entityCount: Int {
        contexts.count + tenants.count + deletedTenants.count
            + ownership.count + deletedOwnership.count + configs.count
    }

    /// Combines a batch that failed to flush with a freshly drained one.
    /// Rows from `newer` win — they were exported from the store later.
    static func merged(older: PersistenceBatch, newer: PersistenceBatch) -> PersistenceBatch {
        var contextsByKey: [ChatKey: ChatContextRow] = [:]
        for row in older.contexts { contextsByKey[row.key] = row }
        for row in newer.contexts { contextsByKey[row.key] = row }

        var tenantsByName: [String: TenantRow] = [:]
        for row in older.tenants { tenantsByName[row.username] = row }
        var deletedTenants = Set(older.deletedTenants)
        for name in newer.deletedTenants {
            deletedTenants.insert(name)
            tenantsByName.removeValue(forKey: name)
        }
        for row in newer.tenants {
            tenantsByName[row.username] = row
            deletedTenants.remove(row.username)
        }

        var ownershipByChat: [Int: OwnershipRow] = [:]
        for row in older.ownership { ownershipByChat[row.chatID] = row }
        var deletedOwnership = Set(older.deletedOwnership)
        for chatID in newer.deletedOwnership {
            deletedOwnership.insert(chatID)
            ownershipByChat.removeValue(forKey: chatID)
        }
        for row in newer.ownership {
            ownershipByChat[row.chatID] = row
            deletedOwnership.remove(row.chatID)
        }

        var configsByKey: [GlobalConfigKey: GlobalConfigValue] = [:]
        for value in older.configs { configsByKey[value.key] = value }
        for value in newer.configs { configsByKey[value.key] = value }

        var result = PersistenceBatch()
        result.contexts = Array(contextsByKey.values)
        result.tenants = Array(tenantsByName.values)
        result.deletedTenants = Array(deletedTenants)
        result.ownership = Array(ownershipByChat.values)
        result.deletedOwnership = Array(deletedOwnership)
        result.configs = Array(configsByKey.values)
        return result
    }
}

struct PersistedGlobalConfigs: Sendable {
    var starsPrice: Int?
    var starsPerUsd: Int?
    var freeModelIDs: [String]?
    var crypto: CryptoConfigSnapshot?
    var card: CardPaymentConfig?
    var superAdmins: [String]?
    var processedPayments: [String]?
    var pollingOffset: Int?
    var chatMeta: [String: ChatMetaInfo]?
    var invites: [String: InviteRecord]?
    var ads: [AdCampaign]?
    var markup: Int?
    var balances: [String: UserBalance]?
    var funnel: [String: Int]?
    var funnelDaily: FunnelDailyLog?
    var dailyPremiumLimit: Int?
    var dailyPremiumUsage: [String: DailyPremiumUsage]?
    var selfPromo: SelfPromoConfig?
    var reminders: SubscriptionReminderConfig?
    var onboarding: OnboardingConfig?
    var referrals: ReferralConfig?
    var referralLedger: ReferralLedger?
    var userDirectory: UserDirectory?

    var hasAnyValue: Bool {
        starsPrice != nil || starsPerUsd != nil || freeModelIDs != nil || crypto != nil || card != nil
            || superAdmins != nil || processedPayments != nil || pollingOffset != nil
            || chatMeta != nil || invites != nil || ads != nil
            || markup != nil || balances != nil || funnel != nil || funnelDaily != nil
            || dailyPremiumLimit != nil || dailyPremiumUsage != nil || selfPromo != nil
            || reminders != nil || onboarding != nil || referrals != nil || referralLedger != nil
            || userDirectory != nil
    }
}

struct PersistedBotState: Sendable {
    var contexts: [ChatContextRow]
    var tenants: [TenantRow]
    var ownership: [OwnershipRow]
    var configs: PersistedGlobalConfigs

    /// True when the new-schema tables hold nothing yet — triggers a one-time
    /// import of the legacy whole-state snapshot if one exists. Any config row
    /// counts as "not empty" so a stale legacy blob can never overwrite data
    /// already migrated to rows.
    var isEmpty: Bool { contexts.isEmpty && tenants.isEmpty && !configs.hasAnyValue }
}

protocol StatePersistencePort: Sendable {
    func loadEverything() async throws -> PersistedBotState
    /// Pre-migration format: the single JSON blob in `bot_state`.
    func loadLegacySnapshot() async throws -> BotStateSnapshot?
    func apply(_ batch: PersistenceBatch) async throws
}
