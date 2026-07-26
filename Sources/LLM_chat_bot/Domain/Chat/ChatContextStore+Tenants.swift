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

    func mutateTenant(for chatID: Int, _ block: (inout TenantState) -> Void) {
        let owner = chatOwnership[chatID] ?? defaultOwnerKey
        guard var tenant = tenants[owner] else { return }
        block(&tenant)
        tenants[owner] = tenant
        dirtyTenants.insert(owner)
    }

    func mutateTenantByOwner(_ ownerUsername: String, _ block: (inout TenantState) -> Void) {
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

    func accumulateTenantUsage(chatID: Int, usage: StreamUsageSummary?) {
        let owner = chatOwnership[chatID] ?? defaultOwnerKey
        let multiplier = priceMultiplier()
        mutateTenantByOwner(owner) {
            $0.cumulativeUsage.add(usage, priceMultiplier: multiplier)
        }
    }
}
