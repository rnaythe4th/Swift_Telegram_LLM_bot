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
    /// Storage key — pass back to the store; `label` is what people read.
    let username: String
    let label: String
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
    /// Paid model the daily-cap gate swapped out for a free one (roadmap step
    /// 6). Without it a purchase looks like it changed nothing: the chat would
    /// keep answering on the fallback model until someone reopened the model
    /// menu. Cleared the moment the model is chosen again, by anyone.
    var downgradedFromModel: String? = nil
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
    /// Pay-as-you-go wallets, keyed by `UserKey`.
    var userBalances: [String: UserBalance] = [:]
    /// userID ↔ @username directory. Everything above that is "keyed by user"
    /// is keyed by `UserKey` (`#<userID>`), and this is what turns a typed
    /// `@name` into that key and back into a label for the interface. Persisted
    /// via GlobalConfigKey.userDirectory.
    var userDirectoryValue: UserDirectory = .empty

    /// Conversion-funnel event counters (roadmap step 7), keyed by
    /// FunnelEvent.rawValue. Persisted via GlobalConfigKey.funnel so the numbers
    /// survive restarts/redeploys.
    var funnelCounters: [String: Int] = [:]
    /// The same events bucketed per day (roadmap step 7), so the page can show
    /// a period and not only an all-time total. Persisted via
    /// GlobalConfigKey.funnelDaily, pruned to `FunnelDailyLog.windowDays`.
    var funnelDailyValue: FunnelDailyLog = .empty

    /// Built-in self-promo that fills the ad slot when no paid campaign runs
    /// (roadmap step 5). Super-admin knob, persisted via
    /// GlobalConfigKey.selfPromo.
    var selfPromoConfigValue: SelfPromoConfig = .default

    /// Daily free "taste" of premium for free-tier chats/users (roadmap step 6).
    /// Group chats share one counter (`c<chatID>`); private chats count per user
    /// (`u<userID>`). Persisted via GlobalConfigKey.dailyPremiumUsage — see
    /// `DailyPremiumUsage` for why this one is not in-memory.
    var premiumDailyUsage: [String: DailyPremiumUsage] = [:]

    /// When each group last got its welcome, and when each chat last showed the
    /// sponsor credit. Both are anti-noise timers whose worst case on restart is
    /// one extra line — in-memory by the same §17 rule as `_premiumDailyUsage`.
    private var _groupGreetedAt: [Int: Date] = [:]
    private var _sponsorCreditShownAt: [Int: Date] = [:]
    static let groupGreetingCooldown: TimeInterval = 10 * 60
    /// How often a sponsored group repeats "premium here was opened by @X".
    /// Under every single answer it turns into noise; once an hour it still
    /// reads as the sponsor's standing credit.
    static let sponsorCreditCooldown: TimeInterval = 60 * 60

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
    /// Explorer scan positions, `"<asset>:<address>"` → unix seconds.
    private var _explorerCursors: [String: Int] = [:]
    private var _pendingCryptoPriceInputs: [ChatKey: Int] = [:]
    private var _pendingCryptoAddressInputs: [ChatKey: (menuMessageID: Int, chain: CryptoChain)] = [:]
    private var _pendingCryptoPoolAddInputs: [ChatKey: (menuMessageID: Int, chain: CryptoChain)] = [:]

    private var _simulatedRoles: [String: SimulatedRole] = [:]

    private var _pendingAdminInputs: [ChatKey: AdminPendingInput] = [:]

    /// Who armed the chat's current "waiting for a value" state. The waits
    /// themselves are keyed by chat (the menu message they belong to lives
    /// there), but in a group the next message can come from anyone.
    private var _pendingInputOwners: [ChatKey: String] = [:]

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
        // The directory is empty here, so the owner starts as a pending key and
        // is re-filed under `#<userID>` the first time they talk to the bot.
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

    // MARK: - User identity (UserKey ↔ @username)

    /// Storage key for a person named by @username. `#<userID>` once we have
    /// met them, the bare username while they are only a pending reference.
    func userKey(username: String?) -> String? {
        guard let pending = UserKey.pending(username) else { return nil }
        if let userID = userDirectoryValue.userID(forUsername: pending) {
            return UserKey.forUserID(userID)
        }
        return pending
    }

    /// Storage key for a person we have in front of us — always identified.
    nonisolated func userKey(userID: Int) -> String { UserKey.forUserID(userID) }

    /// Variant for call sites that already hold a non-optional username; a
    /// blank one can only key itself, which no real record ever uses.
    func userKeyOrRaw(_ username: String) -> String {
        userKey(username: username) ?? username.lowercased()
    }

    /// Every key a person's records could sit under, most authoritative first:
    /// their permanent `#<userID>`, then anything still pending under the
    /// username they are using. A userID alone is enough — which is what lets
    /// someone with no @username at all own a subscription and a wallet.
    func userKeys(username: String?, userID: Int?) -> [String] {
        var keys: [String] = []
        if let userID { keys.append(UserKey.forUserID(userID)) }
        if let resolved = userKey(username: username), !keys.contains(resolved) {
            keys.append(resolved)
        }
        return keys
    }

    /// Key of the bot's own owner. Resolved every time, because the owner gets
    /// re-filed under `#<userID>` the first time they talk to the bot.
    var defaultOwnerKey: String { rootSuperAdminKey }

    /// Key of the bootstrap super-admin (who is also the default owner). Pinned
    /// in the directory the first time they are seen, so root survives them
    /// changing the @username the bot was configured with.
    var rootSuperAdminKey: String {
        userDirectoryValue.rootKey ?? userKey(username: rootSuperAdminUsername) ?? rootSuperAdminUsername
    }

    /// Label for a stored key: `@username` when known, otherwise the person's
    /// name or `id <n>`. Every interface string that names a stored user goes
    /// through this — the raw `#<userID>` key is never shown.
    func displayLabel(forKey key: String) -> String {
        userDirectoryValue.displayLabel(forKey: key)
    }

    func displayLabels(forKeys keys: [String]) -> [String] {
        keys.map { userDirectoryValue.displayLabel(forKey: $0) }
    }

    /// Bare @username (no `@`) behind a key, where a username is needed as data
    /// rather than as a label — deep links, wallet notices. nil when the person
    /// never set one.
    func username(forKey key: String) -> String? {
        userDirectoryValue.username(forKey: key)
    }

    /// Records a sighting of a user and keeps their state rename-proof.
    ///
    /// Called for every update the bot handles. On a first sighting anything
    /// still filed under their bare username is re-filed under `#<userID>`; on
    /// a rename the stored display names are refreshed. After this, the
    /// person's username can change freely — no state is attached to it.
    func identifyUser(userID: Int, username: String?, firstName: String? = nil) {
        let outcome = userDirectoryValue.record(userID: userID, username: username, firstName: firstName)
        // A moved `seenAt` is worth persisting on its own (throttled inside the
        // directory): the wallet win-back sweep and the retention proxy both
        // read it, and if it only ever reached the database as a side effect of
        // somebody else's rename it would roll back to a stale value on restart
        // — and an active person would be told «давно вас не было».
        if outcome.seenAtAdvanced { dirtyConfigs.insert(.userDirectory) }
        guard outcome.changed else { return }
        dirtyConfigs.insert(.userDirectory)

        let key = UserKey.forUserID(userID)
        // Claim whatever is still filed under a bare username this person now
        // demonstrably owns: the one they just used, and the one they used to
        // have (a record could have been created for either).
        var pendingKeys: [String] = []
        if let current = UserKey.pending(username) { pendingKeys.append(current) }
        if let previous = outcome.previousUsername { pendingKeys.append(previous) }
        // Pin the owner the first time they show up: from here on root is an
        // account, not a handle.
        if userDirectoryValue.rootKey == nil, pendingKeys.contains(rootSuperAdminUsername.lowercased()) {
            userDirectoryValue.rootKey = key
        }
        for pending in Set(pendingKeys) where pending != key {
            adoptRecords(from: pending, to: key)
        }
        refreshDisplayNames(forKey: key)
        userDirectoryValue.prune(protectedKeys: keysHoldingState())
    }

    /// Every `UserKey` some state is currently filed under — the set the
    /// directory must never forget, however long ago that person was seen.
    private func keysHoldingState() -> Set<String> {
        var keys = Set(tenants.keys)
        keys.formUnion(userBalances.keys)
        keys.formUnion(chatOwnership.values)
        keys.formUnion(superAdminUsernames)
        keys.formUnion(inviteRecords.values.map(\.ownerUsername))
        for tenant in tenants.values {
            keys.formUnion(tenant.licensedUsernames)
            keys.formUnion(tenant.adminUsernames)
        }
        for record in referralLedgerValue.records.values {
            keys.insert(UserKey.forUserID(record.inviterUserID))
        }
        // Tallies outlive the records they were built from (records are pruned,
        // aggregates are not), so an inviter with no live record still holds
        // state — their reward cap and client count hang off this key.
        for tally in referralLedgerValue.tallies.keys {
            guard let userID = Int(tally) else { continue }
            keys.insert(UserKey.forUserID(userID))
        }
        // An open crypto invoice is money in flight: lose the identity and
        // `openCryptoInvoiceForUser` stops finding it.
        keys.formUnion(_cryptoInvoices.values.map(\.username))
        keys.formUnion(_simulatedRoles.keys)
        keys.formUnion(userTenantMap.values)
        return keys
    }

    /// Moves every user-keyed record from a pending username key to the
    /// person's permanent key. Nothing is merged into an existing identified
    /// record — the identified one is the truth, the pending one is dropped.
    private func adoptRecords(from pending: String, to key: String) {
        if let tenant = tenants.removeValue(forKey: pending) {
            dirtyTenants.remove(pending)
            deletedTenants.insert(pending)
            if tenants[key] == nil {
                var moved = tenant
                moved.ownerUsername = key
                tenants[key] = moved
                deletedTenants.remove(key)
                dirtyTenants.insert(key)
            }
        }
        if let wallet = userBalances.removeValue(forKey: pending) {
            if var existing = userBalances[key] {
                // Both buckets can only coexist if the pending one was topped
                // up before we ever saw this person: fold it in, losing nothing.
                existing.balanceUsd += wallet.balanceUsd
                existing.spentBilledUsd += wallet.spentBilledUsd
                existing.spentRealUsd += wallet.spentRealUsd
                // `toppedUpUsd` is the only proof this person ever paid real
                // money (§7 «Возврат по балансу»); dropping it on a merge would
                // quietly turn a client back into a stranger. `lapsedNoticeAt`
                // must survive too, or the lapsed-wallet offer is sent twice.
                existing.toppedUpUsd += wallet.toppedUpUsd
                existing.lapsedNoticeAt = [existing.lapsedNoticeAt, wallet.lapsedNoticeAt].compactMap { $0 }.max()
                existing.updatedAt = [existing.updatedAt, wallet.updatedAt].compactMap { $0 }.max()
                userBalances[key] = existing
            } else {
                userBalances[key] = wallet
            }
            dirtyConfigs.insert(.balances)
        }
        for (chatID, owner) in chatOwnership where owner == pending {
            chatOwnership[chatID] = key
            dirtyOwnership.insert(chatID)
        }
        for (mappedUserID, owner) in userTenantMap where owner == pending {
            userTenantMap[mappedUserID] = key
        }
        if superAdminUsernames.remove(pending) != nil {
            superAdminUsernames.insert(key)
            dirtyConfigs.insert(.superAdmins)
        }
        for (owner, tenant) in tenants {
            var updated = tenant
            var touched = false
            if updated.licensedUsernames.remove(pending) != nil {
                updated.licensedUsernames.insert(key)
                touched = true
            }
            if updated.adminUsernames.remove(pending) != nil {
                updated.adminUsernames.insert(key)
                touched = true
            }
            if touched {
                tenants[owner] = updated
                dirtyTenants.insert(owner)
            }
        }
        for (token, record) in inviteRecords where record.ownerUsername == pending {
            inviteRecords[token] = InviteRecord(ownerUsername: key, createdAt: record.createdAt)
            dirtyConfigs.insert(.invites)
        }
        if let role = _simulatedRoles.removeValue(forKey: pending) {
            _simulatedRoles[key] = role
        }
        for (invoiceID, invoice) in _cryptoInvoices where invoice.username == pending {
            var moved = invoice
            moved.username = key
            _cryptoInvoices[invoiceID] = moved
            dirtyConfigs.insert(.crypto)
        }
    }

    /// Keeps denormalized display names in step with the directory, so lists
    /// rendered from stored records show the person's current @username.
    private func refreshDisplayNames(forKey key: String) {
        let label = userDirectoryValue.username(forKey: key)
        guard let label else { return }
        var ledger = referralLedgerValue
        var ledgerTouched = false
        if let userID = UserKey.userID(from: key) {
            if var tally = ledger.tallies[String(userID)], tally.username != label {
                tally.username = label
                ledger.tallies[String(userID)] = tally
                ledgerTouched = true
            }
            if var record = ledger.records[String(userID)], record.invitedUsername != label {
                record.invitedUsername = label
                ledger.records[String(userID)] = record
                ledgerTouched = true
            }
            for (invitedID, var record) in ledger.records where record.inviterUserID == userID {
                if record.inviterUsername != label {
                    record.inviterUsername = label
                    ledger.records[invitedID] = record
                    ledgerTouched = true
                }
            }
        }
        if ledgerTouched {
            referralLedgerValue = ledger
            dirtyConfigs.insert(.referralLedger)
        }
    }

    // MARK: - Tenant routing helpers

    private func tenantState(for chatID: Int) -> TenantState {
        let owner = chatOwnership[chatID] ?? defaultOwnerKey
        if let tenant = tenants[owner] { return tenant }
        if let fallback = tenants[defaultOwnerKey] { return fallback }
        // The owner row is seeded in init and re-filed (never dropped) by
        // identifyUser; rebuild it rather than trap if it ever goes missing.
        let seeded = TenantState(
            ownerUsername: defaultOwnerKey,
            defaultModel: initialDefaultModel,
            defaultRole: initialDefaultRole,
            defaultHistoryLength: initialDefaultHistoryLength,
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
        tenants[defaultOwnerKey] = seeded
        dirtyTenants.insert(defaultOwnerKey)
        return seeded
    }

    private func mutateTenant(for chatID: Int, _ block: (inout TenantState) -> Void) {
        let owner = chatOwnership[chatID] ?? defaultOwnerKey
        guard var tenant = tenants[owner] else { return }
        block(&tenant)
        tenants[owner] = tenant
        dirtyTenants.insert(owner)
    }

    private func mutateTenantByOwner(_ ownerUsername: String, _ block: (inout TenantState) -> Void) {
        guard let u = userKey(username: ownerUsername), var tenant = tenants[u] else { return }
        block(&tenant)
        tenants[u] = tenant
        dirtyTenants.insert(u)
    }

    /// Same as `mutateTenantByOwner` but for a caller that already holds a key.
    private func mutateTenantByKey(_ key: String, _ block: (inout TenantState) -> Void) {
        guard var tenant = tenants[key] else { return }
        block(&tenant)
        tenants[key] = tenant
        dirtyTenants.insert(key)
    }

    // MARK: - Tenant management

    /// Registers a tenant without a subscription term (unlimited) — the
    /// super-admin manual path. Paid activations go through
    /// `activatePaidSubscription`.
    func registerTenant(username: String) {
        let u = userKeyOrRaw(username)
        guard tenants[u] == nil else { return }
        let defaults = tenants[defaultOwnerKey]
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
        let u = userKeyOrRaw(username)
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
        tenants[userKeyOrRaw(ownerUsername)]?.isActive ?? false
    }

    func tenantSubscription(ownerUsername: String) -> (exists: Bool, paidUntil: Date?, isActive: Bool) {
        guard let tenant = tenants[userKeyOrRaw(ownerUsername)] else {
            return (false, nil, false)
        }
        return (true, tenant.paidUntil, tenant.isActive)
    }

    /// Super-admin: extend by N days (from max(now, current end)).
    @discardableResult
    func extendTenantSubscription(username: String, days: Int) -> Date? {
        let u = userKeyOrRaw(username)
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
        let u = userKeyOrRaw(username)
        guard var tenant = tenants[u] else { return false }
        tenant.paidUntil = nil
        tenants[u] = tenant
        dirtyTenants.insert(u)
        return true
    }

    /// Super-admin: expire the subscription immediately.
    @discardableResult
    func expireTenantSubscription(username: String) -> Bool {
        let u = userKeyOrRaw(username)
        guard u != defaultOwnerKey, var tenant = tenants[u] else { return false }
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
        guard let u = userKey(username: username) else { return false }
        return tenants[u]?.remindersOptOut ?? false
    }

    /// Per-sponsor opt-out (toggle in their own admin panel).
    @discardableResult
    func setRemindersOptOut(username: String, optOut: Bool) -> Bool {
        let u = userKeyOrRaw(username)
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
        // Super-admins own the bot rather than buy from it; selling the owner a
        // winback offer for their own product is noise, and the funnel already
        // leaves them out of the sponsor tallies.
        for (owner, tenant) in tenants where !superAdminUsernames.contains(owner) {
            guard let paidUntil = tenant.paidUntil, !tenant.remindersOptOut else { continue }
            // Flags belong to one cycle; a renewal invalidates them.
            let sent = tenant.noticeCycleUntil == paidUntil ? tenant.sentNotices : []
            guard let notice = config.dueNotice(paidUntil: paidUntil, alreadySent: sent, now: now) else {
                continue
            }
            targets.append(SubscriptionNoticeTarget(
                username: owner,
                label: displayLabel(forKey: owner),
                notice: notice,
                paidUntil: paidUntil,
                privateChatID: privateChatID(forKey: owner),
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
        let u = userKeyOrRaw(username)
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
        let u = userKeyOrRaw(username)
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
        guard let u = userKey(username: username), let discount = tenants[u]?.winbackDiscount else { return nil }
        return discount.isActive(now: now, grace: grace) ? discount : nil
    }

    /// Clears the offer after a purchase (one-shot). Returns it when it was
    /// still valid, so the caller can count the winback conversion.
    @discardableResult
    func consumeWinbackDiscount(username: String) -> SubscriptionDiscount? {
        let u = userKeyOrRaw(username)
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
    ///
    /// - Parameter applying: use this discount instead of the stored one.
    ///   Nothing is granted or consumed — it exists so the super-admin preview
    ///   quotes the same numbers on every payment method a real offer would,
    ///   card included.
    func subscriptionPricing(
        username: String?,
        grace: TimeInterval = 0,
        now: Date = Date(),
        applying: SubscriptionDiscount? = nil
    ) -> SubscriptionPricing {
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
        guard let discount = applying ?? subscriptionDiscount(username: username, grace: grace, now: now) else {
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

    /// The person's DM with the bot, if they ever wrote to it (Telegram forbids
    /// bot-initiated conversations, so this is the only way to reach them
    /// personally).
    ///
    /// For an identified user this is exact: a Telegram private chat's ID *is*
    /// the user's ID. Only a pending record still has to be matched by the
    /// username we were told about.
    ///
    /// A DM the person blocked (`my_chat_member` → kicked) is not a channel:
    /// every send there fails with 403, so returning it would make the sweep
    /// retry the same dead address on every pass.
    func privateChatID(forKey key: String) -> Int? {
        if let userID = UserKey.userID(from: key) {
            guard let meta = chatMetaByID[userID], meta.type == "private", meta.botRemoved != true else { return nil }
            return userID
        }
        for (chatID, meta) in chatMetaByID
        where chatID > 0 && meta.type == "private"
            && meta.botRemoved != true
            && meta.username?.lowercased() == key {
            return chatID
        }
        return nil
    }

    /// Group chats the owner's licence covers *and* the bot can still post to.
    /// A chat it was kicked out of stays owned (re-adding restores it) but is
    /// not a delivery channel, so broadcasts skip it instead of burning a send.
    func ownedGroupChatIDs(owner: String) -> [Int] {
        let u = userKeyOrRaw(owner)
        return chatOwnership
            .filter { $0.key < 0 && $0.value == u && chatMetaByID[$0.key]?.botRemoved != true }
            .map(\.key)
            .sorted()
    }

    /// Monitoring snapshot for the super-admin reminders page: who is about to
    /// lapse, who just did, who carries a live offer, who can't be reached.
    func subscriptionLifecycleStats(now: Date = Date()) -> SubscriptionLifecycleStats {
        let config = reminderConfigValue
        let lead = Double(max(config.daysBeforeExpiry, 1)) * 86_400
        let winbackHorizon = Double((config.winbackDays.max() ?? 7)) * 86_400 + config.winbackCatchUpWindow
        var stats = SubscriptionLifecycleStats()
        // Same population the sweep works on — a page that lists people the
        // sweep will never contact reads as a bug report.
        for (owner, tenant) in tenants where !superAdminUsernames.contains(owner) {
            guard let paidUntil = tenant.paidUntil else { continue }
            stats.sponsors += 1
            let reachable = privateChatID(forKey: owner) != nil || !ownedGroupChatIDs(owner: owner).isEmpty
            if !reachable { stats.unreachable += 1 }
            if tenant.remindersOptOut { stats.optedOut += 1 }
            let row = SubscriptionLifecycleStats.Row(
                username: owner,
                label: displayLabel(forKey: owner),
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
                stats.activeDiscounts.append((label: displayLabel(forKey: owner), discount: discount))
            }
        }
        stats.expiringSoon.sort { $0.paidUntil < $1.paidUntil }
        stats.recentlyExpired.sort { $0.paidUntil > $1.paidUntil }
        stats.activeDiscounts.sort { $0.label < $1.label }
        return stats
    }

    @discardableResult
    func removeTenant(username: String) -> Bool {
        let u = userKeyOrRaw(username)
        guard u != defaultOwnerKey, tenants[u] != nil else { return false }
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

    func listTenants() -> [(key: String, label: String)] {
        tenants.keys
            .map { (key: $0, label: displayLabel(forKey: $0)) }
            .sorted { $0.label < $1.label }
    }

    func isTenant(username: String) -> Bool {
        tenants[userKeyOrRaw(username)] != nil
    }

    /// Storage key of whoever opened premium in this chat.
    func chatOwner(chatID: Int) -> String? {
        chatOwnership[chatID]
    }

    /// Same, ready to print: `@username` / name / `id <n>`.
    func chatOwnerLabel(chatID: Int) -> String? {
        chatOwnership[chatID].map { displayLabel(forKey: $0) }
    }

    func effectiveOwnerUsername(chatID: Int) -> String {
        chatOwnership[chatID] ?? defaultOwnerKey
    }

    @discardableResult
    func assignChat(chatID: Int, to ownerUsername: String) -> Bool {
        let u = userKeyOrRaw(ownerUsername)
        guard tenants[u] != nil else { return false }
        chatOwnership[chatID] = u
        dirtyOwnership.insert(chatID)
        deletedOwnership.remove(chatID)
        return true
    }

    /// What a payment did with the chat it was made in.
    enum ChatClaimOutcome: Sendable {
        case assigned
        /// The payer has no tenant record (should not happen after activation).
        case unknownTenant
        /// A live subscription of someone else already pays for this group, so
        /// the chat stays with them.
        case keptSponsor(label: String)
    }

    /// Attaches the chat a payment was made in to the payer — but never takes a
    /// group away from a sponsor whose subscription is still running.
    ///
    /// Buying premium inside someone else's group used to overwrite ownership
    /// silently: the sponsor lost the chat from their list, from `ownedGroupChatIDs`
    /// (so renewal reminders stopped mentioning it) and from the "premium opened
    /// by @X" credit — while still paying for it. Private chats are unaffected:
    /// the payer's own DM always follows the payer.
    func claimChatForPayment(chatID: Int, payerKey: String) -> ChatClaimOutcome {
        let key = userKeyOrRaw(payerKey)
        guard tenants[key] != nil else { return .unknownTenant }
        if chatID < 0,
           let current = chatOwnership[chatID],
           current != key,
           tenants[current]?.isActive == true {
            return .keptSponsor(label: displayLabel(forKey: current))
        }
        chatOwnership[chatID] = key
        dirtyOwnership.insert(chatID)
        deletedOwnership.remove(chatID)
        return .assigned
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
        let u = userKeyOrRaw(ownerUsername)
        return chatOwnership.compactMap { $0.value == u ? $0.key : nil }
    }

    func autoAssignIfNeeded(chatID: Int, senderUsername: String?, senderUserID: Int?) {
        guard chatOwnership[chatID] == nil else { return }
        let lowered = userKey(username: senderUsername)
        // A super-admin simulating a regular user must be able to keep a chat
        // unowned (after /tenant release) to test ads and balance billing —
        // otherwise their own tenant would instantly re-claim it here.
        if let u = lowered, superAdminUsernames.contains(u), _simulatedRoles[u] != nil {
            return
        }
        if let userID = senderUserID, tenants[UserKey.forUserID(userID)] != nil {
            // Their own subscription — works even without a @username.
            chatOwnership[chatID] = UserKey.forUserID(userID)
        } else if let username = lowered, tenants[username] != nil {
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
        guard let u = userKey(username: username) else { return false }
        guard superAdminUsernames.contains(u) else { return false }
        return _simulatedRoles[u] == nil
    }

    /// Raw super-admin check that ignores any active simulation. Use only for
    /// gating commands that must remain reachable while a simulation is active
    /// (e.g. `/simulate` itself).
    func isActuallySuperAdmin(username: String?) -> Bool {
        guard let u = userKey(username: username) else { return false }
        return superAdminUsernames.contains(u)
    }

    /// True only for the immutable bootstrap super-admin (default @maythe4th).
    /// Only this user may add or remove other super-admins.
    func isRootSuperAdmin(username: String?) -> Bool {
        guard let u = userKey(username: username) else { return false }
        return u == rootSuperAdminKey
    }

    /// Super-admins as (key, label) — the interface prints labels, the callers
    /// that act on one pass the key back.
    func listSuperAdmins() -> [(key: String, label: String)] {
        superAdminUsernames
            .map { (key: $0, label: displayLabel(forKey: $0)) }
            .sorted { $0.label < $1.label }
    }

    @discardableResult
    func addSuperAdmin(target: String) -> Bool {
        let u = userKeyOrRaw(target)
        guard !u.isEmpty else { return false }
        let inserted = superAdminUsernames.insert(u).inserted
        if inserted { dirtyConfigs.insert(.superAdmins) }
        return inserted
    }

    @discardableResult
    func removeSuperAdmin(target: String) -> Bool {
        let u = userKeyOrRaw(target)
        guard u != rootSuperAdminKey else { return false }
        let removed = superAdminUsernames.remove(u) != nil
        if removed { dirtyConfigs.insert(.superAdmins) }
        return removed
    }

    func simulatedRole(username: String?) -> SimulatedRole? {
        guard let u = userKey(username: username) else { return nil }
        guard superAdminUsernames.contains(u) else { return nil }
        return _simulatedRoles[u]
    }

    @discardableResult
    func setSimulatedRole(username: String, role: SimulatedRole?) -> Bool {
        let u = userKeyOrRaw(username)
        guard superAdminUsernames.contains(u) else { return false }
        if let role {
            _simulatedRoles[u] = role
        } else {
            _simulatedRoles.removeValue(forKey: u)
        }
        return true
    }

    func isTenantOwner(username: String?, chatID: Int) -> Bool {
        guard let u = userKey(username: username) else { return false }
        if superAdminUsernames.contains(u) {
            if _simulatedRoles[u] != nil { return false }
            return true
        }
        return effectiveOwnerUsername(chatID: chatID) == u
    }

    func isAdmin(username: String?, chatID: Int) -> Bool {
        guard let u = userKey(username: username) else { return false }
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
        let u = userKeyOrRaw(username)
        mutateTenant(for: chatID) { $0.adminUsernames.insert(u) }
    }

    func removeAdmin(username: String, chatID: Int) {
        let u = userKeyOrRaw(username)
        mutateTenant(for: chatID) { $0.adminUsernames.remove(u) }
    }

    func listAdmins(chatID: Int) -> [(key: String, label: String)] {
        tenantState(for: chatID).adminUsernames
            .map { (key: $0, label: displayLabel(forKey: $0)) }
            .sorted { $0.label < $1.label }
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
            // An explicit choice supersedes the cap fallback: nothing left to
            // restore later (roadmap step 6).
            context.downgradedFromModel = nil
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

    /// Returns true when the charge for this answer emptied the payer's wallet
    /// (see `chargeBalance`) — the coordinator pitches a top-up right there.
    @discardableResult
    func appendAssistant(
        chatKey: ChatKey,
        generationID: GenerationID,
        content: String,
        usage: StreamUsageSummary? = nil,
        billedTo: String? = nil
    ) -> Bool {
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
            return chargeBalance(username: billedTo, billedUsd: billed, realUsd: real)
        }
        return false
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
        _starsPerUsd = max(0, rate)
        dirtyConfigs.insert(.starsPerUsd)
    }

    /// Whether credit packs may be sold for Stars. Deliberately independent of
    /// `starsPrice` (the *subscription* price): turning subscriptions off must
    /// not silently kill the cheapest entry point (roadmap step 2). 0 = off.
    func starsCreditsEnabled() -> Bool { _starsPerUsd > 0 }

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

    /// The fallback model, deterministically. `Set.first` is arbitrary and
    /// changes between runs and even between mutations — a chat dropped to the
    /// free tier would land on a different model every time, so answer quality
    /// would swing for no visible reason and the super-admin could not choose
    /// the backup. Pinned models win in the order they were pinned.
    func firstFreeModel() -> String? {
        if let pinned = _freeModelIDs.first { return pinned }
        return effectiveFreeModelIDs()?.sorted().first
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

    /// FX rate used to price credit packs on the card (roadmap step 2).
    func setCardUsdRateMinorUnits(_ value: Int?) {
        _cardConfig.usdRateMinorUnits = value.flatMap { $0 > 0 ? $0 : nil }
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
        let u = userKeyOrRaw(username)
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

    // MARK: - Explorer cursors

    static func explorerCursorKey(asset: CryptoAsset, address: String) -> String {
        "\(asset.rawValue):\(address.lowercased())"
    }

    /// Where the blockchain scan stopped last time, per asset+address. Survives
    /// restarts on purpose: seeded at "now", every transfer that arrived during
    /// a redeploy would fall outside every future scan — the money lands, the
    /// invoice expires, and nothing in the logs says why.
    func explorerCursors() -> [String: Int] { _explorerCursors }

    /// Only ever moves forward — an out-of-order or stale write must not reopen
    /// an already scanned range (harmless but wasteful) or, worse, rewind past
    /// transfers that were already credited.
    func advanceExplorerCursor(asset: CryptoAsset, address: String, unix: Int) {
        let key = Self.explorerCursorKey(asset: asset, address: address)
        guard unix > (_explorerCursors[key] ?? 0) else { return }
        _explorerCursors[key] = unix
        dirtyConfigs.insert(.crypto)
    }

    /// Drops cursors for addresses that are no longer polled (address changed,
    /// pool entry removed), so the row does not accumulate dead keys forever.
    func pruneExplorerCursors(keeping keys: Set<String>) {
        guard _explorerCursors.contains(where: { !keys.contains($0.key) }) else { return }
        _explorerCursors = _explorerCursors.filter { keys.contains($0.key) }
        dirtyConfigs.insert(.crypto)
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

    // MARK: - Pending input ownership

    /// Is this chat waiting for a typed value of any kind?
    func hasAnyPendingInput(chatKey: ChatKey) -> Bool {
        _pendingInputs[chatKey] != nil
            || _pendingStarsPriceInputs[chatKey] != nil
            || _pendingStarsPerUsdInputs[chatKey] != nil
            || _pendingFreeModelInputs[chatKey] != nil
            || _pendingCryptoPriceInputs[chatKey] != nil
            || _pendingCryptoAddressInputs[chatKey] != nil
            || _pendingCryptoPoolAddInputs[chatKey] != nil
            || _pendingAdminInputs[chatKey] != nil
    }

    /// Remembers who a live wait belongs to; forgets it once nothing is pending.
    /// Called after every menu action, so a new wait always carries its owner
    /// and a consumed one leaves nothing behind.
    func notePendingInputOwner(_ userKey: String?, chatKey: ChatKey) {
        guard hasAnyPendingInput(chatKey: chatKey) else {
            _pendingInputOwners.removeValue(forKey: chatKey)
            return
        }
        guard let userKey else { return }
        _pendingInputOwners[chatKey] = userKey
    }

    /// Owner of the chat's live wait, or nil when nothing is pending (a stale
    /// entry left by a consumed wait is dropped here rather than lingering).
    func pendingInputOwner(chatKey: ChatKey) -> String? {
        guard hasAnyPendingInput(chatKey: chatKey) else {
            _pendingInputOwners.removeValue(forKey: chatKey)
            return nil
        }
        return _pendingInputOwners[chatKey]
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
            addressPools: pools.isEmpty ? nil : pools,
            explorerCursors: _explorerCursors.isEmpty ? nil : _explorerCursors
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
        _explorerCursors = snapshot?.explorerCursors ?? [:]
    }

    func superAdminPrivateChats() -> [ChatKey] {
        contexts.keys.filter { $0.chatID > 0 && chatOwnership[$0.chatID] == defaultOwnerKey }.map { $0 }
    }

    /// Why this chat does (or doesn't) have smart models right now. Same order
    /// of precedence as `hasSubscriptionCoverage`/`hasFullModelAccess`, but it
    /// reports *who* is paying — so the menu and the purchase page can credit
    /// the sponsor (roadmap step 3) instead of selling to someone who is
    /// already covered.
    func chatAccessStatus(chatID: Int, username: String?, userID: Int? = nil) -> ChatAccessStatus {
        let candidates = userKeys(username: username, userID: userID)
        let simulated = candidates.contains { superAdminUsernames.contains($0) && _simulatedRoles[$0] != nil }

        if !simulated {
            for u in candidates {
                if let own = tenants[u], own.isActive {
                    return .ownSubscription(until: own.paidUntil)
                }
            }
            for (owner, tenant) in tenants where tenant.isActive
                && !tenant.licensedUsernames.isDisjoint(with: candidates) {
                return .guest(displayLabel(forKey: owner))
            }
        }
        if let owner = chatOwnership[chatID], tenants[owner]?.isActive == true {
            return .sponsored(displayLabel(forKey: owner))
        }
        if let userID {
            let tenant = tenantState(for: chatID)
            if tenant.whitelistedUserIDs.contains(userID), tenant.isActive {
                return .guest(displayLabel(forKey: tenant.ownerUsername))
            }
        }
        for u in candidates {
            if let wallet = userBalances[u], wallet.balanceUsd > 0 {
                return .balance(wallet.balanceUsd)
            }
        }
        return .free
    }

    /// Subscription/licence coverage only — the generation is paid by a
    /// tenant's subscription, not by the sender's personal balance.
    func hasSubscriptionCoverage(username: String?, userID: Int? = nil, chatID: Int? = nil) -> Bool {
        let candidates = userKeys(username: username, userID: userID)
        let simulated = candidates.contains { superAdminUsernames.contains($0) && _simulatedRoles[$0] != nil }

        // Every path below requires the granting tenant's subscription to be
        // active: an expired admin keeps their panel (to renew) but their
        // chats and users fall back to free models.
        if !simulated {
            for u in candidates where tenants[u]?.isActive == true { return true }
            for tenant in tenants.values where tenant.isActive
                && !tenant.licensedUsernames.isDisjoint(with: candidates) {
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
        if let asker = userKey(username: askerUsername), asker == owner {
            return nil
        }
        return displayLabel(forKey: owner)
    }

    /// Same as `chatSponsor`, but rate-limited: the credit line under answers
    /// repeats at most once per `sponsorCreditCooldown` per chat. Consuming the
    /// slot here (rather than in the caller) keeps two parallel generations in
    /// one chat from both printing it.
    func chatSponsorForCredit(chatID: Int, askerUsername: String?, now: Date = Date()) -> String? {
        guard let sponsor = chatSponsor(chatID: chatID, askerUsername: askerUsername) else { return nil }
        if let last = _sponsorCreditShownAt[chatID], now.timeIntervalSince(last) < Self.sponsorCreditCooldown {
            return nil
        }
        _sponsorCreditShownAt[chatID] = now
        if _sponsorCreditShownAt.count > 512 {
            _sponsorCreditShownAt = _sponsorCreditShownAt.filter { now.timeIntervalSince($0.value) < Self.sponsorCreditCooldown }
        }
        return sponsor
    }

    /// Paid-model access: subscription coverage OR a positive personal
    /// balance. The balance path deliberately ignores role simulation so the
    /// super-admin can test pay-as-you-go end to end.
    func hasFullModelAccess(username: String?, userID: Int? = nil, chatID: Int? = nil) -> Bool {
        if hasSubscriptionCoverage(username: username, userID: userID, chatID: chatID) {
            return true
        }
        // A wallet belongs to a person, not to a handle: the userID alone is
        // enough, so someone with no @username still spends their balance.
        return userKeys(username: username, userID: userID)
            .contains { (userBalances[$0]?.balanceUsd ?? 0) > 0 }
    }

    // MARK: - Daily premium "taste" (free-tier)

    enum DailyPremiumDecision: Sendable {
        /// One unit was consumed; the paid model may answer this turn.
        /// `remaining` counts what is left *after* this turn — 0 means the pain
        /// point is one message away, which is worth saying out loud.
        case allowed(remaining: Int, limit: Int)
        /// Today's allowance is spent; caller should fall back to free + upsell.
        /// `limit == 0` means the free premium taste is switched off entirely —
        /// a different message, not "you used 0 of 0".
        case exhausted(limit: Int)
    }

    /// Counter key: a group shares one allowance (social pressure — "кто-нибудь
    /// откройте премиум"), a private chat counts per person.
    private func dailyPremiumKey(chatID: Int, userID: Int?, isGroup: Bool) -> String {
        isGroup ? "c\(chatID)" : "u\(userID ?? chatID)"
    }

    /// Drops entries from previous days. Called on every write, so the row
    /// tracks "free chats active today" rather than growing forever.
    private func pruneDailyPremiumUsage(today: Int) {
        guard premiumDailyUsage.contains(where: { $0.value.day != today }) else { return }
        premiumDailyUsage = premiumDailyUsage.filter { $0.value.day == today }
    }

    /// Consumes one unit of today's free premium allowance for a free-tier
    /// chat/user and reports whether a paid-model answer is allowed. Counter
    /// resets at the UTC day boundary. `.exhausted` does not consume a unit.
    func consumeDailyPremium(chatID: Int, userID: Int?, isGroup: Bool) -> DailyPremiumDecision {
        let limit = dailyPremiumLimitValue
        guard limit > 0 else { return .exhausted(limit: limit) }
        let key = dailyPremiumKey(chatID: chatID, userID: userID, isGroup: isGroup)
        let today = FunnelDailyLog.dayNumber()
        var entry = premiumDailyUsage[key] ?? DailyPremiumUsage(day: today, used: 0)
        if entry.day != today { entry = DailyPremiumUsage(day: today, used: 0) }
        guard entry.used < limit else { return .exhausted(limit: limit) }
        entry.used += 1
        premiumDailyUsage[key] = entry
        pruneDailyPremiumUsage(today: today)
        dirtyConfigs.insert(.dailyPremiumUsage)
        return .allowed(remaining: max(0, limit - entry.used), limit: limit)
    }

    /// Gives a consumed unit back when the turn produced no answer (provider
    /// error, cancellation, empty reply). Without this a failed generation
    /// silently costs a free user one of their few smart answers of the day.
    func refundDailyPremium(chatID: Int, userID: Int?, isGroup: Bool) {
        let key = dailyPremiumKey(chatID: chatID, userID: userID, isGroup: isGroup)
        let today = FunnelDailyLog.dayNumber()
        guard var entry = premiumDailyUsage[key], entry.day == today, entry.used > 0 else { return }
        entry.used -= 1
        premiumDailyUsage[key] = entry
        dirtyConfigs.insert(.dailyPremiumUsage)
    }

    /// Read-only view for the menu: how much of today's taste is left.
    func remainingDailyPremium(chatID: Int, userID: Int?, isGroup: Bool) -> (remaining: Int, limit: Int) {
        let limit = dailyPremiumLimitValue
        guard limit > 0 else { return (0, 0) }
        let key = dailyPremiumKey(chatID: chatID, userID: userID, isGroup: isGroup)
        let entry = premiumDailyUsage[key]
        let used = (entry?.day == FunnelDailyLog.dayNumber()) ? (entry?.used ?? 0) : 0
        return (max(0, limit - used), limit)
    }

    /// May this person point the chat at a paid model right now?
    enum PaidModelAccess: Sendable {
        /// Subscription, sponsor or a positive balance — no daily ceiling.
        case full
        /// Free tier with today's premium taste still unspent.
        case dailyTaste(remaining: Int, limit: Int)
        /// Free tier, allowance spent (or switched off) — only free models.
        case none
    }

    /// Paid-model gate for the pickers (`/model`, menu). Full access aside, a
    /// free-tier chat with units left today must be able to *choose* a smart
    /// model: otherwise the daily taste is reachable only by chats that happened
    /// to have a paid model set before the cap parked it, and nobody can opt in.
    func paidModelAccess(username: String?, userID: Int?, chatID: Int) -> PaidModelAccess {
        if hasFullModelAccess(username: username, userID: userID, chatID: chatID) { return .full }
        let left = remainingDailyPremium(chatID: chatID, userID: userID, isGroup: chatID < 0)
        return left.remaining > 0 ? .dailyTaste(remaining: left.remaining, limit: left.limit) : .none
    }

    // MARK: - Funnel analytics (roadmap step 7)

    /// Records one funnel event. Persisted (dirties GlobalConfigKey.funnel) both
    /// as an all-time total and in today's bucket.
    func bumpFunnel(_ event: FunnelEvent, by amount: Int = 1) {
        bumpFunnelCounter(key: event.rawValue, by: amount)
    }

    /// Counts a purchase-page open together with the surface it came from, so
    /// the pain-point upsells can be compared with the plain menu button.
    func bumpPurchaseOpen(source: PurchaseSource) {
        bumpFunnelCounter(key: FunnelEvent.openPurchase.rawValue)
        bumpFunnelCounter(key: source.counterKey)
    }

    private func bumpFunnelCounter(key: String, by amount: Int = 1) {
        funnelCounters[key, default: 0] += amount
        dirtyConfigs.insert(.funnel)
        funnelDailyValue.bump(key: key, by: amount)
        dirtyConfigs.insert(.funnelDaily)
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

    /// Cycles where an example is offered: везде → личка → группы → везде.
    /// Returns the new placement, nil when the example is gone.
    @discardableResult
    func cycleOnboardingExamplePlacement(id: String) -> OnboardingPlacement? {
        var config = onboardingConfigValue
        guard let index = config.examples.firstIndex(where: { $0.id == id }) else { return nil }
        config.examples[index].placement = config.examples[index].placement.next
        setOnboardingConfig(config)
        return onboardingConfigValue.example(id: id)?.placement
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

    /// Display label of a user we know by ID — for referral texts, which name
    /// the other side of the pair.
    func displayLabel(forUserID userID: Int) -> String {
        userDirectoryValue.displayLabel(forKey: UserKey.forUserID(userID))
    }

    /// Whether we have ever met this person. Used to refuse a referral link
    /// carrying a userID that was never seen (a made-up or mistyped one).
    private func isKnownUser(_ userID: Int) -> Bool {
        userDirectoryValue.identity(userID: userID) != nil || chatMetaByID[userID] != nil
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
        // Check both the permanent key and any record still pending under the
        // username they arrived with.
        var keys = [UserKey.forUserID(userID)]
        if let pending = UserKey.pending(username) { keys.append(pending) }
        for key in keys {
            if tenants[key] != nil { return true }
            if userBalances[key] != nil { return true }
        }
        return false
    }

    /// Attributes a new user to the inviter behind a `ref_` deep link. Pays
    /// nothing yet: the reward lands after the friend's first real answer
    /// (`redeemReferralIfDue`), which is what makes farming expensive.
    func bindReferral(invitedUserID: Int, invitedUsername: String?, inviterUserID: Int) -> ReferralBindOutcome {
        let config = referralConfigValue
        guard config.enabled else { return .disabled }
        guard invitedUserID != inviterUserID else {
            referralLedgerValue.refusedSelf += 1
            markReferralLedgerDirty()
            return .selfInvite
        }

        let invitedKey = String(invitedUserID)
        if let existing = referralLedgerValue.records[invitedKey] {
            referralLedgerValue.refusedRepeat += 1
            markReferralLedgerDirty()
            return .alreadyBound(inviter: existing.inviterUsername)
        }

        // A link the bot has never seen a matching person for is refused: there
        // is no wallet to pay into. No @username is needed on either side —
        // wallets are keyed by userID.
        guard isKnownUser(inviterUserID) else {
            referralLedgerValue.refusedUnknown += 1
            markReferralLedgerDirty()
            return .unknownInviter
        }
        let inviterLabel = displayLabel(forUserID: inviterUserID)
        let invited = UserKey.pending(invitedUsername)

        guard !hasPriorBotActivity(userID: invitedUserID, username: invitedUsername) else {
            referralLedgerValue.refusedNotNew += 1
            markReferralLedgerDirty()
            return .notNewUser
        }

        referralLedgerValue.records[invitedKey] = ReferralRecord(
            inviterUserID: inviterUserID,
            inviterUsername: inviterLabel,
            invitedUsername: invited
        )
        var tally = referralLedgerValue.tallies[String(inviterUserID)] ?? ReferralTally(username: inviterLabel)
        tally.username = inviterLabel
        tally.invited += 1
        referralLedgerValue.tallies[String(inviterUserID)] = tally
        markReferralLedgerDirty()
        bumpFunnel(.referralJoined)

        // The cap is checked again at payout time (it may be raised meanwhile),
        // but a friend who arrives past it must not be told about money that
        // will never come — the attribution still stands, only the promise goes.
        let cap = config.maxRewardsPerInviter
        if cap > 0, tally.rewarded >= cap {
            return .boundWithoutReward(inviter: inviterLabel)
        }
        return .bound(inviter: inviterLabel, inviteeRewardUsd: config.inviteeRewardUsd)
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

        // Both wallets are addressed by userID, so a missing or changed
        // @username can no longer hold a payout back — the labels below are
        // only what the notifications will say.
        let invited = UserKey.pending(username) ?? record.invitedUsername
        if let invited { record.invitedUsername = invited }
        record.inviterUsername = displayLabel(forUserID: record.inviterUserID)

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
            creditBalance(key: UserKey.forUserID(record.inviterUserID), amountUsd: inviterReward)
        }
        if inviteeReward > 0 {
            creditBalance(key: UserKey.forUserID(userID), amountUsd: inviteeReward)
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
            invitedLabel: displayLabel(forUserID: userID),
            inviteeRewardUsd: inviteeReward,
            inviterRewardedTotal: tally.rewarded
        )
    }

    /// Pays the inviter their one-off bonus the first time their invited friend
    /// actually spends money (subscription or credit pack). Credits the wallet
    /// and stamps the record in one actor step, so a redelivered payment cannot
    /// pay twice. Returns nil when there is nothing to pay.
    ///
    /// The anti-farming cap deliberately does not apply: it exists to make
    /// farming *free* signups pointless, and this bonus only fires on money
    /// that already came in.
    func redeemReferralPaymentBonus(payerUserID: Int) -> ReferralPaymentBonus? {
        let config = referralConfigValue
        guard config.enabled, config.payingFriendBonusCents > 0 else { return nil }
        let key = String(payerUserID)
        guard var record = referralLedgerValue.records[key], record.paidBonusAt == nil else { return nil }

        let bonus = config.payingFriendBonusUsd
        record.inviterUsername = displayLabel(forUserID: record.inviterUserID)
        var tally = referralLedgerValue.tallies[String(record.inviterUserID)]
            ?? ReferralTally(username: record.inviterUsername)
        tally.username = record.inviterUsername

        creditBalance(key: UserKey.forUserID(record.inviterUserID), amountUsd: bonus)
        record.paidBonusAt = Date()
        record.paidBonusUsd = bonus
        tally.paidConversions += 1
        tally.earnedUsd += bonus
        referralLedgerValue.paidOutUsd += bonus
        referralLedgerValue.records[key] = record
        referralLedgerValue.tallies[String(record.inviterUserID)] = tally
        markReferralLedgerDirty()
        bumpFunnel(.referralPaidBonus)

        return ReferralPaymentBonus(
            inviterUserID: record.inviterUserID,
            inviterLabel: record.inviterUsername,
            friendLabel: displayLabel(forUserID: payerUserID),
            amountUsd: bonus,
            inviterPaidTotal: tally.paidConversions
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
            paidConversions: tally?.paidConversions ?? 0,
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
            top: ledger.topInviters(limit: topLimit),
            paidConversions: ledger.paidConversionCount,
            refusedSelf: ledger.refusedSelf,
            refusedRepeat: ledger.refusedRepeat,
            refusedNotNew: ledger.refusedNotNew,
            refusedUnknown: ledger.refusedUnknown
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
            todayCounters: funnelDailyValue.counts(lastDays: 1, now: now),
            weekCounters: funnelDailyValue.counts(lastDays: 7, now: now),
            monthCounters: funnelDailyValue.counts(lastDays: 30, now: now),
            retention: userDirectoryValue.retention(now: now),
            sponsorsActive: active,
            sponsorsExpired: expired,
            sponsorsUnlimited: unlimited,
            sponsorsExpiringSoon: expiringSoon,
            winbackOffersActive: offers,
            referralPending: referralLedgerValue.pendingCount,
            referralRewarded: referralLedgerValue.rewardedCount,
            referralPaidCents: Int((referralLedgerValue.paidOutUsd * 100).rounded()),
            referralConversions: referralLedgerValue.paidConversionCount
        )
    }

    // MARK: - Per-tenant licensed users (paid access for individuals)

    @discardableResult
    func addLicensedUser(ownerUsername: String, target: String) -> Bool {
        let owner = userKeyOrRaw(ownerUsername)
        let user = userKeyOrRaw(target)
        guard !user.isEmpty, tenants[owner] != nil else { return false }
        var inserted = false
        mutateTenantByOwner(owner) { inserted = $0.licensedUsernames.insert(user).inserted }
        return inserted
    }

    @discardableResult
    func removeLicensedUser(ownerUsername: String, target: String) -> Bool {
        let owner = userKeyOrRaw(ownerUsername)
        let user = userKeyOrRaw(target)
        guard tenants[owner] != nil else { return false }
        var removed = false
        mutateTenantByOwner(owner) { removed = $0.licensedUsernames.remove(user) != nil }
        return removed
    }

    func licensedUsers(ownerUsername: String) -> [(key: String, label: String)] {
        (tenants[userKeyOrRaw(ownerUsername)]?.licensedUsernames ?? [])
            .map { (key: $0, label: displayLabel(forKey: $0)) }
            .sorted { $0.label < $1.label }
    }

    // MARK: - Tenant usage / stats

    func tenantUsage(ownerUsername: String) -> CumulativeUsage {
        tenants[userKeyOrRaw(ownerUsername)]?.cumulativeUsage ?? .zero
    }

    func tenantStats() -> [TenantStatsRow] {
        tenants.values.map { tenant in
            let owner = tenant.ownerUsername
            let chats = chatOwnership.values.filter { $0 == owner }.count
            return TenantStatsRow(
                username: owner,
                label: displayLabel(forKey: owner),
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
        let owner = chatOwnership[chatID] ?? defaultOwnerKey
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
            $0.downgradedFromModel = nil
        }
    }

    /// Cap fallback (roadmap step 6): switch to a free model but remember what
    /// was parked, so the paid choice comes back by itself once the chat has
    /// full access again. Re-downgrading keeps the *original* paid model.
    func downgradeModelToFree(chatKey: ChatKey, freeModel: String) {
        mutate(chatKey: chatKey) { context in
            guard context.model != freeModel else { return }
            if context.downgradedFromModel == nil {
                context.downgradedFromModel = context.model
            }
            context.model = freeModel
            context.modelProviderRouting = nil
        }
    }

    /// Gives back the paid model parked by the cap fallback and reports it, so
    /// the caller can tell the chat its purchase took effect. Returns nil when
    /// nothing was parked.
    @discardableResult
    func restoreDowngradedModel(chatKey: ChatKey) -> String? {
        guard let parked = contexts[chatKey]?.downgradedFromModel else { return nil }
        mutate(chatKey: chatKey) { context in
            context.model = parked
            context.modelProviderRouting = nil
            context.downgradedFromModel = nil
        }
        return parked
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

    /// Records that the bot joined or left a chat (roadmap step 4). A chat the
    /// bot was removed from still owns its licence and history — it just stops
    /// being a delivery channel until the bot is back.
    func setBotPresence(chatID: Int, isMember: Bool, type: String? = nil, title: String? = nil) {
        var info = chatMetaByID[chatID]
            ?? ChatMetaInfo(type: type ?? "group", title: title, username: nil, firstName: nil)
        if let type { info.type = type }
        if let title { info.title = title }
        info.botRemoved = isMember ? nil : true
        guard chatMetaByID[chatID] != info else { return }
        chatMetaByID[chatID] = info
        dirtyConfigs.insert(.chatMeta)
    }

    /// True when the bot is known to have been removed from this chat.
    func isBotRemoved(chatID: Int) -> Bool {
        chatMetaByID[chatID]?.botRemoved == true
    }

    // MARK: - Group welcome (roadmap step 4)

    /// One welcome per group entry. Telegram announces a join twice — as
    /// `my_chat_member` and as the `/start <payload>` message that the
    /// `?startgroup=` link posts into the chat — and the two arrive on
    /// different paths, so whichever lands first claims the greeting. The
    /// window is short enough that a genuine re-add (or a `/start` typed much
    /// later) still gets one.
    func claimGroupGreeting(chatID: Int, now: Date = Date()) -> Bool {
        if let last = _groupGreetedAt[chatID], now.timeIntervalSince(last) < Self.groupGreetingCooldown {
            return false
        }
        _groupGreetedAt[chatID] = now
        if _groupGreetedAt.count > 512 {
            // Bounded: drop entries that can no longer suppress anything.
            _groupGreetedAt = _groupGreetedAt.filter { now.timeIntervalSince($0.value) < Self.groupGreetingCooldown }
        }
        return true
    }

    // MARK: - Invite links (referral access under an admin's licence)

    func inviteToken(owner: String) -> String? {
        let u = userKeyOrRaw(owner)
        return inviteRecords.first(where: { $0.value.ownerUsername == u })?.key
    }

    /// Replaces the owner's invite with a fresh token (old links stop working).
    func regenerateInviteToken(owner: String) -> String? {
        let u = userKeyOrRaw(owner)
        guard tenants[u] != nil else { return nil }
        inviteRecords = inviteRecords.filter { $0.value.ownerUsername != u }
        let token = Self.makeInviteToken()
        inviteRecords[token] = InviteRecord(ownerUsername: u, createdAt: Date())
        dirtyConfigs.insert(.invites)
        return token
    }

    @discardableResult
    func revokeInviteToken(owner: String) -> Bool {
        let u = userKeyOrRaw(owner)
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
    /// Owner key behind an invite token, if their subscription is still active.
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
        guard let u = userKey(username: username) else { return nil }
        return userBalances[u]
    }

    func hasPositiveBalance(username: String?) -> Bool {
        (balance(username: username)?.balanceUsd ?? 0) > 0
    }

    /// Key of the wallet that should pay for this person's answers, or nil when
    /// there is nothing to charge. Resolved by userID first, so a person with
    /// no @username still spends the balance they topped up.
    func billingKey(username: String?, userID: Int?) -> String? {
        userKeys(username: username, userID: userID)
            .first { (userBalances[$0]?.balanceUsd ?? 0) > 0 }
    }

    /// Adds (or subtracts, for corrections) to the user's balance. Creates the
    /// wallet on first credit.
    @discardableResult
    func creditBalance(username: String, amountUsd: Double) -> UserBalance {
        creditBalance(key: userKeyOrRaw(username), amountUsd: amountUsd)
    }

    /// Same, for a caller that already holds the person's key — the referral
    /// payout, which addresses wallets by userID and never by @username.
    @discardableResult
    func creditBalance(key: String, amountUsd: Double) -> UserBalance {
        var wallet = userBalances[key] ?? .empty
        wallet.balanceUsd += amountUsd
        wallet.updatedAt = Date()
        userBalances[key] = wallet
        dirtyConfigs.insert(.balances)
        return wallet
    }

    /// A credit pack the person actually paid for, as opposed to a referral
    /// bonus or a super-admin grant. Tracked separately because "has paid real
    /// money at least once" is what makes a lapsed wallet worth an offer, and
    /// what tells the super-admin who is a customer (§7 «Возврат по балансу»).
    /// Topping up also reopens the lapse cycle: coming back earns a new notice.
    @discardableResult
    func creditPurchasedBalance(username: String, amountUsd: Double) -> UserBalance {
        creditPurchasedBalance(key: userKeyOrRaw(username), amountUsd: amountUsd)
    }

    @discardableResult
    func creditPurchasedBalance(key: String, amountUsd: Double) -> UserBalance {
        var wallet = creditBalance(key: key, amountUsd: amountUsd)
        wallet.toppedUpUsd += amountUsd
        wallet.lapsedNoticeAt = nil
        userBalances[key] = wallet
        dirtyConfigs.insert(.balances)
        return wallet
    }

    // MARK: - Lapsed wallets (roadmap step 8, applied to pay-as-you-go)

    /// Wallets worth one "come back" offer: the person paid real money, spent
    /// it all, has no subscription covering them, has been quiet for at least
    /// `walletWinbackDays`, and has not been offered this before.
    ///
    /// The audience is intentionally narrow — proven payers only. Everyone else
    /// already meets an offer at the moment of pain (empty balance, daily cap),
    /// and an unsolicited broadcast to free users buys nothing but blocks.
    func dueWalletWinbacks(now: Date = Date()) -> [WalletWinbackTarget] {
        let config = reminderConfigValue
        guard config.enabled, config.walletWinbackDays > 0 else { return [] }
        let idleCutoff = Double(config.walletWinbackDays) * 86_400
        var targets: [WalletWinbackTarget] = []

        for (key, wallet) in userBalances {
            guard wallet.toppedUpUsd > 0, wallet.lapsedNoticeAt == nil else { continue }
            // The bot's owners are not sold the bot's own product — same rule
            // the subscription sweep follows.
            guard !superAdminUsernames.contains(key) else { continue }
            // Still has money, or is covered by a subscription: not lapsed.
            guard wallet.balanceUsd <= Self.lapsedWalletThresholdUsd else { continue }
            if let tenant = tenants[key] {
                if tenant.isActive || tenant.remindersOptOut { continue }
            }
            guard let userID = UserKey.userID(from: key),
                  let chatID = privateChatID(forKey: key) else { continue }
            // Idle for long enough. `seenAt` is refreshed on every update, so
            // somebody who is still around never lands here.
            let lastSeen = userDirectoryValue.identity(userID: userID)?.seenAt ?? wallet.updatedAt
            guard let lastSeen, now.timeIntervalSince(lastSeen) >= idleCutoff else { continue }

            targets.append(WalletWinbackTarget(
                key: key,
                label: displayLabel(forKey: key),
                privateChatID: chatID,
                toppedUpUsd: wallet.toppedUpUsd,
                idleDays: max(1, Int(now.timeIntervalSince(lastSeen) / 86_400))
            ))
        }
        return targets.sorted { $0.toppedUpUsd > $1.toppedUpUsd }
    }

    /// A wallet is "empty enough" below this: sub-cent dust is not money.
    static let lapsedWalletThresholdUsd = 0.01

    /// Stamps a delivered lapsed-wallet offer, so it goes out once per lapse.
    /// Only called after a successful send — a failed one is retried next sweep.
    @discardableResult
    func markWalletWinbackSent(key: String, now: Date = Date()) -> Bool {
        guard var wallet = userBalances[key] else { return false }
        wallet.lapsedNoticeAt = now
        userBalances[key] = wallet
        dirtyConfigs.insert(.balances)
        return true
    }

    /// How many wallets are lapsed right now, and how many already heard from
    /// us — the monitoring line on the super-admin reminders page.
    func lapsedWalletStats(now: Date = Date()) -> (due: Int, notified: Int, payers: Int) {
        var notified = 0
        var payers = 0
        for wallet in userBalances.values where wallet.toppedUpUsd > 0 {
            payers += 1
            if wallet.lapsedNoticeAt != nil { notified += 1 }
        }
        return (dueWalletWinbacks(now: now).count, notified, payers)
    }

    @discardableResult
    func setBalanceAmount(username: String, amountUsd: Double) -> UserBalance {
        let u = userKeyOrRaw(username)
        var wallet = userBalances[u] ?? .empty
        wallet.balanceUsd = amountUsd
        wallet.updatedAt = Date()
        userBalances[u] = wallet
        dirtyConfigs.insert(.balances)
        return wallet
    }

    @discardableResult
    func removeBalance(username: String) -> Bool {
        let removed = userBalances.removeValue(forKey: userKeyOrRaw(username)) != nil
        if removed { dirtyConfigs.insert(.balances) }
        return removed
    }

    func allBalances() -> [(key: String, label: String, wallet: UserBalance)] {
        userBalances
            .map { (key: $0.key, label: displayLabel(forKey: $0.key), wallet: $0.value) }
            .sorted { $0.label < $1.label }
    }

    /// What the footer will show as the post-charge balance. The actual charge
    /// happens in `appendAssistant`; formula is identical.
    func projectedBalanceAfterCharge(username: String, realCost: Double) -> Double {
        let current = userBalances[userKeyOrRaw(username)]?.balanceUsd ?? 0
        return current - realCost * priceMultiplier()
    }

    /// Returns true when this charge is the one that emptied the wallet — the
    /// caller turns that into a single "top up" pitch at the pain point
    /// (roadmap step 5). Subsequent turns bill nobody (`billingKey` requires a
    /// positive balance), so this can only fire once per top-up cycle.
    @discardableResult
    private func chargeBalance(username: String, billedUsd: Double, realUsd: Double) -> Bool {
        guard billedUsd > 0 else { return false }
        let u = userKeyOrRaw(username)
        var wallet = userBalances[u] ?? .empty
        let wasPositive = wallet.balanceUsd > 0
        wallet.balanceUsd -= billedUsd
        wallet.spentBilledUsd += billedUsd
        wallet.spentRealUsd += realUsd
        wallet.updatedAt = Date()
        userBalances[u] = wallet
        dirtyConfigs.insert(.balances)
        let depleted = wasPositive && wallet.balanceUsd <= 0
        if depleted { bumpFunnel(.balanceEmpty) }
        return depleted
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
        // isn't met this call, it owns the slot — don't undercut it. Text and
        // throttle are super-admin knobs (`SelfPromoConfig`); the campaign
        // object stays synthetic, only the impression counter is persisted.
        guard selfPromoConfigValue.enabled else { return nil }
        guard !adCampaignList.contains(where: { $0.isRunning(now: now) }) else { return nil }
        let promo = AdCampaign.selfPromo(selfPromoConfigValue)
        guard context.adReplyCounter >= promo.everyNReplies,
              context.adLastShownAt.map({ now.timeIntervalSince($0) >= TimeInterval(promo.minIntervalSeconds) }) ?? true
        else { return nil }

        context.adReplyCounter = 0
        context.adLastShownAt = now
        contexts[chatKey] = context
        dirtyContexts.insert(chatKey)
        selfPromoConfigValue.impressions += 1
        dirtyConfigs.insert(.selfPromo)
        bumpFunnel(.promoShown)
        return promo
    }

    // MARK: - Built-in self-promo (roadmap step 5)

    func selfPromoConfig() -> SelfPromoConfig { selfPromoConfigValue }

    /// Keeps the impression counter — editing the pitch is an A/B tweak, not a
    /// reason to lose what the slot has already done. Use `resetSelfPromoStats`
    /// for that.
    func setSelfPromoConfig(_ config: SelfPromoConfig) {
        var next = config.normalized
        next.impressions = selfPromoConfigValue.impressions
        selfPromoConfigValue = next
        dirtyConfigs.insert(.selfPromo)
    }

    func resetSelfPromoStats() {
        selfPromoConfigValue.impressions = 0
        dirtyConfigs.insert(.selfPromo)
    }
}
