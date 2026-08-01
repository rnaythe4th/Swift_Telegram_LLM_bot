import Foundation

// The single owner of all mutable bot state. Storage and the boot wiring live
// here; the behaviour is split across ChatContextStore+*.swift by area.

actor ChatContextStore {
    // Storage is `internal` (not private) so the ChatContextStore+*.swift
    // extensions can reach it; nothing outside the actor touches it directly.
    var contexts: [ChatKey: ChatContext] = [:]
    var tenants: [UserKey: TenantState] = [:]
    var chatOwnership: [Int: UserKey] = [:]
    var userTenantMap: [Int: UserKey] = [:]

    var superAdminKeys: Set<UserKey>
    /// Owner as configured at boot (`OWNER_USER_ID` / `OWNER_USERNAME`). A seed:
    /// `rootSuperAdminKey` prefers what the directory has pinned since.
    let configuredOwnerKey: UserKey
    /// Owner's Telegram userID when configured (`OWNER_USER_ID`). Root is then
    /// this account and nothing else — not a stored key, not a handle.
    let pinnedOwnerUserID: Int?
    var formatOptions: String
    let companyChatId: Int
    let companyMembers: String
    let defaultSuffix: Int?

    let initialDefaultModel: String
    let initialDefaultRole: String
    let initialDefaultHistoryLength: Int

    // MARK: - Dirty tracking (drained by PersistenceCoordinator)

    // Every mutable entity has a set here, and every mutation marks its own.
    // Anything that grows with the user base is tracked per row, so a flush
    // writes the wallet that changed rather than the file that holds all of
    // them (§2.1).
    var dirtyContexts = Set<ChatKey>()
    var deletedContexts = Set<ChatKey>()
    var dirtyTenants = Set<UserKey>()
    var deletedTenants = Set<UserKey>()
    /// Chat identity *and* which tenant's licence covers it — one row, because
    /// they describe one thing and are always read together.
    var dirtyChats = Set<Int>()
    var deletedChats = Set<Int>()
    var dirtyUsers = Set<Int>()
    /// Wallets are drained by the ledger, not by the write-behind batch: money
    /// is written through a transaction (§3.2). The set exists so a cache-only
    /// change (a rename adopting a wallet) still reaches storage.
    var dirtyWallets = Set<UserKey>()
    var deletedWallets = Set<UserKey>()
    var dirtyInvites = Set<String>()
    var deletedInvites = Set<String>()
    var dirtyPremiumUsage = Set<String>()
    var deletedPremiumUsage = Set<String>()
    var dirtyReferrals = Set<Int>()
    var deletedReferrals = Set<Int>()
    var dirtyReferralTallies = Set<Int>()
    var deletedReferralTallies = Set<Int>()
    var dirtyTrafficAttributions = Set<Int>()
    var deletedTrafficAttributions = Set<Int>()
    var dirtyFunnelDays = Set<FunnelDayKey>()
    var dirtyCryptoInvoices = Set<String>()
    var deletedCryptoInvoices = Set<String>()
    var dirtyExternalOrders = Set<String>()
    var deletedExternalOrders = Set<String>()
    var dirtyConfigs = Set<GlobalConfigKey>()
    var pollingOffsetValue: Int? = nil
    var chatMetaByID: [Int: ChatMetaInfo] = [:]
    var inviteRecords: [String: InviteRecord] = [:]
    var adCampaignList: [AdCampaign] = []
    /// Markup percent on provider prices for customer-facing costs and
    /// balance charging.
    var markupPercentValue: Int = 30
    /// Free-premium "taste" answers granted per day to a free-tier chat (group,
    /// shared) or user (private) before a paid model falls back to free (roadmap
    /// step 6). Super-admin-configurable; persisted via
    /// GlobalConfigKey.dailyPremiumLimit. 0 = no free premium taste at all.
    var dailyPremiumLimitValue: Int = 5
    /// Renewal-reminder / winback schedule (roadmap step 8). Super-admin knob,
    /// persisted via GlobalConfigKey.reminders.
    var reminderConfigValue: SubscriptionReminderConfig = .default
    /// Greeting example prompts + their tap counters (roadmap step 9).
    /// Super-admin knob, persisted via GlobalConfigKey.onboarding.
    var onboardingConfigValue: OnboardingConfig = .default
    /// Two-sided referral economics (roadmap step 10). Super-admin knob,
    /// persisted via GlobalConfigKey.referrals.
    var referralConfigValue: ReferralConfig = .default
    /// Referral attributions + per-inviter aggregates (roadmap step 10).
    /// Persisted as `bot_referral` / `bot_referral_tally` rows — the anti-fraud rules
    /// ("one attribution per person, once per pair") depend on it surviving
    /// restarts, so unlike the daily premium counter it is not in-memory.
    var referralLedgerValue: ReferralLedger = .empty
    /// Paid-traffic attributions + per-campaign aggregates behind `src_` deep
    /// links. Persisted as `bot_traffic_attribution` rows: an ad buy is judged
    /// weeks after the click, so these numbers have to outlive every redeploy in
    /// between or the campaign becomes unmeasurable.
    var trafficSourceLedgerValue: TrafficSourceLedger = .empty
    /// Pay-as-you-go wallets, keyed by `UserKey`.
    var userBalances: [UserKey: UserBalance] = [:]
    /// userID ↔ @username directory. Everything above that is "keyed by user"
    /// is keyed by `UserKey` (`#<userID>`), and this is what turns a typed
    /// `@name` into that key and back into a label for the interface. Persisted
    /// as `bot_user` rows.
    var userDirectoryValue: UserDirectory = .empty

    /// Conversion-funnel event counters (roadmap step 7), keyed by
    /// FunnelEvent.rawValue. Persisted via GlobalConfigKey.funnel so the numbers
    /// survive restarts/redeploys.
    var funnelCounters: [String: Int] = [:]
    /// The same events bucketed per day (roadmap step 7), so the page can show
    /// a period and not only an all-time total. Persisted via
    /// `bot_funnel_daily`, pruned to `FunnelDailyLog.windowDays`.
    var funnelDailyValue: FunnelDailyLog = .empty

    /// Provider spending ceilings (§4.1). Super-admin knob, persisted via
    /// GlobalConfigKey.spendPolicy; the day's running spend next to it is
    /// in-memory (see `DailySpendLedger`).
    var spendPolicyValue: SpendPolicy = .default
    var dailySpendValue: DailySpendLedger = DailySpendLedger()

    /// Built-in self-promo that fills the ad slot when no paid campaign runs
    /// (roadmap step 5). Super-admin knob, persisted via
    /// GlobalConfigKey.selfPromo.
    var selfPromoConfigValue: SelfPromoConfig = .default

    /// Reference modes: the settings bundles a user picks in one tap, and which
    /// of them the free tier may reach. Super-admin knob, persisted via
    /// GlobalConfigKey.modes.
    var modeConfigValue: ModePresetConfig = .default

    /// Daily free "taste" of premium for free-tier chats/users (roadmap step 6).
    /// Group chats share one counter (`c<chatID>`); private chats count per user
    /// (`u<userID>`). Persisted as `bot_premium_usage` rows — see
    /// `DailyPremiumUsage` for why this one is not in-memory.
    var premiumDailyUsage: [String: DailyPremiumUsage] = [:]

    /// When each group last got its welcome, and when each chat last showed the
    /// sponsor credit. Both are anti-noise timers whose worst case on restart is
    /// one extra line — in-memory by the same §17 rule as `_premiumDailyUsage`.
    var _groupGreetedAt: [Int: Date] = [:]
    var _sponsorCreditShownAt: [Int: Date] = [:]
    static let groupGreetingCooldown: TimeInterval = 10 * 60
    /// How often a sponsored group repeats "premium here was opened by @X".
    /// Under every single answer it turns into noise; once an hour it still
    /// reads as the sponsor's standing credit.
    static let sponsorCreditCooldown: TimeInterval = 60 * 60

    /// The one typed-value wait a chat can hold, whatever asked for it.
    /// See `PendingRequest` for why it is a single slot and not eight maps.
    var _pendingRequests: [ChatKey: PendingRequest] = [:]
    // Internal (not private): restored by ChatContextStore+Persistence.swift.
    var _starsPrice: Int? = nil
    /// Stars charged per $1 when buying credit packs. Telegram pays devs
    /// ~$0.013/⭐, so 77⭐/$ recovers the pack's face value; the 30% spend
    /// markup on top is the margin. Tunable live from the super-admin menu.
    var _starsPerUsd: Int = 77
    var _freeModelIDs: [String] = []
    var _openRouterFreeModelIDs: Set<String>? = nil
    var _openRouterModelPrices: [String: ModelPriceInfo] = [:]

    var _cryptoPriceUsdCents: Int? = nil
    // Internal (not private): restored by ChatContextStore+Persistence.swift.
    var _cardConfig: CardPaymentConfig = .empty
    var _cryptoAddresses: [CryptoChain: String] = [:]
    var _cryptoInvoices: [String: CryptoInvoice] = [:]
    var _cryptoSlotCounters: [CryptoAsset: Int] = [:]
    var _cryptoMatchMode: CryptoMatchMode = .amountDelta
    var _cryptoAddressPools: [CryptoChain: [String]] = [:]
    /// Explorer scan positions, `"<asset>:<address>"` → unix seconds.
    var _explorerCursors: [String: Int] = [:]

    /// Hosted checkout (§7 «Внешняя касса»): merchant credentials, prices and
    /// the rails offered. Persisted with the open orders next to it, because a
    /// callback lands in whichever process is alive by then.
    var _externalPaymentConfig: ExternalPaymentConfig = .default
    var _externalOrders: [String: ExternalPaymentOrder] = [:]

    var _simulatedRoles: [UserKey: SimulatedRole] = [:]

    init(
        ownerUsername: String,
        ownerUserID: Int? = nil,
        model: String,
        systemPrompt: String,
        formatOptions: String,
        companyChatId: Int,
        companyMembers: String,
        defaultHistoryLength: Int,
        defaultSuffix: Int?
    ) {
        // The directory is empty here, so the owner starts as a pending key and
        // is re-filed under `#<userID>` the first time they talk to the bot.
        //
        // Unless `ownerUserID` is configured, in which case root is that account
        // from the start. A @username is rented: release it and whoever
        // registers it next inherits the pending root record on their first
        // message. A userID cannot change hands, so pinning root to one closes
        // that door — and keeps the owner's own access from depending on a
        // handle they might one day drop.
        self.pinnedOwnerUserID = ownerUserID
        let owner = ownerUserID.map { UserKey.identified($0) }
            ?? UserKey.pending(ownerUsername)
            ?? UserKey.sanitizedPendingFallback(ownerUsername)
        self.superAdminKeys = [owner]
        self.configuredOwnerKey = owner
        self.formatOptions = formatOptions
        self.companyChatId = companyChatId
        self.companyMembers = companyMembers
        self.defaultSuffix = defaultSuffix
        self.initialDefaultModel = model
        self.initialDefaultRole = systemPrompt
        self.initialDefaultHistoryLength = defaultHistoryLength
        self.tenants = [
            owner: TenantState(
                ownerKey: owner,
                defaultModel: model,
                defaultRole: systemPrompt,
                defaultHistoryLength: defaultHistoryLength,
                modelPresets: [],
                tempPresets: [],
                historyLengthPresets: [],
                rolePresets: [],
                whitelistedUserIDs: [],
                adminKeys: [],
                licensedKeys: [],
                cumulativeUsage: .zero,
                createdAt: Date(),
                paidUntil: nil
            )
        ]
    }
}
