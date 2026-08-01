import Foundation

// Tenants: routing a chat to its owner, tenant CRUD, chat ownership,
// licensed users and per-tenant usage stats.

extension ChatContextStore {
    // MARK: - Tenant routing helpers

    func tenantState(for chatID: Int) -> TenantState {
        let owner = chatOwnership[chatID] ?? defaultOwnerKey
        if let tenant = tenants[owner] { return tenant }
        if let fallback = tenants[defaultOwnerKey] { return fallback }
        // The owner row is seeded in init and re-filed (never dropped) by
        // identifyUser; rebuild it rather than trap if it ever goes missing.
        let seeded = TenantState(
            ownerKey: defaultOwnerKey,
            defaultModel: initialDefaultModel,
            defaultRole: initialDefaultRole,
            defaultHistoryLength: initialDefaultHistoryLength,
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
        tenants[defaultOwnerKey] = seeded
        dirtyTenants.insert(defaultOwnerKey)
        return seeded
    }

    func mutateTenant(for chatID: Int, _ block: (inout TenantState) -> Void) {
        let owner = chatOwnership[chatID] ?? defaultOwnerKey
        guard var tenant = tenants[owner] else { return }
        block(&tenant)
        tenants[owner] = tenant
        dirtyTenants.insert(owner)
    }

    func mutateTenantByOwner(_ ownerKey: UserKey, _ block: (inout TenantState) -> Void) {
        let u = resolved(ownerKey)
        guard var tenant = tenants[u] else { return }
        block(&tenant)
        tenants[u] = tenant
        dirtyTenants.insert(u)
    }

    // MARK: - Tenant management

    /// Registers a tenant without a subscription term (unlimited) — the
    /// super-admin manual path. Paid activations go through
    /// `activatePaidSubscription`.
    func registerTenant(_ key: UserKey) {
        let u = resolved(key)
        guard tenants[u] == nil else { return }
        let defaults = tenants[defaultOwnerKey]
        tenants[u] = TenantState(
            ownerKey: u,
            defaultModel: defaults?.defaultModel ?? initialDefaultModel,
            defaultRole: defaults?.defaultRole ?? initialDefaultRole,
            defaultHistoryLength: defaults?.defaultHistoryLength ?? initialDefaultHistoryLength,
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
        dirtyTenants.insert(u)
        deletedTenants.remove(u)
    }

    @discardableResult
    func removeTenant(_ key: UserKey) -> Bool {
        let u = resolved(key)
        guard u != defaultOwnerKey, tenants[u] != nil else { return false }
        tenants.removeValue(forKey: u)
        let ownedChats = chatOwnership.filter { $0.value == u }.map(\.key)
        for chatID in ownedChats {
            chatOwnership.removeValue(forKey: chatID)
            dirtyChats.insert(chatID)
            deletedChats.remove(chatID)
        }
        userTenantMap = userTenantMap.filter { $0.value != u }
        for token in inviteRecords.filter({ $0.value.ownerKey == u }).keys {
            inviteRecords.removeValue(forKey: token)
            dirtyInvites.remove(token)
            deletedInvites.insert(token)
        }
        dirtyTenants.remove(u)
        deletedTenants.insert(u)
        return true
    }

    func listTenants() -> [(key: UserKey, label: String)] {
        tenants.keys
            .map { (key: $0, label: displayLabel(forKey: $0)) }
            .sorted { $0.label < $1.label }
    }

    func isTenant(_ key: UserKey) -> Bool {
        tenants[resolved(key)] != nil
    }

    /// Storage key of whoever opened premium in this chat.
    func chatOwner(chatID: Int) -> UserKey? {
        chatOwnership[chatID]
    }

    /// Same, ready to print: `@username` / name / `id <n>`.
    func chatOwnerLabel(chatID: Int) -> String? {
        chatOwnership[chatID].map { displayLabel(forKey: $0) }
    }

    func effectiveOwnerKey(chatID: Int) -> UserKey {
        chatOwnership[chatID] ?? defaultOwnerKey
    }

    @discardableResult
    func assignChat(chatID: Int, to ownerKey: UserKey) -> Bool {
        let u = resolved(ownerKey)
        guard tenants[u] != nil else { return false }
        chatOwnership[chatID] = u
        dirtyChats.insert(chatID)
        deletedChats.remove(chatID)
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
    func claimChatForPayment(chatID: Int, payerKey: UserKey) -> ChatClaimOutcome {
        let key = resolved(payerKey)
        guard tenants[key] != nil else { return .unknownTenant }
        if chatID < 0,
           let current = chatOwnership[chatID],
           current != key,
           tenants[current]?.isActive == true {
            return .keptSponsor(label: displayLabel(forKey: current))
        }
        chatOwnership[chatID] = key
        dirtyChats.insert(chatID)
        deletedChats.remove(chatID)
        return .assigned
    }

    @discardableResult
    func unassignChat(chatID: Int) -> UserKey? {
        let removed = chatOwnership.removeValue(forKey: chatID)
        if removed != nil {
            dirtyChats.insert(chatID)
            deletedChats.remove(chatID)
        }
        return removed
    }

    func chatsOwnedBy(_ ownerKey: UserKey) -> [Int] {
        let u = resolved(ownerKey)
        return chatOwnership.compactMap { $0.value == u ? $0.key : nil }
    }

    func autoAssignIfNeeded(chatID: Int, senderKey: UserKey?, senderUserID: Int?) {
        guard chatOwnership[chatID] == nil else { return }
        let lowered = senderKey.map(resolved)
        // A super-admin simulating a regular user must be able to keep a chat
        // unowned (after /tenant release) to test ads and balance billing —
        // otherwise their own tenant would instantly re-claim it here.
        if let u = lowered, superAdminKeys.contains(u), _simulatedRoles[u] != nil {
            return
        }
        if let userID = senderUserID, tenants[UserKey.identified(userID)] != nil {
            // Their own subscription — works even without a @username.
            chatOwnership[chatID] = UserKey.identified(userID)
        } else if let sender = lowered, tenants[sender] != nil {
            chatOwnership[chatID] = sender
        } else if let userID = senderUserID, let owner = userTenantMap[userID] {
            chatOwnership[chatID] = owner
        } else {
            return
        }
        dirtyChats.insert(chatID)
        deletedChats.remove(chatID)
    }

    // MARK: - Per-tenant licensed users (paid access for individuals)

    @discardableResult
    func addLicensedUser(ownerKey: UserKey, target: UserKey) -> Bool {
        let owner = resolved(ownerKey)
        let user = resolved(target)
        guard !user.storageValue.isEmpty, tenants[owner] != nil else { return false }
        var inserted = false
        mutateTenantByOwner(owner) { inserted = $0.licensedKeys.insert(user).inserted }
        return inserted
    }

    @discardableResult
    func removeLicensedUser(ownerKey: UserKey, target: UserKey) -> Bool {
        let owner = resolved(ownerKey)
        let user = resolved(target)
        guard tenants[owner] != nil else { return false }
        var removed = false
        mutateTenantByOwner(owner) { removed = $0.licensedKeys.remove(user) != nil }
        return removed
    }

    func licensedUsers(ownerKey: UserKey) -> [(key: UserKey, label: String)] {
        (tenants[resolved(ownerKey)]?.licensedKeys ?? [])
            .map { (key: $0, label: displayLabel(forKey: $0)) }
            .sorted { $0.label < $1.label }
    }

    // MARK: - Tenant usage / stats

    func tenantUsage(ownerKey: UserKey) -> CumulativeUsage {
        tenants[resolved(ownerKey)]?.cumulativeUsage ?? .zero
    }

    func tenantStats() -> [TenantStatsRow] {
        tenants.values.map { tenant in
            let owner = tenant.ownerKey
            let chats = chatOwnership.values.filter { $0 == owner }.count
            return TenantStatsRow(
                key: owner,
                label: displayLabel(forKey: owner),
                usage: tenant.cumulativeUsage,
                chatCount: chats,
                licensedUserCount: tenant.licensedKeys.count,
                isSuperAdmin: superAdminKeys.contains(owner),
                paidUntil: tenant.paidUntil,
                isActive: tenant.isActive
            )
        }
        .sorted { $0.key < $1.key }
    }

    func accumulateTenantUsage(chatID: Int, usage: StreamUsageSummary?) {
        let owner = chatOwnership[chatID] ?? defaultOwnerKey
        let markup = markupPercentValue
        mutateTenantByOwner(owner) {
            $0.cumulativeUsage.add(usage, markupPercent: markup)
        }
    }
}
