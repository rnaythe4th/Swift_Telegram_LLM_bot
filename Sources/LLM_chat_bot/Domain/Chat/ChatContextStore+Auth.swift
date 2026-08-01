import Foundation

// Roles and access: super-admins, admins, whitelists, role simulation and
// the paid-access resolution used by every gate.

extension ChatContextStore {
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

    /// DMs of the actual super-admins — the channel for owner-only notices.
    ///
    /// Resolved from the super-admin list through `privateChatID`, not from
    /// chat ownership: a DM is only ever assigned to a tenant by
    /// `autoAssignIfNeeded`, so an owner who never triggered that (or who is a
    /// super-admin without being the root tenant) received nothing at all,
    /// while any chat someone had pointed at the root tenant got mail meant for
    /// the owner. Blocked DMs drop out, like everywhere else.
    func superAdminPrivateChats() -> [ChatKey] {
        superAdminUsernames
            .compactMap { privateChatID(forKey: $0) }
            .map { ChatKey(chatID: $0, threadID: 0) }
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
            if let wallet = userBalances[u], wallet.balance.isPositive {
                return .balance(wallet.balance)
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
            .contains { (userBalances[$0]?.balance ?? .zero).isPositive }
    }
}
