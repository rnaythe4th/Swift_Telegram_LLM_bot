import Foundation

enum SimulatedRole: String, Sendable, CaseIterable {
    case admin
    case regularUser = "user"
}

struct TenantState: Sendable {
    var ownerUsername: String
    var defaultModel: String
    var defaultRole: String
    var defaultHistoryLength: Int
    var modelPresets: [Preset]
    var tempPresets: [Preset]
    var historyLengthPresets: [Preset]
    var rolePresets: [Preset]
    var whitelistedUserIDs: Set<Int>
    var adminUsernames: Set<String>
    var licensedUsernames: Set<String>
    var cumulativeUsage: CumulativeUsage
    var createdAt: Date?
    /// Subscription end. nil = unlimited (root owner, manually added tenants).
    var paidUntil: Date?
    /// Lifecycle notices already delivered for the cycle ending at this date
    /// (roadmap step 8). A renewal moves `paidUntil`, which drops the set — so
    /// every subscription cycle gets its own reminder exactly once.
    var noticeCycleUntil: Date?
    var sentNotices: Set<String> = []
    /// Winback discount granted after expiry; consumed by the next purchase.
    var winbackDiscount: SubscriptionDiscount?
    /// Sponsor asked not to be reminded (toggle in their admin panel).
    var remindersOptOut: Bool = false

    var isActive: Bool {
        guard let paidUntil else { return true }
        return paidUntil > Date()
    }
}

/// Outcome of a paid activation — drives the confirmation message wording.
enum SubscriptionActivation: Sendable {
    case started(until: Date)
    case extended(until: Date)
    case alreadyUnlimited
}

struct TenantStatsRow: Sendable {
    let username: String
    let usage: CumulativeUsage
    let chatCount: Int
    let licensedUserCount: Int
    let isSuperAdmin: Bool
    let paidUntil: Date?
    let isActive: Bool
}

struct ChatContext: Sendable {
    enum PendingTurnState: Sendable {
        case pending
        case completed(String)
        case cancelled
    }

    struct PendingTurn: Sendable {
        let generationID: GenerationID
        let userMessage: ChatMessage
        var state: PendingTurnState
    }

    var role: String
    var history: [ChatMessage]
    var pendingTurns: [PendingTurn]
    var model: String
    // OpenRouter upstream provider pin for the current model (provider routing).
    var modelProviderRouting: String?
    var temp: Float
    var showStats: Bool
    var maxHistory: Int
    var showCost: Bool
    var showModel: Bool
    var provider: ServiceProvider
    var suffix: Int?
    var reasoningEffort: ReasoningEffort?
    var backupNotify: Bool
    var cumulativeUsage: CumulativeUsage
    var chatModelPresets: [Preset]
    var chatTempPresets: [Preset]
    var chatHistoryLengthPresets: [Preset]
    var chatRolePresets: [Preset]
    /// Bot replies in this chat since the last ad impression.
    var adReplyCounter: Int = 0
    var adLastShownAt: Date? = nil
    /// Funnel analytics: set once this chat produces its first LLM turn, so the
    /// `firstMessage` (activation) event is counted at most once per chat.
    var funnelFirstMessageCounted: Bool = false
}

struct GenerationSnapshot: Sendable {
    let provider: ServiceProvider
    let model: String
    let providerRouting: String?
    let temperature: Float
    let options: GenerationOptions
    let messages: [ChatMessage]
}

struct HelpData: Sendable {
    let model: String
    let modelProviderRouting: String?
    let role: String
    let temp: Float
    let maxHistory: Int
    let showTokens: Bool
    let showCost: Bool
    let showModel: Bool
    let defaultRole: String
    let provider: ServiceProvider
    let reasoningEffort: ReasoningEffort?
    let testModeSuffix: Int?
    let backupNotify: Bool
    let cumulativeUsage: CumulativeUsage
}

actor ChatContextStore {
    // Storage is `internal` (not private) so ChatContextStore+Persistence.swift
    // can export/restore rows; nothing outside the actor touches it directly.
    var contexts: [ChatKey: ChatContext] = [:]
    var tenants: [String: TenantState] = [:]
    var chatOwnership: [Int: String] = [:]
    var userTenantMap: [Int: String] = [:]

    var superAdminUsernames: Set<String>
    let rootSuperAdminUsername: String
    let defaultOwnerUsername: String
    var formatOptions: String
    let companyChatId: Int
    let companyMembers: String
    let defaultSuffix: Int?

    let initialDefaultModel: String
    let initialDefaultRole: String
    let initialDefaultHistoryLength: Int

    // MARK: - Dirty tracking (drained by PersistenceCoordinator)

    var dirtyContexts = Set<ChatKey>()
    var dirtyTenants = Set<String>()
    var deletedTenants = Set<String>()
    var dirtyOwnership = Set<Int>()
    var deletedOwnership = Set<Int>()
    var dirtyConfigs = Set<GlobalConfigKey>()
    /// Telegram Stars charge IDs already handled — makes payment processing
    /// idempotent across update redeliveries and restarts.
    var processedPaymentChargeIDs: [String] = []
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
    /// Persisted via GlobalConfigKey.referralLedger — the anti-fraud rules
    /// ("one attribution per person, once per pair") depend on it surviving
    /// restarts, so unlike the daily premium counter it is not in-memory.
    var referralLedgerValue: ReferralLedger = .empty
    /// Pay-as-you-go wallets, keyed by lowercased username.
    var userBalances: [String: UserBalance] = [:]

    /// Conversion-funnel event counters (roadmap step 7), keyed by
    /// FunnelEvent.rawValue. Persisted via GlobalConfigKey.funnel so the numbers
    /// survive restarts/redeploys.
    var funnelCounters: [String: Int] = [:]

    /// Daily free "taste" of premium for free-tier chats/users. In-memory only:
    /// per §17 CLAUDE.md this is the sanctioned simplification — resetting the
    /// counter on restart is non-critical, so it is neither dirty-tracked nor
    /// persisted. Group chats share one counter (`c<chatID>`); private chats
    /// count per user (`u<userID>`). Value = (UTC day number, units used).
    private var _premiumDailyUsage: [String: (day: Int, used: Int)] = [:]

    private var _pendingInputs: [ChatKey: PendingInput] = [:]
    // Internal (not private): restored by ChatContextStore+Persistence.swift.
    var _starsPrice: Int? = nil
    /// Stars charged per $1 when buying credit packs. Telegram pays devs
    /// ~$0.013/⭐, so 77⭐/$ recovers the pack's face value; the 30% spend
    /// markup on top is the margin. Tunable live from the super-admin menu.
    var _starsPerUsd: Int = 77
    private var _pendingStarsPriceInputs: [ChatKey: Int] = [:]
    private var _pendingStarsPerUsdInputs: [ChatKey: Int] = [:]
    private var _pendingFreeModelInputs: [ChatKey: Int] = [:]
    var _freeModelIDs: [String] = []
    private var _openRouterFreeModelIDs: Set<String>? = nil
    private var _openRouterModelPrices: [String: ModelPriceInfo] = [:]

    private var _cryptoPriceUsdCents: Int? = nil
    // Internal (not private): restored by ChatContextStore+Persistence.swift.
    var _cardConfig: CardPaymentConfig = .empty
    private var _cryptoAddresses: [CryptoChain: String] = [:]
    private var _cryptoInvoices: [String: CryptoInvoice] = [:]
    private var _cryptoSlotCounters: [CryptoAsset: Int] = [:]
    private var _cryptoMatchMode: CryptoMatchMode = .amountDelta
    private var _cryptoAddressPools: [CryptoChain: [String]] = [:]
    private var _pendingCryptoPriceInputs: [ChatKey: Int] = [:]
    private var _pendingCryptoAddressInputs: [ChatKey: (menuMessageID: Int, chain: CryptoChain)] = [:]
    private var _pendingCryptoPoolAddInputs: [ChatKey: (menuMessageID: Int, chain: CryptoChain)] = [:]

    private var _simulatedRoles: [String: SimulatedRole] = [:]

    private var _pendingAdminInputs: [ChatKey: AdminPendingInput] = [:]

    init(
        ownerUsername: String,
        model: String,
        systemPrompt: String,
        formatOptions: String,
        companyChatId: Int,
        companyMembers: String,
        defaultHistoryLength: Int,
        defaultSuffix: Int?
    ) {
        let owner = ownerUsername.lowercased()
        self.superAdminUsernames = [owner]
        self.rootSuperAdminUsername = owner
        self.defaultOwnerUsername = owner
        self.formatOptions = formatOptions
        self.companyChatId = companyChatId
        self.companyMembers = companyMembers
        self.defaultSuffix = defaultSuffix
        self.initialDefaultModel = model
        self.initialDefaultRole = systemPrompt
        self.initialDefaultHistoryLength = defaultHistoryLength
        self.tenants = [
            owner: TenantState(
                ownerUsername: owner,
                defaultModel: model,
                defaultRole: systemPrompt,
                defaultHistoryLength: defaultHistoryLength,
                modelPresets: [],
                tempPresets: [],
                historyLengthPresets: [],
                rolePresets: [],
                whitelistedUserIDs: [],
                adminUsernames: [],
                licensedUsernames: [],
                cumulativeUsage: .zero,
                createdAt: Date(),
                paidUntil: nil
            )
        ]
    }

    // MARK: - Tenant routing helpers

    private func tenantState(for chatID: Int) -> TenantState {
        let owner = chatOwnership[chatID] ?? defaultOwnerUsername
        return tenants[owner] ?? tenants[defaultOwnerUsername]!
    }

    private func mutateTenant(for chatID: Int, _ block: (inout TenantState) -> Void) {
        let owner = chatOwnership[chatID] ?? defaultOwnerUsername
        guard var tenant = tenants[owner] else { return }
        block(&tenant)
        tenants[owner] = tenant
        dirtyTenants.insert(owner)
    }

    private func mutateTenantByOwner(_ ownerUsername: String, _ block: (inout TenantState) -> Void) {
        let u = ownerUsername.lowercased()
        guard var tenant = tenants[u] else { return }
        block(&tenant)
        tenants[u] = tenant
        dirtyTenants.insert(u)
    }

    // MARK: - Tenant management

    /// Registers a tenant without a subscription term (unlimited) — the
    /// super-admin manual path. Paid activations go through
    /// `activatePaidSubscription`.
    func registerTenant(username: String) {
        let u = username.lowercased()
        guard tenants[u] == nil else { return }
        let defaults = tenants[defaultOwnerUsername]
        tenants[u] = TenantState(
            ownerUsername: u,
            defaultModel: defaults?.defaultModel ?? initialDefaultModel,
            defaultRole: defaults?.defaultRole ?? initialDefaultRole,
            defaultHistoryLength: defaults?.defaultHistoryLength ?? initialDefaultHistoryLength,
            modelPresets: [],
            tempPresets: [],
            historyLengthPresets: [],
            rolePresets: [],
            whitelistedUserIDs: [],
            adminUsernames: [],
            licensedUsernames: [],
            cumulativeUsage: .zero,
            createdAt: Date(),
            paidUntil: nil
        )
        dirtyTenants.insert(u)
        deletedTenants.remove(u)
    }

    // MARK: - Subscription

    static let subscriptionDays = 30

    /// Payment path: creates the tenant if needed and extends the subscription
    /// by `days` from max(now, current end). An unlimited tenant stays
    /// unlimited — paying never shortens access.
    func activatePaidSubscription(username: String, days: Int = ChatContextStore.subscriptionDays) -> SubscriptionActivation {
        let u = username.lowercased()
        let isNew = tenants[u] == nil
        if isNew {
            registerTenant(username: u)
        }
        guard var tenant = tenants[u] else { return .alreadyUnlimited }

        if !isNew, tenant.paidUntil == nil {
            return .alreadyUnlimited
        }

        let base = max(Date(), tenant.paidUntil ?? Date())
        let until = base.addingTimeInterval(TimeInterval(days) * 86_400)
        tenant.paidUntil = until
        tenants[u] = tenant
        dirtyTenants.insert(u)
        return isNew ? .started(until: until) : .extended(until: until)
    }

    /// True when the owner exists and the subscription hasn't expired.
    /// Expired tenants keep their admin panel (to renew) but lose paid models.
    func tenantIsActive(_ ownerUsername: String) -> Bool {
        tenants[ownerUsername.lowercased()]?.isActive ?? false
    }

    func tenantSubscription(ownerUsername: String) -> (exists: Bool, paidUntil: Date?, isActive: Bool) {
        guard let tenant = tenants[ownerUsername.lowercased()] else {
            return (false, nil, false)
        }
        return (true, tenant.paidUntil, tenant.isActive)
    }

    /// Super-admin: extend by N days (from max(now, current end)).
    @discardableResult
    func extendTenantSubscription(username: String, days: Int) -> Date? {
        let u = username.lowercased()
        guard var tenant = tenants[u] else { return nil }
        let base = max(Date(), tenant.paidUntil ?? Date())
        let until = base.addingTimeInterval(TimeInterval(days) * 86_400)
        tenant.paidUntil = until
        tenants[u] = tenant
        dirtyTenants.insert(u)
        return until
    }

    /// Super-admin: make the subscription unlimited.
    @discardableResult
    func setTenantUnlimited(username: String) -> Bool {
        let u = username.lowercased()
        guard var tenant = tenants[u] else { return false }
        tenant.paidUntil = nil
        tenants[u] = tenant
        dirtyTenants.insert(u)
        return true
    }

    /// Super-admin: expire the subscription immediately.
    @discardableResult
    func expireTenantSubscription(username: String) -> Bool {
        let u = username.lowercased()
        guard u != defaultOwnerUsername, var tenant = tenants[u] else { return false }
        tenant.paidUntil = Date()
        tenants[u] = tenant
        dirtyTenants.insert(u)
        return true
    }

    // MARK: - Subscription lifecycle: reminders & winback (roadmap step 8)

    /// An invoice opened just before a winback offer ran out is still honored
    /// at checkout — the user must never be charged more than they were shown.
    static let checkoutDiscountGrace: TimeInterval = 3600

    func reminderConfig() -> SubscriptionReminderConfig { reminderConfigValue }

    func setReminderConfig(_ config: SubscriptionReminderConfig) {
        reminderConfigValue = config.normalized
        dirtyConfigs.insert(.reminders)
    }

    func remindersOptOut(username: String?) -> Bool {
        guard let u = username?.lowercased() else { return false }
        return tenants[u]?.remindersOptOut ?? false
    }

    /// Per-sponsor opt-out (toggle in their own admin panel).
    @discardableResult
    func setRemindersOptOut(username: String, optOut: Bool) -> Bool {
        let u = username.lowercased()
        guard tenants[u] != nil else { return false }
        mutateTenantByOwner(u) { $0.remindersOptOut = optOut }
        return true
    }

    /// Notices due right now. Pure decision: the caller sends them and reports
    /// back through `markNoticeSent`, so a failed send is retried next sweep
    /// (bounded by each notice's own window) instead of being lost.
    func dueSubscriptionNotices(now: Date = Date()) -> [SubscriptionNoticeTarget] {
        let config = reminderConfigValue
        guard config.enabled else { return [] }
        var targets: [SubscriptionNoticeTarget] = []
        for (owner, tenant) in tenants {
            guard let paidUntil = tenant.paidUntil, !tenant.remindersOptOut else { continue }
            // Flags belong to one cycle; a renewal invalidates them.
            let sent = tenant.noticeCycleUntil == paidUntil ? tenant.sentNotices : []
            guard let notice = config.dueNotice(paidUntil: paidUntil, alreadySent: sent, now: now) else {
                continue
            }
            targets.append(SubscriptionNoticeTarget(
                username: owner,
                notice: notice,
                paidUntil: paidUntil,
                privateChatID: privateChatID(forUsername: owner),
                groupChatIDs: ownedGroupChatIDs(owner: owner)
            ))
        }
        return targets.sorted { $0.username < $1.username }
    }

    /// Records a delivered notice against the cycle it was computed for. A
    /// renewal in between changes `paidUntil` → the mark is dropped, so the new
    /// cycle keeps its own reminder.
    @discardableResult
    func markNoticeSent(username: String, notice: SubscriptionNotice, paidUntil: Date) -> Bool {
        let u = username.lowercased()
        guard let tenant = tenants[u], tenant.paidUntil == paidUntil else { return false }
        mutateTenantByOwner(u) { state in
            if state.noticeCycleUntil != paidUntil {
                state.noticeCycleUntil = paidUntil
                state.sentNotices = []
            }
            state.sentNotices.insert(notice.key)
        }
        return true
    }

    /// Attaches a winback discount; the next subscription purchase by this user
    /// is priced with it on every payment method.
    @discardableResult
    func grantWinbackDiscount(username: String, percent: Int, hours: Int, now: Date = Date()) -> SubscriptionDiscount? {
        let u = username.lowercased()
        guard tenants[u] != nil, percent > 0, hours > 0 else { return nil }
        let discount = SubscriptionDiscount(
            percent: percent,
            expiresAt: now.addingTimeInterval(Double(hours) * 3600)
        )
        mutateTenantByOwner(u) { $0.winbackDiscount = discount }
        return discount
    }

    /// The discount honored right now, if any.
    func subscriptionDiscount(username: String?, grace: TimeInterval = 0, now: Date = Date()) -> SubscriptionDiscount? {
        guard let u = username?.lowercased(), let discount = tenants[u]?.winbackDiscount else { return nil }
        return discount.isActive(now: now, grace: grace) ? discount : nil
    }

    /// Clears the offer after a purchase (one-shot). Returns it when it was
    /// still valid, so the caller can count the winback conversion.
    @discardableResult
    func consumeWinbackDiscount(username: String) -> SubscriptionDiscount? {
        let u = username.lowercased()
        guard let discount = tenants[u]?.winbackDiscount else { return nil }
        mutateTenantByOwner(u) { $0.winbackDiscount = nil }
        return discount.isActive(grace: Self.checkoutDiscountGrace) ? discount : nil
    }

    /// Super-admin escape hatch: drops every live offer at once (e.g. after a
    /// misconfigured discount went out).
    @discardableResult
    func clearAllWinbackDiscounts() -> Int {
        var cleared = 0
        for (owner, tenant) in tenants where tenant.winbackDiscount != nil {
            mutateTenantByOwner(owner) { $0.winbackDiscount = nil }
            cleared += 1
        }
        return cleared
    }

    /// Subscription prices for this user with any active winback discount
    /// applied. Single source of truth for menus, `/buy`, crypto invoices and
    /// pre-checkout validation.
    func subscriptionPricing(username: String?, grace: TimeInterval = 0, now: Date = Date()) -> SubscriptionPricing {
        let cardPrice = _cardConfig.isEnabled ? _cardConfig.priceMinorUnits : nil
        var pricing = SubscriptionPricing(
            discount: nil,
            starsFull: _starsPrice,
            stars: _starsPrice,
            cryptoCentsFull: _cryptoPriceUsdCents,
            cryptoCents: _cryptoPriceUsdCents,
            cardMinorUnitsFull: cardPrice,
            cardMinorUnits: cardPrice,
            cardLabelFull: cardPrice.map { _cardConfig.currency.format(minorUnits: $0) },
            cardLabel: cardPrice.map { _cardConfig.currency.format(minorUnits: $0) }
        )
        guard let discount = subscriptionDiscount(username: username, grace: grace, now: now) else {
            return pricing
        }
        pricing.discount = discount
        pricing.stars = _starsPrice.map { discount.apply(to: $0) }
        pricing.cryptoCents = _cryptoPriceUsdCents.map { discount.apply(to: $0) }
        // Card: never dip below the provider minimum — Telegram rejects it.
        pricing.cardMinorUnits = cardPrice.map { max(_cardConfig.currency.minMinorUnits, discount.apply(to: $0)) }
        pricing.cardLabel = pricing.cardMinorUnits.map { _cardConfig.currency.format(minorUnits: $0) }
        return pricing
    }

    /// The sponsor's DM with the bot, if they ever wrote to it (Telegram
    /// forbids bot-initiated conversations, so this is the only way to reach
    /// them personally).
    func privateChatID(forUsername username: String) -> Int? {
        let u = username.lowercased()
        for (chatID, meta) in chatMetaByID
        where chatID > 0 && meta.type == "private" && meta.username?.lowercased() == u {
            return chatID
        }
        return nil
    }

    /// Group chats currently covered by this sponsor's licence.
    func ownedGroupChatIDs(owner: String) -> [Int] {
        let u = owner.lowercased()
        return chatOwnership.filter { $0.key < 0 && $0.value == u }.map(\.key).sorted()
    }

    /// Monitoring snapshot for the super-admin reminders page: who is about to
    /// lapse, who just did, who carries a live offer, who can't be reached.
    func subscriptionLifecycleStats(now: Date = Date()) -> SubscriptionLifecycleStats {
        let config = reminderConfigValue
        let lead = Double(max(config.daysBeforeExpiry, 1)) * 86_400
        let winbackHorizon = Double((config.winbackDays.max() ?? 7)) * 86_400 + config.winbackCatchUpWindow
        var stats = SubscriptionLifecycleStats()
        for (owner, tenant) in tenants {
            guard let paidUntil = tenant.paidUntil else { continue }
            stats.sponsors += 1
            let reachable = privateChatID(forUsername: owner) != nil || !ownedGroupChatIDs(owner: owner).isEmpty
            if !reachable { stats.unreachable += 1 }
            if tenant.remindersOptOut { stats.optedOut += 1 }
            let row = SubscriptionLifecycleStats.Row(
                username: owner,
                paidUntil: paidUntil,
                reachable: reachable,
                optedOut: tenant.remindersOptOut
            )
            if paidUntil > now {
                if paidUntil.timeIntervalSince(now) <= lead { stats.expiringSoon.append(row) }
            } else if now.timeIntervalSince(paidUntil) <= winbackHorizon {
                stats.recentlyExpired.append(row)
            }
            if let discount = tenant.winbackDiscount, discount.isActive(now: now) {
                stats.activeDiscounts.append((username: owner, discount: discount))
            }
        }
        stats.expiringSoon.sort { $0.paidUntil < $1.paidUntil }
        stats.recentlyExpired.sort { $0.paidUntil > $1.paidUntil }
        stats.activeDiscounts.sort { $0.username < $1.username }
        return stats
    }

    @discardableResult
    func removeTenant(username: String) -> Bool {
        let u = username.lowercased()
        guard u != defaultOwnerUsername, tenants[u] != nil else { return false }
        tenants.removeValue(forKey: u)
        let ownedChats = chatOwnership.filter { $0.value == u }.map(\.key)
        for chatID in ownedChats {
            chatOwnership.removeValue(forKey: chatID)
            dirtyOwnership.remove(chatID)
            deletedOwnership.insert(chatID)
        }
        userTenantMap = userTenantMap.filter { $0.value != u }
        let hadInvites = inviteRecords.contains { $0.value.ownerUsername == u }
        if hadInvites {
            inviteRecords = inviteRecords.filter { $0.value.ownerUsername != u }
            dirtyConfigs.insert(.invites)
        }
        dirtyTenants.remove(u)
        deletedTenants.insert(u)
        return true
    }

    func listTenants() -> [String] {
        Array(tenants.keys).sorted()
    }

    func isTenant(username: String) -> Bool {
        tenants[username.lowercased()] != nil
    }

    func chatOwner(chatID: Int) -> String? {
        chatOwnership[chatID]
    }

    func effectiveOwnerUsername(chatID: Int) -> String {
        chatOwnership[chatID] ?? defaultOwnerUsername
    }

    @discardableResult
    func assignChat(chatID: Int, to ownerUsername: String) -> Bool {
        let u = ownerUsername.lowercased()
        guard tenants[u] != nil else { return false }
        chatOwnership[chatID] = u
        dirtyOwnership.insert(chatID)
        deletedOwnership.remove(chatID)
        return true
    }

    @discardableResult
    func unassignChat(chatID: Int) -> String? {
        let removed = chatOwnership.removeValue(forKey: chatID)
        if removed != nil {
            dirtyOwnership.remove(chatID)
            deletedOwnership.insert(chatID)
        }
        return removed
    }

    func chatsOwnedBy(_ ownerUsername: String) -> [Int] {
        let u = ownerUsername.lowercased()
        return chatOwnership.compactMap { $0.value == u ? $0.key : nil }
    }

    func autoAssignIfNeeded(chatID: Int, senderUsername: String?, senderUserID: Int?) {
        guard chatOwnership[chatID] == nil else { return }
        let lowered = senderUsername?.lowercased()
        // A super-admin simulating a regular user must be able to keep a chat
        // unowned (after /tenant release) to test ads and balance billing —
        // otherwise their own tenant would instantly re-claim it here.
        if let u = lowered, superAdminUsernames.contains(u), _simulatedRoles[u] != nil {
            return
        }
        if let username = lowered, tenants[username] != nil {
            chatOwnership[chatID] = username
        } else if let userID = senderUserID, let owner = userTenantMap[userID] {
            chatOwnership[chatID] = owner
        } else {
            return
        }
        dirtyOwnership.insert(chatID)
        deletedOwnership.remove(chatID)
    }

    // MARK: - Auth

    func isSuperAdmin(username: String?) -> Bool {
        guard let u = username?.lowercased() else { return false }
        guard superAdminUsernames.contains(u) else { return false }
        return _simulatedRoles[u] == nil
    }

    /// Raw super-admin check that ignores any active simulation. Use only for
    /// gating commands that must remain reachable while a simulation is active
    /// (e.g. `/simulate` itself).
    func isActuallySuperAdmin(username: String?) -> Bool {
        guard let u = username?.lowercased() else { return false }
        return superAdminUsernames.contains(u)
    }

    /// True only for the immutable bootstrap super-admin (default @maythe4th).
    /// Only this user may add or remove other super-admins.
    func isRootSuperAdmin(username: String?) -> Bool {
        guard let u = username?.lowercased() else { return false }
        return u == rootSuperAdminUsername
    }

    func listSuperAdmins() -> [String] {
        superAdminUsernames.sorted()
    }

    @discardableResult
    func addSuperAdmin(target: String) -> Bool {
        let u = target.lowercased()
        guard !u.isEmpty else { return false }
        let inserted = superAdminUsernames.insert(u).inserted
        if inserted { dirtyConfigs.insert(.superAdmins) }
        return inserted
    }

    @discardableResult
    func removeSuperAdmin(target: String) -> Bool {
        let u = target.lowercased()
        guard u != rootSuperAdminUsername else { return false }
        let removed = superAdminUsernames.remove(u) != nil
        if removed { dirtyConfigs.insert(.superAdmins) }
        return removed
    }

    func simulatedRole(username: String?) -> SimulatedRole? {
        guard let u = username?.lowercased() else { return nil }
        guard superAdminUsernames.contains(u) else { return nil }
        return _simulatedRoles[u]
    }

    @discardableResult
    func setSimulatedRole(username: String, role: SimulatedRole?) -> Bool {
        let u = username.lowercased()
        guard superAdminUsernames.contains(u) else { return false }
        if let role {
            _simulatedRoles[u] = role
        } else {
            _simulatedRoles.removeValue(forKey: u)
        }
        return true
    }

    func isTenantOwner(username: String?, chatID: Int) -> Bool {
        guard let u = username?.lowercased() else { return false }
        if superAdminUsernames.contains(u) {
            if _simulatedRoles[u] != nil { return false }
            return true
        }
        return effectiveOwnerUsername(chatID: chatID) == u
    }

    func isAdmin(username: String?, chatID: Int) -> Bool {
        guard let u = username?.lowercased() else { return false }
        if let sim = _simulatedRoles[u], superAdminUsernames.contains(u) {
            return sim == .admin
        }
        if superAdminUsernames.contains(u) { return true }
        let owner = effectiveOwnerUsername(chatID: chatID)
        if u == owner { return true }
        return tenants[owner]?.adminUsernames.contains(u) ?? false
    }

    func isWhitelisted(userID: Int, chatID: Int) -> Bool {
        tenantState(for: chatID).whitelistedUserIDs.contains(userID)
    }

    func addToWhitelist(userID: Int, chatID: Int) {
        mutateTenant(for: chatID) { $0.whitelistedUserIDs.insert(userID) }
        let owner = effectiveOwnerUsername(chatID: chatID)
        userTenantMap[userID] = owner
    }

    func removeFromWhitelist(userID: Int, chatID: Int) {
        mutateTenant(for: chatID) { $0.whitelistedUserIDs.remove(userID) }
        userTenantMap.removeValue(forKey: userID)
    }

    func listWhitelisted(chatID: Int) -> Set<Int> {
        tenantState(for: chatID).whitelistedUserIDs
    }

    func addAdmin(username: String, chatID: Int) {
        let u = username.lowercased()
        mutateTenant(for: chatID) { $0.adminUsernames.insert(u) }
    }

    func removeAdmin(username: String, chatID: Int) {
        let u = username.lowercased()
        mutateTenant(for: chatID) { $0.adminUsernames.remove(u) }
    }

    func listAdmins(chatID: Int) -> Set<String> {
        tenantState(for: chatID).adminUsernames
    }

    // MARK: - Defaults

    func defaultRole(chatID: Int) -> String {
        let baseRole = tenantState(for: chatID).defaultRole
        return roleWithCompanyMembers(chatID: chatID, role: baseRole + formatOptions)
    }

    func getDefaults(chatID: Int) -> (model: String, role: String, historyLength: Int) {
        let t = tenantState(for: chatID)
        return (t.defaultModel, t.defaultRole, t.defaultHistoryLength)
    }

    @discardableResult
    func setDefaultModel(_ model: String, chatID: Int) -> String {
        mutateTenant(for: chatID) { $0.defaultModel = model }
        return model
    }

    @discardableResult
    func setDefaultRole(_ role: String, chatID: Int) -> String {
        mutateTenant(for: chatID) { $0.defaultRole = role }
        return role
    }

    @discardableResult
    func setDefaultHistoryLength(_ length: Int, chatID: Int) -> Int {
        let clamped = max(1, length)
        mutateTenant(for: chatID) { $0.defaultHistoryLength = clamped }
        return clamped
    }

    // MARK: - Presets (tenant-scoped)

    func modelPresets(chatID: Int) -> [Preset] { tenantState(for: chatID).modelPresets }
    func tempPresets(chatID: Int) -> [Preset] { tenantState(for: chatID).tempPresets }
    func historyLengthPresets(chatID: Int) -> [Preset] { tenantState(for: chatID).historyLengthPresets }
    func rolePresets(chatID: Int) -> [Preset] { tenantState(for: chatID).rolePresets }

    func presets(for category: PresetCategory, chatID: Int) -> [Preset] {
        switch category {
        case .model: return modelPresets(chatID: chatID)
        case .temp: return tempPresets(chatID: chatID)
        case .history: return historyLengthPresets(chatID: chatID)
        case .role: return rolePresets(chatID: chatID)
        }
    }

    func addPreset(category: PresetCategory, display: String, value: String, provider: String? = nil, chatID: Int) -> Preset {
        let preset = Preset(display: display, value: value, provider: provider)
        mutateTenant(for: chatID) { tenant in
            switch category {
            case .model: tenant.modelPresets.append(preset)
            case .temp: tenant.tempPresets.append(preset)
            case .history: tenant.historyLengthPresets.append(preset)
            case .role: tenant.rolePresets.append(preset)
            }
        }
        return preset
    }

    func removePresetByIndex(category: PresetCategory, index: Int, chatID: Int) -> Bool {
        var success = false
        mutateTenant(for: chatID) { tenant in
            switch category {
            case .model:
                guard index >= 0, index < tenant.modelPresets.count else { return }
                tenant.modelPresets.remove(at: index)
                success = true
            case .temp:
                guard index >= 0, index < tenant.tempPresets.count else { return }
                tenant.tempPresets.remove(at: index)
                success = true
            case .history:
                guard index >= 0, index < tenant.historyLengthPresets.count else { return }
                tenant.historyLengthPresets.remove(at: index)
                success = true
            case .role:
                guard index >= 0, index < tenant.rolePresets.count else { return }
                tenant.rolePresets.remove(at: index)
                success = true
            }
        }
        return success
    }

    func editPreset(category: PresetCategory, index: Int, display: String, value: String, provider: String? = nil, chatID: Int) -> Bool {
        let preset = Preset(display: display, value: value, provider: provider)
        var success = false
        mutateTenant(for: chatID) { tenant in
            switch category {
            case .model:
                guard index >= 0, index < tenant.modelPresets.count else { return }
                tenant.modelPresets[index] = preset
                success = true
            case .temp:
                guard index >= 0, index < tenant.tempPresets.count else { return }
                tenant.tempPresets[index] = preset
                success = true
            case .history:
                guard index >= 0, index < tenant.historyLengthPresets.count else { return }
                tenant.historyLengthPresets[index] = preset
                success = true
            case .role:
                guard index >= 0, index < tenant.rolePresets.count else { return }
                tenant.rolePresets[index] = preset
                success = true
            }
        }
        return success
    }

    func addModelPreset(display: String, value: String, provider: String? = nil, chatID: Int) -> Preset {
        addPreset(category: .model, display: display, value: value, provider: provider, chatID: chatID)
    }

    func removeModelPreset(value: String, chatID: Int) -> Bool {
        var removed = false
        mutateTenant(for: chatID) { tenant in
            let before = tenant.modelPresets.count
            tenant.modelPresets.removeAll { $0.value == value }
            removed = tenant.modelPresets.count < before
        }
        return removed
    }

    func addTempPreset(display: String, value: String, chatID: Int) -> Preset {
        addPreset(category: .temp, display: display, value: value, chatID: chatID)
    }

    func removeTempPreset(value: String, chatID: Int) -> Bool {
        var removed = false
        mutateTenant(for: chatID) { tenant in
            let before = tenant.tempPresets.count
            tenant.tempPresets.removeAll { $0.value == value }
            removed = tenant.tempPresets.count < before
        }
        return removed
    }

    func addHistoryLengthPreset(display: String, value: String, chatID: Int) -> Preset {
        addPreset(category: .history, display: display, value: value, chatID: chatID)
    }

    func removeHistoryLengthPreset(value: String, chatID: Int) -> Bool {
        var removed = false
        mutateTenant(for: chatID) { tenant in
            let before = tenant.historyLengthPresets.count
            tenant.historyLengthPresets.removeAll { $0.value == value }
            removed = tenant.historyLengthPresets.count < before
        }
        return removed
    }

    func addRolePreset(display: String, value: String, chatID: Int) -> Preset {
        addPreset(category: .role, display: display, value: value, chatID: chatID)
    }

    func removeRolePreset(value: String, chatID: Int) -> Bool {
        var removed = false
        mutateTenant(for: chatID) { tenant in
            let before = tenant.rolePresets.count
            tenant.rolePresets.removeAll { $0.value == value }
            removed = tenant.rolePresets.count < before
        }
        return removed
    }

    // MARK: - Initial preset seeding (called at boot)

    func setModelPresets(_ presets: [Preset]) {
        mutateTenantByOwner(defaultOwnerUsername) { $0.modelPresets = presets }
    }

    func setTempPresets(_ presets: [Preset]) {
        mutateTenantByOwner(defaultOwnerUsername) { $0.tempPresets = presets }
    }

    func setHistoryLengthPresets(_ presets: [Preset]) {
        mutateTenantByOwner(defaultOwnerUsername) { $0.historyLengthPresets = presets }
    }

    func setRolePresets(_ presets: [Preset]) {
        mutateTenantByOwner(defaultOwnerUsername) { $0.rolePresets = presets }
    }

    // MARK: - Chat context helpers

    private func roleWithCompanyMembers(chatID: Int, role: String) -> String {
        chatID == companyChatId ? role + companyMembers : role
    }

    private func ensure(chatKey: ChatKey) -> ChatContext {
        if let context = contexts[chatKey] {
            return context
        }
        let tenant = tenantState(for: chatKey.chatID)
        let role = roleWithCompanyMembers(chatID: chatKey.chatID, role: tenant.defaultRole + formatOptions)
        let context = ChatContext(
            role: role,
            history: [.init(role: "system", content: role)],
            pendingTurns: [],
            model: tenant.defaultModel,
            modelProviderRouting: nil,
            temp: 1.5,
            showStats: false,
            maxHistory: tenant.defaultHistoryLength,
            showCost: true,
            showModel: true,
            provider: .openrouter,
            suffix: defaultSuffix,
            reasoningEffort: nil,
            backupNotify: false,
            cumulativeUsage: .zero,
            chatModelPresets: [],
            chatTempPresets: [],
            chatHistoryLengthPresets: [],
            chatRolePresets: []
        )
        contexts[chatKey] = context
        dirtyContexts.insert(chatKey)
        return context
    }

    private func mutate(chatKey: ChatKey, _ block: (inout ChatContext) -> Void) {
        var context = ensure(chatKey: chatKey)
        block(&context)
        contexts[chatKey] = context
        dirtyContexts.insert(chatKey)
    }

    private func trimHistory(_ history: [ChatMessage], limit: Int) -> [ChatMessage] {
        guard let first = history.first else { return history }
        let safeLimit = max(1, limit)
        let tail = Array(history.dropFirst())
        let clipped = tail.suffix(safeLimit)
        return [first] + clipped
    }

    private func visibleHistory(for context: ChatContext) -> [ChatMessage] {
        let pendingUserMessages = context.pendingTurns.map(\.userMessage)
        return trimHistory(context.history + pendingUserMessages, limit: context.maxHistory)
    }

    private func flushResolvedTurns(_ context: inout ChatContext) {
        while let first = context.pendingTurns.first {
            switch first.state {
            case .pending:
                context.history = trimHistory(context.history, limit: context.maxHistory)
                return
            case .completed(let assistantContent):
                context.history.append(first.userMessage)
                context.history.append(.init(role: "assistant", content: assistantContent))
                context.pendingTurns.removeFirst()
            case .cancelled:
                context.pendingTurns.removeFirst()
            }
        }
        context.history = trimHistory(context.history, limit: context.maxHistory)
    }

    // MARK: - Help

    func fetchHelp(chatKey: ChatKey) -> HelpData {
        makeHelpData(ensure(chatKey: chatKey), chatKey: chatKey)
    }

    /// Read-only variant for inspection: never creates a context (and so never
    /// marks anything dirty) for chats the bot merely looks at.
    func peekHelp(chatKey: ChatKey) -> HelpData? {
        contexts[chatKey].map { makeHelpData($0, chatKey: chatKey) }
    }

    /// Thread keys with an existing context for the chat, main thread first.
    func existingContextKeys(chatID: Int) -> [ChatKey] {
        contexts.keys
            .filter { $0.chatID == chatID }
            .sorted { $0.threadID < $1.threadID }
    }

    private func makeHelpData(_ context: ChatContext, chatKey: ChatKey) -> HelpData {
        .init(
            model: context.model,
            modelProviderRouting: context.modelProviderRouting,
            role: displayRole(context.role, chatID: chatKey.chatID),
            temp: context.temp,
            maxHistory: context.maxHistory,
            showTokens: context.showStats,
            showCost: context.showCost,
            showModel: context.showModel,
            defaultRole: displayRole(defaultRole(chatID: chatKey.chatID), chatID: chatKey.chatID),
            provider: context.provider,
            reasoningEffort: context.reasoningEffort,
            testModeSuffix: context.suffix,
            backupNotify: context.backupNotify,
            cumulativeUsage: context.cumulativeUsage
        )
    }

    private func displayRole(_ role: String, chatID: Int) -> String {
        var s = role
        if !companyMembers.isEmpty, chatID == companyChatId, s.hasSuffix(companyMembers) {
            s = String(s.dropLast(companyMembers.count))
        }
        if s.hasSuffix(formatOptions) {
            s = String(s.dropLast(formatOptions.count))
        }
        return s
    }

    // MARK: - Chat context mutations

    func suffix(chatKey: ChatKey) -> Int? {
        ensure(chatKey: chatKey).suffix
    }

    func toggleTestMode(chatKey: ChatKey) -> Int? {
        let current = ensure(chatKey: chatKey).suffix
        if current == nil {
            let newSuffix = Int.random(in: 1...10)
            mutate(chatKey: chatKey) { $0.suffix = newSuffix }
            return newSuffix
        }
        mutate(chatKey: chatKey) { $0.suffix = nil }
        return nil
    }

    func toggleReasoning(chatKey: ChatKey) -> ReasoningEffort? {
        let current = ensure(chatKey: chatKey).reasoningEffort
        let next: ReasoningEffort?
        switch current {
        case nil:       next = .high
        case .high:     next = .medium
        case .medium:   next = .low
        case .low:      next = nil
        }
        mutate(chatKey: chatKey) { $0.reasoningEffort = next }
        return next
    }

    func setReasoningEffort(chatKey: ChatKey, effort: ReasoningEffort?) {
        mutate(chatKey: chatKey) { $0.reasoningEffort = effort }
    }

    func reasoningEnabled(chatKey: ChatKey) -> Bool {
        ensure(chatKey: chatKey).reasoningEffort != nil
    }

    func reasoningEffort(chatKey: ChatKey) -> ReasoningEffort? {
        ensure(chatKey: chatKey).reasoningEffort
    }

    func setMaxHistory(chatKey: ChatKey, newMax: Int) {
        mutate(chatKey: chatKey) { context in
            context.maxHistory = max(1, newMax)
            context.history = trimHistory(context.history, limit: context.maxHistory)
        }
    }

    func setRoleAndResetHistory(chatKey: ChatKey, role: String) -> String {
        let effectiveRole = roleWithCompanyMembers(chatID: chatKey.chatID, role: role)
        mutate(chatKey: chatKey) { context in
            context.role = effectiveRole
            context.history = [.init(role: "system", content: effectiveRole)]
            context.pendingTurns = []
        }
        return effectiveRole
    }

    func clearHistory(chatKey: ChatKey) {
        mutate(chatKey: chatKey) { context in
            context.history = [.init(role: "system", content: context.role)]
            context.pendingTurns = []
        }
    }

    func setTemperature(chatKey: ChatKey, value: Float) {
        mutate(chatKey: chatKey) { $0.temp = value }
    }

    func temperature(chatKey: ChatKey) -> Float {
        ensure(chatKey: chatKey).temp
    }

    func setModelAndResetHistory(chatKey: ChatKey, newModel: String, providerRouting: String? = nil) -> (old: String, new: String) {
        let old = ensure(chatKey: chatKey).model
        mutate(chatKey: chatKey) { context in
            context.model = newModel
            context.modelProviderRouting = providerRouting
            context.history = [.init(role: "system", content: context.role)]
            context.pendingTurns = []
        }
        return (old, newModel)
    }

    func toggleShowStats(chatKey: ChatKey) -> Bool {
        mutate(chatKey: chatKey) { $0.showStats.toggle() }
        return ensure(chatKey: chatKey).showStats
    }

    func toggleShowCost(chatKey: ChatKey) -> Bool {
        mutate(chatKey: chatKey) { $0.showCost.toggle() }
        return ensure(chatKey: chatKey).showCost
    }

    func toggleShowModel(chatKey: ChatKey) -> Bool {
        mutate(chatKey: chatKey) { $0.showModel.toggle() }
        return ensure(chatKey: chatKey).showModel
    }

    func toggleBackupNotify(chatKey: ChatKey) -> Bool {
        mutate(chatKey: chatKey) { $0.backupNotify.toggle() }
        return ensure(chatKey: chatKey).backupNotify
    }

    func changeProvider(chatKey: ChatKey, newProvider: ServiceProvider) -> ServiceProvider {
        let oldProvider = ensure(chatKey: chatKey).provider
        mutate(chatKey: chatKey) { $0.provider = newProvider }
        return oldProvider
    }

    func provider(chatKey: ChatKey) -> ServiceProvider {
        ensure(chatKey: chatKey).provider
    }

    func snapshotAndAppend(
        chatKey: ChatKey,
        generationID: GenerationID,
        content: UserInputContent,
        username: String?
    ) -> GenerationSnapshot {
        var context = ensure(chatKey: chatKey)
        let userMessage = ChatMessage.userContent(content, username: username)
        context.pendingTurns.append(.init(generationID: generationID, userMessage: userMessage, state: .pending))
        let messages = visibleHistory(for: context)
        contexts[chatKey] = context
        return .init(
            provider: context.provider,
            model: context.model,
            providerRouting: context.modelProviderRouting,
            temperature: context.temp,
            options: .init(
                showStats: context.showStats,
                showCost: context.showCost,
                showModel: context.showModel,
                reasoningEffort: context.reasoningEffort
            ),
            messages: messages
        )
    }

    func appendAssistant(
        chatKey: ChatKey,
        generationID: GenerationID,
        content: String,
        usage: StreamUsageSummary? = nil,
        billedTo: String? = nil
    ) {
        let real = usage?.cost ?? 0
        let billed = real * priceMultiplier()
        mutate(chatKey: chatKey) { context in
            guard let index = context.pendingTurns.firstIndex(where: { $0.generationID == generationID }) else {
                return
            }
            context.pendingTurns[index].state = .completed(content)
            flushResolvedTurns(&context)
            context.cumulativeUsage.totalTokens += usage?.totalTokens ?? 0
            context.cumulativeUsage.totalCost += real
            context.cumulativeUsage.totalBilledCost += billed
            context.cumulativeUsage.generationCount += 1
        }
        accumulateTenantUsage(chatID: chatKey.chatID, usage: usage)
        if let billedTo {
            chargeBalance(username: billedTo, billedUsd: billed, realUsd: real)
        }
    }

    func cancelPendingTurn(chatKey: ChatKey, generationID: GenerationID) {
        mutate(chatKey: chatKey) { context in
            guard let index = context.pendingTurns.firstIndex(where: { $0.generationID == generationID }) else {
                return
            }
            context.pendingTurns[index].state = .cancelled
            flushResolvedTurns(&context)
        }
    }

    func accumulateUsage(chatKey: ChatKey, usage: StreamUsageSummary?) {
        let multiplier = priceMultiplier()
        mutate(chatKey: chatKey) { context in
            context.cumulativeUsage.add(usage, priceMultiplier: multiplier)
        }
        accumulateTenantUsage(chatID: chatKey.chatID, usage: usage)
    }

    func resetUsage(chatKey: ChatKey) {
        mutate(chatKey: chatKey) { $0.cumulativeUsage = .zero }
    }

    // MARK: - Per-chat preset management

    func chatPresets(category: PresetCategory, chatKey: ChatKey) -> [Preset] {
        let ctx = ensure(chatKey: chatKey)
        switch category {
        case .model: return ctx.chatModelPresets
        case .temp: return ctx.chatTempPresets
        case .history: return ctx.chatHistoryLengthPresets
        case .role: return ctx.chatRolePresets
        }
    }

    func addChatPreset(category: PresetCategory, chatKey: ChatKey, display: String, value: String, provider: String? = nil) -> Preset {
        let preset = Preset(display: display, value: value, provider: provider)
        mutate(chatKey: chatKey) { ctx in
            switch category {
            case .model: ctx.chatModelPresets.append(preset)
            case .temp: ctx.chatTempPresets.append(preset)
            case .history: ctx.chatHistoryLengthPresets.append(preset)
            case .role: ctx.chatRolePresets.append(preset)
            }
        }
        return preset
    }

    func removeChatPresetByIndex(category: PresetCategory, chatKey: ChatKey, index: Int) -> Bool {
        var success = false
        mutate(chatKey: chatKey) { ctx in
            switch category {
            case .model:
                guard index >= 0, index < ctx.chatModelPresets.count else { return }
                ctx.chatModelPresets.remove(at: index)
                success = true
            case .temp:
                guard index >= 0, index < ctx.chatTempPresets.count else { return }
                ctx.chatTempPresets.remove(at: index)
                success = true
            case .history:
                guard index >= 0, index < ctx.chatHistoryLengthPresets.count else { return }
                ctx.chatHistoryLengthPresets.remove(at: index)
                success = true
            case .role:
                guard index >= 0, index < ctx.chatRolePresets.count else { return }
                ctx.chatRolePresets.remove(at: index)
                success = true
            }
        }
        return success
    }

    func editChatPreset(category: PresetCategory, chatKey: ChatKey, index: Int, display: String, value: String, provider: String? = nil) -> Bool {
        let preset = Preset(display: display, value: value, provider: provider)
        var success = false
        mutate(chatKey: chatKey) { ctx in
            switch category {
            case .model:
                guard index >= 0, index < ctx.chatModelPresets.count else { return }
                ctx.chatModelPresets[index] = preset
                success = true
            case .temp:
                guard index >= 0, index < ctx.chatTempPresets.count else { return }
                ctx.chatTempPresets[index] = preset
                success = true
            case .history:
                guard index >= 0, index < ctx.chatHistoryLengthPresets.count else { return }
                ctx.chatHistoryLengthPresets[index] = preset
                success = true
            case .role:
                guard index >= 0, index < ctx.chatRolePresets.count else { return }
                ctx.chatRolePresets[index] = preset
                success = true
            }
        }
        return success
    }

    // MARK: - Pending input

    func setPendingInput(_ input: PendingInput, chatKey: ChatKey) {
        _pendingInputs[chatKey] = input
    }

    func consumePendingInput(chatKey: ChatKey) -> PendingInput? {
        _pendingInputs.removeValue(forKey: chatKey)
    }

    func clearPendingInput(chatKey: ChatKey) {
        _pendingInputs.removeValue(forKey: chatKey)
    }

    func hasPendingInput(chatKey: ChatKey) -> Bool {
        _pendingInputs[chatKey] != nil
    }

    // MARK: - Stars price

    func starsPrice() -> Int? { _starsPrice }

    func setStarsPrice(_ price: Int?) {
        _starsPrice = price.flatMap { $0 > 0 ? $0 : nil }
        dirtyConfigs.insert(.starsPrice)
    }

    func setPendingStarsPriceInput(menuMessageID: Int, chatKey: ChatKey) {
        _pendingStarsPriceInputs[chatKey] = menuMessageID
    }

    func consumePendingStarsPriceInput(chatKey: ChatKey) -> Int? {
        _pendingStarsPriceInputs.removeValue(forKey: chatKey)
    }

    func hasPendingStarsPriceInput(chatKey: ChatKey) -> Bool {
        _pendingStarsPriceInputs[chatKey] != nil
    }

    func clearPendingStarsPriceInput(chatKey: ChatKey) {
        _pendingStarsPriceInputs.removeValue(forKey: chatKey)
    }

    // MARK: - Stars-per-USD rate (credit packs)

    func starsPerUsd() -> Int { _starsPerUsd }

    func setStarsPerUsd(_ rate: Int) {
        _starsPerUsd = max(1, rate)
        dirtyConfigs.insert(.starsPerUsd)
    }

    /// Stars to charge for a credit pack worth `cents` USD.
    func starsForCents(_ cents: Int) -> Int {
        max(1, Int((Double(cents) / 100.0 * Double(_starsPerUsd)).rounded()))
    }

    func setPendingStarsPerUsdInput(menuMessageID: Int, chatKey: ChatKey) {
        _pendingStarsPerUsdInputs[chatKey] = menuMessageID
    }

    func consumePendingStarsPerUsdInput(chatKey: ChatKey) -> Int? {
        _pendingStarsPerUsdInputs.removeValue(forKey: chatKey)
    }

    func hasPendingStarsPerUsdInput(chatKey: ChatKey) -> Bool {
        _pendingStarsPerUsdInputs[chatKey] != nil
    }

    func clearPendingStarsPerUsdInput(chatKey: ChatKey) {
        _pendingStarsPerUsdInputs.removeValue(forKey: chatKey)
    }

    // MARK: - Pending free model input

    func setPendingFreeModelInput(menuMessageID: Int, chatKey: ChatKey) {
        _pendingFreeModelInputs[chatKey] = menuMessageID
    }

    func consumePendingFreeModelInput(chatKey: ChatKey) -> Int? {
        _pendingFreeModelInputs.removeValue(forKey: chatKey)
    }

    func hasPendingFreeModelInput(chatKey: ChatKey) -> Bool {
        _pendingFreeModelInputs[chatKey] != nil
    }

    func clearPendingFreeModelInput(chatKey: ChatKey) {
        _pendingFreeModelInputs.removeValue(forKey: chatKey)
    }

    // MARK: - Free model access

    func freeModelIDs() -> [String] { _freeModelIDs }

    func setFreeModelIDs(_ ids: [String]) {
        _freeModelIDs = ids.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        dirtyConfigs.insert(.freeModels)
    }

    @discardableResult
    func addFreeModel(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !_freeModelIDs.contains(trimmed) else { return false }
        _freeModelIDs.append(trimmed)
        dirtyConfigs.insert(.freeModels)
        return true
    }

    @discardableResult
    func removeFreeModel(_ id: String) -> Bool {
        let before = _freeModelIDs.count
        _freeModelIDs.removeAll { $0 == id }
        let removed = _freeModelIDs.count < before
        if removed { dirtyConfigs.insert(.freeModels) }
        return removed
    }

    func effectiveFreeModelIDs() -> Set<String>? {
        let pinned = _freeModelIDs
        let openRouter = _openRouterFreeModelIDs
        guard !pinned.isEmpty || openRouter != nil else { return nil }
        var result = Set(pinned)
        if let openRouter { result.formUnion(openRouter) }
        return result
    }

    func isFreeModel(_ id: String) -> Bool {
        guard let effective = effectiveFreeModelIDs() else { return true }
        return effective.contains(id)
    }

    func firstFreeModel() -> String? {
        effectiveFreeModelIDs()?.first
    }

    func openRouterFreeModelIDs() -> Set<String>? { _openRouterFreeModelIDs }

    func updateOpenRouterFreeModelIDs(_ ids: Set<String>) {
        _openRouterFreeModelIDs = ids
    }

    func openRouterModelPrice(for id: String) -> ModelPriceInfo? { _openRouterModelPrices[id] }

    func openRouterModelPrices() -> [String: ModelPriceInfo] { _openRouterModelPrices }

    func updateOpenRouterModelPrices(_ prices: [String: ModelPriceInfo]) {
        for (k, v) in prices { _openRouterModelPrices[k] = v }
    }

    // MARK: - Card payment config

    func cardConfig() -> CardPaymentConfig { _cardConfig }

    func setCardProviderToken(_ token: String?) {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        _cardConfig.providerToken = trimmed.isEmpty ? nil : trimmed
        dirtyConfigs.insert(.card)
    }

    func setCardCurrency(_ currency: CardCurrency) {
        _cardConfig.currency = currency
        dirtyConfigs.insert(.card)
    }

    func setCardPriceMinorUnits(_ value: Int?) {
        _cardConfig.priceMinorUnits = value.flatMap { $0 > 0 ? $0 : nil }
        dirtyConfigs.insert(.card)
    }

    // MARK: - Crypto config

    func cryptoPriceUsdCents() -> Int? { _cryptoPriceUsdCents }

    func setCryptoPriceUsdCents(_ value: Int?) {
        _cryptoPriceUsdCents = value.flatMap { $0 > 0 ? $0 : nil }
        dirtyConfigs.insert(.crypto)
    }

    func cryptoAddress(_ chain: CryptoChain) -> String? {
        _cryptoAddresses[chain]
    }

    func cryptoAddresses() -> [CryptoChain: String] { _cryptoAddresses }

    func setCryptoAddress(_ chain: CryptoChain, address: String?) {
        let trimmed = address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            _cryptoAddresses.removeValue(forKey: chain)
        } else {
            _cryptoAddresses[chain] = trimmed
        }
        dirtyConfigs.insert(.crypto)
    }

    func nextCryptoSlot(asset: CryptoAsset) -> Int {
        let max = asset.maxConcurrentSlots
        let current = (_cryptoSlotCounters[asset] ?? Int.random(in: 0..<max))
        let next = (current + 1) % max
        _cryptoSlotCounters[asset] = next
        dirtyConfigs.insert(.crypto)
        return next
    }

    func upsertCryptoInvoice(_ invoice: CryptoInvoice) {
        _cryptoInvoices[invoice.id] = invoice
        dirtyConfigs.insert(.crypto)
    }

    func cryptoInvoice(id: String) -> CryptoInvoice? {
        _cryptoInvoices[id]
    }

    func openCryptoInvoices() -> [CryptoInvoice] {
        _cryptoInvoices.values.filter { $0.status == .open || $0.status == .partial }
    }

    func openCryptoInvoices(asset: CryptoAsset) -> [CryptoInvoice] {
        _cryptoInvoices.values.filter {
            ($0.status == .open || $0.status == .partial) && $0.asset == asset
        }
    }

    func openCryptoInvoiceForUser(username: String, asset: CryptoAsset, purpose: CryptoInvoicePurpose) -> CryptoInvoice? {
        let u = username.lowercased()
        return _cryptoInvoices.values.first {
            $0.username == u && $0.asset == asset && $0.resolvedPurpose == purpose
                && ($0.status == .open || $0.status == .partial)
        }
    }

    func cancelCryptoInvoice(id: String) {
        guard var inv = _cryptoInvoices[id] else { return }
        if inv.status == .open || inv.status == .partial {
            inv.status = .cancelled
            _cryptoInvoices[id] = inv
            dirtyConfigs.insert(.crypto)
        }
    }

    func expireDueCryptoInvoices(now: Date = Date()) -> [CryptoInvoice] {
        var expired: [CryptoInvoice] = []
        for (id, inv) in _cryptoInvoices {
            guard inv.status == .open || inv.status == .partial else { continue }
            if now >= inv.expiresAt {
                var copy = inv
                copy.status = .expired
                _cryptoInvoices[id] = copy
                expired.append(copy)
            }
        }
        if !expired.isEmpty { dirtyConfigs.insert(.crypto) }
        return expired
    }

    func usedSlots(asset: CryptoAsset) -> Set<Int> {
        Set(
            _cryptoInvoices.values
                .filter { ($0.status == .open || $0.status == .partial) && $0.asset == asset }
                .map { $0.slotOffset }
        )
    }

    func setPendingCryptoPriceInput(menuMessageID: Int, chatKey: ChatKey) {
        _pendingCryptoPriceInputs[chatKey] = menuMessageID
    }

    func consumePendingCryptoPriceInput(chatKey: ChatKey) -> Int? {
        _pendingCryptoPriceInputs.removeValue(forKey: chatKey)
    }

    func hasPendingCryptoPriceInput(chatKey: ChatKey) -> Bool {
        _pendingCryptoPriceInputs[chatKey] != nil
    }

    func clearPendingCryptoPriceInput(chatKey: ChatKey) {
        _pendingCryptoPriceInputs.removeValue(forKey: chatKey)
    }

    func setPendingCryptoAddressInput(menuMessageID: Int, chain: CryptoChain, chatKey: ChatKey) {
        _pendingCryptoAddressInputs[chatKey] = (menuMessageID, chain)
    }

    func consumePendingCryptoAddressInput(chatKey: ChatKey) -> (menuMessageID: Int, chain: CryptoChain)? {
        _pendingCryptoAddressInputs.removeValue(forKey: chatKey)
    }

    func hasPendingCryptoAddressInput(chatKey: ChatKey) -> Bool {
        _pendingCryptoAddressInputs[chatKey] != nil
    }

    func clearPendingCryptoAddressInput(chatKey: ChatKey) {
        _pendingCryptoAddressInputs.removeValue(forKey: chatKey)
    }

    func cryptoMatchMode() -> CryptoMatchMode { _cryptoMatchMode }

    func setCryptoMatchMode(_ mode: CryptoMatchMode) {
        _cryptoMatchMode = mode
        dirtyConfigs.insert(.crypto)
    }

    func cryptoAddressPool(_ chain: CryptoChain) -> [String] {
        _cryptoAddressPools[chain] ?? []
    }

    func cryptoAddressPools() -> [CryptoChain: [String]] { _cryptoAddressPools }

    @discardableResult
    func addCryptoPoolAddress(_ chain: CryptoChain, address: String) -> Bool {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var pool = _cryptoAddressPools[chain] ?? []
        guard !pool.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return false }
        pool.append(trimmed)
        _cryptoAddressPools[chain] = pool
        dirtyConfigs.insert(.crypto)
        return true
    }

    @discardableResult
    func removeCryptoPoolAddress(_ chain: CryptoChain, at index: Int) -> Bool {
        guard var pool = _cryptoAddressPools[chain], index >= 0, index < pool.count else { return false }
        pool.remove(at: index)
        if pool.isEmpty {
            _cryptoAddressPools.removeValue(forKey: chain)
        } else {
            _cryptoAddressPools[chain] = pool
        }
        dirtyConfigs.insert(.crypto)
        return true
    }

    /// All addresses worth polling for a chain — primary delta address plus pool.
    func pollableCryptoAddresses(_ chain: CryptoChain) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        if let primary = _cryptoAddresses[chain] {
            let key = primary.lowercased()
            if !seen.contains(key) { seen.insert(key); result.append(primary) }
        }
        for addr in _cryptoAddressPools[chain] ?? [] {
            let key = addr.lowercased()
            if !seen.contains(key) { seen.insert(key); result.append(addr) }
        }
        return result
    }

    /// Addresses already allocated to open/partial invoices for given asset.
    func allocatedPoolAddresses(asset: CryptoAsset) -> Set<String> {
        Set(
            _cryptoInvoices.values
                .filter { ($0.status == .open || $0.status == .partial) && $0.asset == asset }
                .map { $0.receivingAddress.lowercased() }
        )
    }

    /// Find first pool address for the chain that's not currently held by an open invoice
    /// of any asset on that chain.
    func nextFreePoolAddress(chain: CryptoChain) -> String? {
        let pool = _cryptoAddressPools[chain] ?? []
        guard !pool.isEmpty else { return nil }
        let allocated = Set(
            _cryptoInvoices.values
                .filter { ($0.status == .open || $0.status == .partial) && $0.asset.chain == chain }
                .map { $0.receivingAddress.lowercased() }
        )
        return pool.first { !allocated.contains($0.lowercased()) }
    }

    func openInvoiceMatching(asset: CryptoAsset, address: String) -> CryptoInvoice? {
        let target = address.lowercased()
        return _cryptoInvoices.values.first {
            ($0.status == .open || $0.status == .partial)
                && $0.asset == asset
                && $0.receivingAddress.lowercased() == target
        }
    }

    func setAdminPendingInput(_ input: AdminPendingInput, chatKey: ChatKey) {
        _pendingAdminInputs[chatKey] = input
    }

    func consumeAdminPendingInput(chatKey: ChatKey) -> AdminPendingInput? {
        _pendingAdminInputs.removeValue(forKey: chatKey)
    }

    func hasAdminPendingInput(chatKey: ChatKey) -> Bool {
        _pendingAdminInputs[chatKey] != nil
    }

    func clearAdminPendingInput(chatKey: ChatKey) {
        _pendingAdminInputs.removeValue(forKey: chatKey)
    }

    func setPendingCryptoPoolAddInput(menuMessageID: Int, chain: CryptoChain, chatKey: ChatKey) {
        _pendingCryptoPoolAddInputs[chatKey] = (menuMessageID, chain)
    }

    func consumePendingCryptoPoolAddInput(chatKey: ChatKey) -> (menuMessageID: Int, chain: CryptoChain)? {
        _pendingCryptoPoolAddInputs.removeValue(forKey: chatKey)
    }

    func hasPendingCryptoPoolAddInput(chatKey: ChatKey) -> Bool {
        _pendingCryptoPoolAddInputs[chatKey] != nil
    }

    func clearPendingCryptoPoolAddInput(chatKey: ChatKey) {
        _pendingCryptoPoolAddInputs.removeValue(forKey: chatKey)
    }

    func cryptoConfigSnapshot() -> CryptoConfigSnapshot {
        var addrs: [String: String] = [:]
        for (chain, value) in _cryptoAddresses { addrs[chain.rawValue] = value }
        var counters: [String: Int] = [:]
        for (asset, value) in _cryptoSlotCounters { counters[asset.rawValue] = value }
        var pools: [String: [String]] = [:]
        for (chain, list) in _cryptoAddressPools { pools[chain.rawValue] = list }
        return CryptoConfigSnapshot(
            priceUsdCents: _cryptoPriceUsdCents,
            addresses: addrs,
            slotCounters: counters,
            invoices: Array(_cryptoInvoices.values),
            matchMode: _cryptoMatchMode.rawValue,
            addressPools: pools.isEmpty ? nil : pools
        )
    }

    func restoreCryptoConfig(_ snapshot: CryptoConfigSnapshot?) {
        _cryptoPriceUsdCents = snapshot?.priceUsdCents
        _cryptoAddresses = [:]
        for (key, value) in snapshot?.addresses ?? [:] {
            if let chain = CryptoChain(rawValue: key) {
                _cryptoAddresses[chain] = value
            }
        }
        _cryptoSlotCounters = [:]
        for (key, value) in snapshot?.slotCounters ?? [:] {
            if let asset = CryptoAsset(rawValue: key) {
                _cryptoSlotCounters[asset] = value
            }
        }
        _cryptoInvoices = [:]
        for invoice in snapshot?.invoices ?? [] {
            _cryptoInvoices[invoice.id] = invoice
        }
        _cryptoMatchMode = (snapshot?.matchMode).flatMap { CryptoMatchMode(rawValue: $0) } ?? .amountDelta
        _cryptoAddressPools = [:]
        for (key, list) in snapshot?.addressPools ?? [:] {
            if let chain = CryptoChain(rawValue: key) {
                _cryptoAddressPools[chain] = list
            }
        }
    }

    func superAdminPrivateChats() -> [ChatKey] {
        contexts.keys.filter { $0.chatID > 0 && chatOwnership[$0.chatID] == defaultOwnerUsername }.map { $0 }
    }

    /// Subscription/licence coverage only — the generation is paid by a
    /// tenant's subscription, not by the sender's personal balance.
    func hasSubscriptionCoverage(username: String?, userID: Int? = nil, chatID: Int? = nil) -> Bool {
        let lowered = username?.lowercased()
        let simulated: Bool = {
            guard let u = lowered else { return false }
            return superAdminUsernames.contains(u) && _simulatedRoles[u] != nil
        }()

        // Every path below requires the granting tenant's subscription to be
        // active: an expired admin keeps their panel (to renew) but their
        // chats and users fall back to free models.
        if !simulated, let u = lowered {
            if let own = tenants[u], own.isActive { return true }
            for tenant in tenants.values where tenant.licensedUsernames.contains(u) && tenant.isActive {
                return true
            }
        }

        // Chat-level licensing: chat assigned to a tenant grants access to all members.
        if let chatID, let owner = chatOwnership[chatID],
           tenants[owner]?.isActive == true {
            return true
        }
        // Per-chat whitelisted user IDs (set by tenant owner for this chat).
        if let chatID, let userID {
            let tenant = tenantState(for: chatID)
            if tenant.whitelistedUserIDs.contains(userID), tenant.isActive {
                return true
            }
        }
        return false
    }

    /// The sponsor of a group chat: the owner whose *active* subscription opens
    /// paid access to the whole chat. Used for the hero credit under answers.
    /// Returns nil when the chat has no active-tenant owner, or when the asker
    /// is the sponsor themselves (no self-crediting).
    func chatSponsor(chatID: Int, askerUsername: String?) -> String? {
        guard let owner = chatOwnership[chatID], tenants[owner]?.isActive == true else {
            return nil
        }
        if let asker = askerUsername?.lowercased(), asker == owner {
            return nil
        }
        return owner
    }

    /// Paid-model access: subscription coverage OR a positive personal
    /// balance. The balance path deliberately ignores role simulation so the
    /// super-admin can test pay-as-you-go end to end.
    func hasFullModelAccess(username: String?, userID: Int? = nil, chatID: Int? = nil) -> Bool {
        if hasSubscriptionCoverage(username: username, userID: userID, chatID: chatID) {
            return true
        }
        return hasPositiveBalance(username: username)
    }

    // MARK: - Daily premium "taste" (free-tier)

    enum DailyPremiumDecision: Sendable {
        /// One unit was consumed; the paid model may answer this turn.
        case allowed
        /// Today's allowance is spent; caller should fall back to free + upsell.
        case exhausted(limit: Int)
    }

    /// Consumes one unit of today's free premium allowance for a free-tier
    /// chat/user and reports whether a paid-model answer is allowed. Group chats
    /// share one counter (chatID → social pressure); private chats count per
    /// user (userID). Counter resets at the UTC day boundary. In-memory only
    /// (see `_premiumDailyUsage`). `.exhausted` does not consume a unit.
    func consumeDailyPremium(chatID: Int, userID: Int?, isGroup: Bool) -> DailyPremiumDecision {
        let limit = dailyPremiumLimitValue
        guard limit > 0 else { return .exhausted(limit: limit) }
        let key = isGroup ? "c\(chatID)" : "u\(userID ?? chatID)"
        let today = Int(Date().timeIntervalSince1970 / 86_400)
        var entry = _premiumDailyUsage[key] ?? (day: today, used: 0)
        if entry.day != today { entry = (day: today, used: 0) }
        guard entry.used < limit else { return .exhausted(limit: limit) }
        entry.used += 1
        _premiumDailyUsage[key] = entry
        return .allowed
    }

    // MARK: - Funnel analytics (roadmap step 7)

    /// Records one funnel event. Persisted (dirties GlobalConfigKey.funnel).
    func bumpFunnel(_ event: FunnelEvent, by amount: Int = 1) {
        funnelCounters[event.rawValue, default: 0] += amount
        dirtyConfigs.insert(.funnel)
    }

    /// Counts the `firstMessage` activation the first time a chat produces an LLM
    /// turn. Idempotent per chat via a persisted flag on the context, so a
    /// restart never re-counts it.
    func markFirstMessageIfNeeded(chatKey: ChatKey) {
        var context = ensure(chatKey: chatKey)
        guard !context.funnelFirstMessageCounted else { return }
        context.funnelFirstMessageCounted = true
        contexts[chatKey] = context
        dirtyContexts.insert(chatKey)
        bumpFunnel(.firstMessage)
    }

    // MARK: - Onboarding examples (roadmap step 9)

    func onboardingConfig() -> OnboardingConfig { onboardingConfigValue }

    func setOnboardingConfig(_ config: OnboardingConfig) {
        onboardingConfigValue = config.normalized
        dirtyConfigs.insert(.onboarding)
    }

    /// Appends an example; nil when the list is full or the input normalized to
    /// nothing (the menu turns that into a toast).
    func addOnboardingExample(label: String, prompt: String) -> OnboardingExample? {
        var config = onboardingConfigValue
        guard config.examples.count < OnboardingConfig.maxExamples else { return nil }
        let example = OnboardingExample(
            id: OnboardingConfig.makeID(existing: config.examples),
            label: label,
            prompt: prompt
        )
        config.examples.append(example)
        setOnboardingConfig(config)
        // Re-read: normalization may have rejected an empty label/prompt.
        return onboardingConfigValue.example(id: example.id)
    }

    /// Edits an example in place, keeping its id (live buttons keep working) and
    /// its tap counter (stats stay comparable across wording tweaks).
    @discardableResult
    func updateOnboardingExample(id: String, label: String, prompt: String) -> Bool {
        var config = onboardingConfigValue
        guard let index = config.examples.firstIndex(where: { $0.id == id }) else { return false }
        config.examples[index].label = label
        config.examples[index].prompt = prompt
        setOnboardingConfig(config)
        return onboardingConfigValue.example(id: id) != nil
    }

    @discardableResult
    func removeOnboardingExample(id: String) -> Bool {
        var config = onboardingConfigValue
        let before = config.examples.count
        config.examples.removeAll { $0.id == id }
        guard config.examples.count < before else { return false }
        setOnboardingConfig(config)
        return true
    }

    /// Flips one example on/off; returns the new state (nil = unknown id).
    func toggleOnboardingExample(id: String) -> Bool? {
        var config = onboardingConfigValue
        guard let index = config.examples.firstIndex(where: { $0.id == id }) else { return nil }
        config.examples[index].enabled.toggle()
        let newValue = config.examples[index].enabled
        setOnboardingConfig(config)
        return newValue
    }

    /// Moves an example one slot up — the order is the button order in the
    /// greeting, so this is how the super-admin puts the best example first.
    @discardableResult
    func moveOnboardingExampleUp(id: String) -> Bool {
        var config = onboardingConfigValue
        guard let index = config.examples.firstIndex(where: { $0.id == id }), index > 0 else { return false }
        config.examples.swapAt(index, index - 1)
        setOnboardingConfig(config)
        return true
    }

    /// Looks up a tapped example and counts the tap (per-example stat + funnel).
    /// Deliberately tolerant of a disabled example: a greeting already delivered
    /// keeps working after the super-admin hides it from new greetings.
    func recordOnboardingTap(id: String) -> OnboardingExample? {
        guard let index = onboardingConfigValue.examples.firstIndex(where: { $0.id == id }) else { return nil }
        onboardingConfigValue.examples[index].taps += 1
        dirtyConfigs.insert(.onboarding)
        bumpFunnel(.exampleTapped)
        return onboardingConfigValue.examples[index]
    }

    func resetOnboardingTapStats() {
        for index in onboardingConfigValue.examples.indices {
            onboardingConfigValue.examples[index].taps = 0
        }
        dirtyConfigs.insert(.onboarding)
    }

    /// Restores the shipped example set, keeping the on/off switches as they are.
    func resetOnboardingExamplesToDefaults() {
        var config = OnboardingConfig.default
        config.enabled = onboardingConfigValue.enabled
        config.showInGroups = onboardingConfigValue.showInGroups
        setOnboardingConfig(config)
    }

    // MARK: - Two-sided referral (roadmap step 10)

    func referralConfig() -> ReferralConfig { referralConfigValue }

    func setReferralConfig(_ config: ReferralConfig) {
        referralConfigValue = config.normalized
        dirtyConfigs.insert(.referrals)
    }

    private func markReferralLedgerDirty() {
        referralLedgerValue.prune()
        dirtyConfigs.insert(.referralLedger)
    }

    /// @username of a user we have met in a private chat. Telegram private
    /// chatIDs equal the userID, so the chat-meta table doubles as the
    /// userID → @username directory needed to credit a wallet.
    func usernameForUserID(_ userID: Int) -> String? {
        guard let meta = chatMetaByID[userID], meta.type == "private",
              let username = meta.username, !username.isEmpty else { return nil }
        return username.lowercased()
    }

    /// True when this person has used the bot before — the "new user only"
    /// anti-fraud rule. Signals: a private chat that already produced turns, an
    /// owned licence, or a wallet.
    private func hasPriorBotActivity(userID: Int, username: String?) -> Bool {
        if let context = contexts[ChatKey(chatID: userID, threadID: 0)] {
            // `ensure` seeds history with the system message, so "used before"
            // means more than that one entry.
            if context.funnelFirstMessageCounted
                || context.cumulativeUsage.generationCount > 0
                || context.history.count > 1 { return true }
        }
        if userTenantMap[userID] != nil { return true }
        if let user = username?.lowercased(), !user.isEmpty {
            if tenants[user] != nil { return true }
            if userBalances[user] != nil { return true }
        }
        return false
    }

    /// Attributes a new user to the inviter behind a `ref_` deep link. Pays
    /// nothing yet: the reward lands after the friend's first real answer
    /// (`redeemReferralIfDue`), which is what makes farming expensive.
    func bindReferral(invitedUserID: Int, invitedUsername: String?, inviterUserID: Int) -> ReferralBindOutcome {
        let config = referralConfigValue
        guard config.enabled else { return .disabled }
        guard invitedUserID != inviterUserID else { return .selfInvite }

        let invitedKey = String(invitedUserID)
        if let existing = referralLedgerValue.records[invitedKey] {
            return .alreadyBound(inviter: existing.inviterUsername)
        }

        // The inviter must be known to us by @username — that is the wallet key.
        guard let inviterUsername = usernameForUserID(inviterUserID) else { return .unknownInviter }
        let invited = invitedUsername?.lowercased()
        if let invited, invited == inviterUsername { return .selfInvite }

        guard !hasPriorBotActivity(userID: invitedUserID, username: invited) else { return .notNewUser }

        referralLedgerValue.records[invitedKey] = ReferralRecord(
            inviterUserID: inviterUserID,
            inviterUsername: inviterUsername,
            invitedUsername: invited
        )
        var tally = referralLedgerValue.tallies[String(inviterUserID)] ?? ReferralTally(username: inviterUsername)
        tally.username = inviterUsername
        tally.invited += 1
        referralLedgerValue.tallies[String(inviterUserID)] = tally
        markReferralLedgerDirty()
        bumpFunnel(.referralJoined)

        return .bound(
            inviter: inviterUsername,
            inviteeRewardUsd: config.inviteeRewardUsd,
            needsUsername: invited == nil && config.inviteeRewardCents > 0
        )
    }

    /// Pays a pending referral pair once the invited user has produced their
    /// first real answer. Credits both wallets and resolves the record in one
    /// actor step, so a crash can never leave money credited twice or a pair
    /// half-paid. Returns nil when there is nothing to pay.
    func redeemReferralIfDue(userID: Int, username: String?) -> ReferralPayout? {
        let config = referralConfigValue
        guard config.enabled else { return nil }
        let key = String(userID)
        guard var record = referralLedgerValue.records[key], record.isPending else { return nil }

        // The invited side needs a @username to receive their share; until they
        // set one the pair stays pending (nobody loses their reward).
        let invited = (username?.lowercased()).flatMap { $0.isEmpty ? nil : $0 } ?? record.invitedUsername
        if config.inviteeRewardCents > 0, invited == nil { return nil }
        if let invited { record.invitedUsername = invited }

        // Usernames change: pay the inviter's *current* handle when we know it,
        // so the credit never lands on an abandoned wallet key.
        if let current = usernameForUserID(record.inviterUserID) {
            record.inviterUsername = current
        }

        var tally = referralLedgerValue.tallies[String(record.inviterUserID)]
            ?? ReferralTally(username: record.inviterUsername)
        tally.username = record.inviterUsername

        // Anti-farming cap: beyond it the pair resolves without a payout, so it
        // is never retried, and the refusal stays visible to the super-admin.
        let cap = config.maxRewardsPerInviter
        if cap > 0, tally.rewarded >= cap {
            record.rewardedAt = Date()
            record.blocked = true
            tally.blocked += 1
            referralLedgerValue.records[key] = record
            referralLedgerValue.tallies[String(record.inviterUserID)] = tally
            markReferralLedgerDirty()
            return nil
        }

        let inviterReward = config.inviterRewardUsd
        let inviteeReward = config.inviteeRewardUsd
        if inviterReward > 0 {
            creditBalance(username: record.inviterUsername, amountUsd: inviterReward)
        }
        if inviteeReward > 0, let invited {
            creditBalance(username: invited, amountUsd: inviteeReward)
        }

        record.rewardedAt = Date()
        record.inviterRewardUsd = inviterReward
        record.inviteeRewardUsd = inviteeReward
        tally.rewarded += 1
        tally.earnedUsd += inviterReward
        referralLedgerValue.paidOutUsd += inviterReward + inviteeReward
        referralLedgerValue.records[key] = record
        referralLedgerValue.tallies[String(record.inviterUserID)] = tally
        markReferralLedgerDirty()
        bumpFunnel(.referralRewarded)

        return ReferralPayout(
            inviterUserID: record.inviterUserID,
            inviterUsername: record.inviterUsername,
            inviterRewardUsd: inviterReward,
            invitedUsername: invited,
            inviteeRewardUsd: inviteeReward,
            inviterRewardedTotal: tally.rewarded
        )
    }

    /// Personal referral state for the `/ref` page.
    func referralUserStats(userID: Int) -> ReferralUserStats {
        let tally = referralLedgerValue.tallies[String(userID)]
        let pending = referralLedgerValue.records.values
            .filter { $0.inviterUserID == userID && $0.isPending }
            .count
        let cap = referralConfigValue.maxRewardsPerInviter
        return ReferralUserStats(
            invited: tally?.invited ?? 0,
            rewarded: tally?.rewarded ?? 0,
            pending: pending,
            earnedUsd: tally?.earnedUsd ?? 0,
            capRemaining: cap > 0 ? max(0, cap - (tally?.rewarded ?? 0)) : nil,
            incoming: referralLedgerValue.records[String(userID)]
        )
    }

    /// Program-wide numbers for the super-admin page and `/metrics`.
    func referralOverview(topLimit: Int = 5) -> ReferralOverview {
        let ledger = referralLedgerValue
        return ReferralOverview(
            bound: ledger.records.count,
            pending: ledger.pendingCount,
            rewarded: ledger.rewardedCount,
            blocked: ledger.blockedCount,
            paidOutUsd: ledger.paidOutUsd,
            inviters: ledger.tallies.count,
            top: ledger.topInviters(limit: topLimit)
        )
    }

    /// Wipes attributions and aggregates (super-admin reset). Destructive: the
    /// "one attribution per person" guard forgets everyone, so previously
    /// invited users could be attributed again if they are still "new".
    @discardableResult
    func clearReferralLedger() -> Int {
        let count = referralLedgerValue.records.count
        referralLedgerValue = .empty
        dirtyConfigs.insert(.referralLedger)
        return count
    }

    /// Funnel event counts plus sponsor tallies derived live from tenant state:
    /// active = paying now, expired = churned, unlimited = comped. Super-admins
    /// are excluded — they are not paying sponsors.
    func funnelReport() -> FunnelReport {
        let now = Date()
        let lead = Double(max(reminderConfigValue.daysBeforeExpiry, 1)) * 86_400
        var active = 0, expired = 0, unlimited = 0, expiringSoon = 0, offers = 0
        for (owner, tenant) in tenants where !superAdminUsernames.contains(owner) {
            if let until = tenant.paidUntil {
                if until > now {
                    active += 1
                    if until.timeIntervalSince(now) <= lead { expiringSoon += 1 }
                } else {
                    expired += 1
                }
            } else {
                unlimited += 1
            }
            if tenant.winbackDiscount?.isActive(now: now) == true { offers += 1 }
        }
        return FunnelReport(
            counters: funnelCounters,
            sponsorsActive: active,
            sponsorsExpired: expired,
            sponsorsUnlimited: unlimited,
            sponsorsExpiringSoon: expiringSoon,
            winbackOffersActive: offers,
            referralPending: referralLedgerValue.pendingCount,
            referralRewarded: referralLedgerValue.rewardedCount,
            referralPaidCents: Int((referralLedgerValue.paidOutUsd * 100).rounded())
        )
    }

    // MARK: - Per-tenant licensed users (paid access for individuals)

    @discardableResult
    func addLicensedUser(ownerUsername: String, target: String) -> Bool {
        let owner = ownerUsername.lowercased()
        let user = target.lowercased()
        guard !user.isEmpty, tenants[owner] != nil else { return false }
        var inserted = false
        mutateTenantByOwner(owner) { inserted = $0.licensedUsernames.insert(user).inserted }
        return inserted
    }

    @discardableResult
    func removeLicensedUser(ownerUsername: String, target: String) -> Bool {
        let owner = ownerUsername.lowercased()
        let user = target.lowercased()
        guard tenants[owner] != nil else { return false }
        var removed = false
        mutateTenantByOwner(owner) { removed = $0.licensedUsernames.remove(user) != nil }
        return removed
    }

    func licensedUsers(ownerUsername: String) -> [String] {
        Array(tenants[ownerUsername.lowercased()]?.licensedUsernames ?? []).sorted()
    }

    // MARK: - Tenant usage / stats

    func tenantUsage(ownerUsername: String) -> CumulativeUsage {
        tenants[ownerUsername.lowercased()]?.cumulativeUsage ?? .zero
    }

    func tenantStats() -> [TenantStatsRow] {
        tenants.values.map { tenant in
            let owner = tenant.ownerUsername
            let chats = chatOwnership.values.filter { $0 == owner }.count
            return TenantStatsRow(
                username: owner,
                usage: tenant.cumulativeUsage,
                chatCount: chats,
                licensedUserCount: tenant.licensedUsernames.count,
                isSuperAdmin: superAdminUsernames.contains(owner),
                paidUntil: tenant.paidUntil,
                isActive: tenant.isActive
            )
        }
        .sorted { $0.username < $1.username }
    }

    private func accumulateTenantUsage(chatID: Int, usage: StreamUsageSummary?) {
        let owner = chatOwnership[chatID] ?? defaultOwnerUsername
        let multiplier = priceMultiplier()
        mutateTenantByOwner(owner) {
            $0.cumulativeUsage.add(usage, priceMultiplier: multiplier)
        }
    }

    func model(chatKey: ChatKey) -> String {
        ensure(chatKey: chatKey).model
    }

    func setModelOnly(chatKey: ChatKey, model: String) {
        mutate(chatKey: chatKey) {
            $0.model = model
            // Provider pin belongs to the previously chosen model.
            $0.modelProviderRouting = nil
        }
    }

    // MARK: - Chat listings

    func privateChats(ownedBy owner: String? = nil) -> [(chatID: Int, threadID: Int64)] {
        contexts.keys
            .filter { $0.chatID > 0 }
            .filter { owner == nil || chatOwnership[$0.chatID] == owner }
            .map { (chatID: $0.chatID, threadID: $0.threadID) }
    }

    func groupChats(ownedBy owner: String? = nil) -> [(chatID: Int, threadID: Int64)] {
        contexts.keys
            .filter { $0.chatID < 0 }
            .filter { owner == nil || chatOwnership[$0.chatID] == owner }
            .map { (chatID: $0.chatID, threadID: $0.threadID) }
    }

    func chatsWithBackupNotify() -> [ChatKey] {
        contexts.filter { $0.value.backupNotify }.map(\.key)
    }

    func chatsUsing(model: String) -> [ChatKey] {
        contexts.filter { $0.value.model == model }.map(\.key)
    }

    func allTrackedModelIDs() -> Set<String> {
        var ids = Set<String>()
        for tenant in tenants.values {
            ids.insert(tenant.defaultModel)
            tenant.modelPresets.forEach { ids.insert($0.value) }
        }
        for ctx in contexts.values {
            ids.insert(ctx.model)
            ctx.chatModelPresets.forEach { ids.insert($0.value) }
        }
        return ids
    }

    func history(chatKey: ChatKey) -> [ChatMessage] {
        ensure(chatKey: chatKey).history
    }

    func resetChat(chatKey: ChatKey) {
        let tenant = tenantState(for: chatKey.chatID)
        let role = roleWithCompanyMembers(chatID: chatKey.chatID, role: tenant.defaultRole + formatOptions)
        contexts[chatKey] = ChatContext(
            role: role,
            history: [.init(role: "system", content: role)],
            pendingTurns: [],
            model: tenant.defaultModel,
            modelProviderRouting: nil,
            temp: 1.5,
            showStats: false,
            maxHistory: tenant.defaultHistoryLength,
            showCost: true,
            showModel: true,
            provider: .openrouter,
            suffix: defaultSuffix,
            reasoningEffort: nil,
            backupNotify: false,
            cumulativeUsage: .zero,
            chatModelPresets: [],
            chatTempPresets: [],
            chatHistoryLengthPresets: [],
            chatRolePresets: []
        )
        dirtyContexts.insert(chatKey)
    }

    // MARK: - Chat metadata (titles / usernames for admin tooling)

    func recordChatMeta(chatID: Int, info: ChatMetaInfo) {
        guard chatMetaByID[chatID] != info else { return }
        chatMetaByID[chatID] = info
        dirtyConfigs.insert(.chatMeta)
    }

    func chatMeta(chatID: Int) -> ChatMetaInfo? {
        chatMetaByID[chatID]
    }

    /// "Title" / "@username" when known, bare ID otherwise.
    func chatDisplayLabel(chatID: Int) -> String {
        chatMetaByID[chatID]?.displayLabel ?? String(chatID)
    }

    // MARK: - Invite links (referral access under an admin's licence)

    func inviteToken(owner: String) -> String? {
        let u = owner.lowercased()
        return inviteRecords.first(where: { $0.value.ownerUsername == u })?.key
    }

    /// Replaces the owner's invite with a fresh token (old links stop working).
    func regenerateInviteToken(owner: String) -> String? {
        let u = owner.lowercased()
        guard tenants[u] != nil else { return nil }
        inviteRecords = inviteRecords.filter { $0.value.ownerUsername != u }
        let token = Self.makeInviteToken()
        inviteRecords[token] = InviteRecord(ownerUsername: u, createdAt: Date())
        dirtyConfigs.insert(.invites)
        return token
    }

    @discardableResult
    func revokeInviteToken(owner: String) -> Bool {
        let u = owner.lowercased()
        let before = inviteRecords.count
        inviteRecords = inviteRecords.filter { $0.value.ownerUsername != u }
        if inviteRecords.count != before {
            dirtyConfigs.insert(.invites)
            return true
        }
        return false
    }

    /// Returns the issuing owner when the token is valid and their
    /// subscription is active.
    func redeemInvite(token: String) -> String? {
        guard let record = inviteRecords[token],
              tenants[record.ownerUsername]?.isActive == true else { return nil }
        return record.ownerUsername
    }

    private static func makeInviteToken() -> String {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<16).map { _ in alphabet.randomElement()! })
    }

    // MARK: - Markup & balances (pay-as-you-go)

    func markupPercent() -> Int { markupPercentValue }

    func setMarkupPercent(_ percent: Int) {
        markupPercentValue = max(0, min(500, percent))
        dirtyConfigs.insert(.markup)
    }

    /// Daily free-premium "taste" allowance (roadmap step 6). Super-admin knob.
    func dailyPremiumLimit() -> Int { dailyPremiumLimitValue }

    func setDailyPremiumLimit(_ value: Int) {
        dailyPremiumLimitValue = max(0, min(100, value))
        dirtyConfigs.insert(.dailyPremiumLimit)
    }

    /// Multiplier applied to real provider cost for everything customers see
    /// and pay: 30% markup → 1.3.
    func priceMultiplier() -> Double {
        1.0 + Double(markupPercentValue) / 100.0
    }

    /// Customer-facing total for a usage record. Rows written before markup
    /// existed carry no billed value — approximate with the current rate.
    func billedCost(of usage: CumulativeUsage) -> Double {
        if usage.totalBilledCost > 0 { return usage.totalBilledCost }
        return usage.totalCost * priceMultiplier()
    }

    func balance(username: String?) -> UserBalance? {
        guard let u = username?.lowercased() else { return nil }
        return userBalances[u]
    }

    func hasPositiveBalance(username: String?) -> Bool {
        (balance(username: username)?.balanceUsd ?? 0) > 0
    }

    /// Adds (or subtracts, for corrections) to the user's balance. Creates the
    /// wallet on first credit.
    @discardableResult
    func creditBalance(username: String, amountUsd: Double) -> UserBalance {
        let u = username.lowercased()
        var wallet = userBalances[u] ?? .empty
        wallet.balanceUsd += amountUsd
        wallet.updatedAt = Date()
        userBalances[u] = wallet
        dirtyConfigs.insert(.balances)
        return wallet
    }

    @discardableResult
    func setBalanceAmount(username: String, amountUsd: Double) -> UserBalance {
        let u = username.lowercased()
        var wallet = userBalances[u] ?? .empty
        wallet.balanceUsd = amountUsd
        wallet.updatedAt = Date()
        userBalances[u] = wallet
        dirtyConfigs.insert(.balances)
        return wallet
    }

    @discardableResult
    func removeBalance(username: String) -> Bool {
        let removed = userBalances.removeValue(forKey: username.lowercased()) != nil
        if removed { dirtyConfigs.insert(.balances) }
        return removed
    }

    func allBalances() -> [(username: String, wallet: UserBalance)] {
        userBalances
            .map { (username: $0.key, wallet: $0.value) }
            .sorted { $0.username < $1.username }
    }

    /// What the footer will show as the post-charge balance. The actual charge
    /// happens in `appendAssistant`; formula is identical.
    func projectedBalanceAfterCharge(username: String, realCost: Double) -> Double {
        let current = userBalances[username.lowercased()]?.balanceUsd ?? 0
        return current - realCost * priceMultiplier()
    }

    private func chargeBalance(username: String, billedUsd: Double, realUsd: Double) {
        guard billedUsd > 0 else { return }
        let u = username.lowercased()
        var wallet = userBalances[u] ?? .empty
        wallet.balanceUsd -= billedUsd
        wallet.spentBilledUsd += billedUsd
        wallet.spentRealUsd += realUsd
        wallet.updatedAt = Date()
        userBalances[u] = wallet
        dirtyConfigs.insert(.balances)
    }

    // MARK: - Ad campaigns

    func adCampaigns() -> [AdCampaign] {
        adCampaignList.sorted { $0.createdAt < $1.createdAt }
    }

    func adCampaign(id: String) -> AdCampaign? {
        adCampaignList.first { $0.id == id }
    }

    func upsertAdCampaign(_ campaign: AdCampaign) {
        if let index = adCampaignList.firstIndex(where: { $0.id == campaign.id }) {
            adCampaignList[index] = campaign
        } else {
            adCampaignList.append(campaign)
        }
        dirtyConfigs.insert(.ads)
    }

    @discardableResult
    func removeAdCampaign(id: String) -> Bool {
        let before = adCampaignList.count
        adCampaignList.removeAll { $0.id == id }
        let removed = adCampaignList.count < before
        if removed { dirtyConfigs.insert(.ads) }
        return removed
    }

    @discardableResult
    func setAdCampaignEnabled(id: String, enabled: Bool) -> Bool {
        guard let index = adCampaignList.firstIndex(where: { $0.id == id }) else { return false }
        adCampaignList[index].enabled = enabled
        dirtyConfigs.insert(.ads)
        return true
    }

    /// Counts a bot reply in an ad-eligible chat and returns the campaign to
    /// show now, if frequency/pacing allow one. Recording the impression and
    /// resetting the per-chat counters happens here so the decision is atomic.
    func nextAdToShow(chatKey: ChatKey) -> AdCampaign? {
        var context = ensure(chatKey: chatKey)
        context.adReplyCounter += 1
        contexts[chatKey] = context
        dirtyContexts.insert(chatKey)

        let now = Date()

        let candidates = adCampaignList.filter { campaign in
            campaign.isRunning(now: now)
                && campaign.pacingAllows(now: now)
                && context.adReplyCounter >= campaign.everyNReplies
                && (context.adLastShownAt.map {
                    now.timeIntervalSince($0) >= TimeInterval(campaign.minIntervalSeconds)
                } ?? true)
        }
        // Least-shown campaign first → fair rotation between active ads.
        if let chosen = candidates.min(by: { $0.impressionsUsed < $1.impressionsUsed }),
           let index = adCampaignList.firstIndex(where: { $0.id == chosen.id }) {
            adCampaignList[index].impressionsUsed += 1
            dirtyConfigs.insert(.ads)

            context.adReplyCounter = 0
            context.adLastShownAt = now
            contexts[chatKey] = context
            dirtyContexts.insert(chatKey)
            return adCampaignList[index]
        }

        // Fallback: the built-in self-promo fills the slot when no super-admin
        // campaign is running. If a real campaign is running but its throttle
        // isn't met this call, it owns the slot — don't undercut it. Same
        // per-chat throttle; synthetic, so no impression count / persistence.
        guard !adCampaignList.contains(where: { $0.isRunning(now: now) }) else { return nil }
        let promo = AdCampaign.selfPromo
        guard context.adReplyCounter >= promo.everyNReplies,
              context.adLastShownAt.map({ now.timeIntervalSince($0) >= TimeInterval(promo.minIntervalSeconds) }) ?? true
        else { return nil }

        context.adReplyCounter = 0
        context.adLastShownAt = now
        contexts[chatKey] = context
        dirtyContexts.insert(chatKey)
        return promo
    }
}
