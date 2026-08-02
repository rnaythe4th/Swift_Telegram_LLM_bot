import Foundation

// Roles and access: super-admins, admins, whitelists, role simulation and
// the paid-access resolution used by every gate.

extension ChatContextStore {
    // MARK: - Auth

    func isSuperAdmin(_ key: UserKey?) -> Bool {
        guard let u = key.map(resolved) else { return false }
        guard superAdminKeys.contains(u) else { return false }
        return _simulatedRoles[u] == nil
    }

    /// Raw super-admin check that ignores any active simulation. Use only for
    /// gating commands that must remain reachable while a simulation is active
    /// (e.g. `/simulate` itself).
    func isActuallySuperAdmin(_ key: UserKey?) -> Bool {
        guard let u = key.map(resolved) else { return false }
        return superAdminKeys.contains(u)
    }

    /// True only for the immutable bootstrap super-admin (default @maythe4th).
    /// Only this user may add or remove other super-admins.
    func isRootSuperAdmin(_ key: UserKey?) -> Bool {
        guard let u = key.map(resolved) else { return false }
        return u == rootSuperAdminKey
    }

    /// Super-admins as (key, label) — the interface prints labels, the callers
    /// that act on one pass the key back.
    func listSuperAdmins() -> [(key: UserKey, label: String)] {
        superAdminKeys
            .map { (key: $0, label: displayLabel(forKey: $0)) }
            .sorted { $0.label < $1.label }
    }

    @discardableResult
    func addSuperAdmin(_ u: UserKey) -> Bool {
        guard !u.storageValue.isEmpty else { return false }
        let inserted = superAdminKeys.insert(u).inserted
        if inserted { dirtyConfigs.insert(.superAdmins) }
        return inserted
    }

    @discardableResult
    func removeSuperAdmin(_ u: UserKey) -> Bool {
        guard u != rootSuperAdminKey else { return false }
        let removed = superAdminKeys.remove(u) != nil
        if removed {
            dirtyConfigs.insert(.superAdmins)
            // A simulation only exists while its owner is a super-admin: every
            // reader below gates on `superAdminKeys`. Left behind, it comes
            // back with them — re-added, the person is a super-admin whom
            // `isSuperAdmin` reads as somebody else, and the only way out is a
            // `/simulate off` for a simulation nothing tells them they are in.
            _simulatedRoles.removeValue(forKey: u)
        }
        return removed
    }

    func simulatedRole(_ key: UserKey?) -> SimulatedRole? {
        guard let u = key.map(resolved) else { return nil }
        guard superAdminKeys.contains(u) else { return nil }
        return _simulatedRoles[u]
    }

    @discardableResult
    func setSimulatedRole(_ key: UserKey, role: SimulatedRole?) -> Bool {
        let u = resolved(key)
        guard superAdminKeys.contains(u) else { return false }
        if let role {
            _simulatedRoles[u] = role
        } else {
            _simulatedRoles.removeValue(forKey: u)
        }
        return true
    }

    func isTenantOwner(_ key: UserKey?, chatID: ChatID) -> Bool {
        guard let u = key.map(resolved) else { return false }
        if superAdminKeys.contains(u) {
            if _simulatedRoles[u] != nil { return false }
            return true
        }
        return effectiveOwnerKey(chatID: chatID) == u
    }

    func isAdmin(_ key: UserKey?, chatID: ChatID) -> Bool {
        guard let u = key.map(resolved) else { return false }
        if let sim = _simulatedRoles[u], superAdminKeys.contains(u) {
            return sim == .admin
        }
        if superAdminKeys.contains(u) { return true }
        let owner = effectiveOwnerKey(chatID: chatID)
        if u == owner { return true }
        return tenants[owner]?.adminKeys.contains(u) ?? false
    }

    func isWhitelisted(userID: UserID, chatID: ChatID) -> Bool {
        tenantState(for: chatID).whitelistedUserIDs.contains(userID)
    }

    func addToWhitelist(userID: UserID, chatID: ChatID) {
        mutateTenant(for: chatID) { $0.whitelistedUserIDs.insert(userID) }
        userTenantMap[userID] = effectiveOwnerKey(chatID: chatID)
    }

    func removeFromWhitelist(userID: UserID, chatID: ChatID) {
        mutateTenant(for: chatID) { $0.whitelistedUserIDs.remove(userID) }
        userTenantMap.removeValue(forKey: userID)
    }

    func listWhitelisted(chatID: ChatID) -> Set<UserID> {
        tenantState(for: chatID).whitelistedUserIDs
    }

    func addAdmin(_ u: UserKey, chatID: ChatID) {
        mutateTenant(for: chatID) { $0.adminKeys.insert(u) }
    }

    func removeAdmin(_ u: UserKey, chatID: ChatID) {
        mutateTenant(for: chatID) { $0.adminKeys.remove(u) }
    }

    func listAdmins(chatID: ChatID) -> [(key: UserKey, label: String)] {
        tenantState(for: chatID).adminKeys
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
        superAdminKeys
            .compactMap { privateChatID(forKey: $0) }
            .map { ChatKey(chatID: $0, threadID: 0) }
    }

    /// Why this chat does (or doesn't) have smart models right now. Same order
    /// of precedence as `hasSubscriptionCoverage`/`hasFullModelAccess`, but it
    /// reports *who* is paying — so the menu and the purchase page can credit
    /// the sponsor (roadmap step 3) instead of selling to someone who is
    /// already covered.
    func chatAccessStatus(chatID: ChatID, key: UserKey?, userID: UserID? = nil) -> ChatAccessStatus {
        let candidates = userKeys(key: key, userID: userID)
        let simulated = candidates.contains { superAdminKeys.contains($0) && _simulatedRoles[$0] != nil }

        if !simulated {
            for u in candidates {
                if let own = tenants[u], own.isActive {
                    return .ownSubscription(until: own.paidUntil)
                }
            }
            for (owner, tenant) in tenants where tenant.isActive
                && !tenant.licensedKeys.isDisjoint(with: candidates) {
                return .guest(displayLabel(forKey: owner))
            }
        }
        if let owner = chatOwnership[chatID], tenants[owner]?.isActive == true {
            return .sponsored(displayLabel(forKey: owner))
        }
        if let userID {
            let tenant = tenantState(for: chatID)
            if tenant.whitelistedUserIDs.contains(userID), tenant.isActive {
                return .guest(displayLabel(forKey: tenant.ownerKey))
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
    func hasSubscriptionCoverage(key: UserKey?, userID: UserID? = nil, chatID: ChatID? = nil) -> Bool {
        let candidates = userKeys(key: key, userID: userID)
        let simulated = candidates.contains { superAdminKeys.contains($0) && _simulatedRoles[$0] != nil }

        // Every path below requires the granting tenant's subscription to be
        // active: an expired admin keeps their panel (to renew) but their
        // chats and users fall back to free models.
        if !simulated {
            for u in candidates where tenants[u]?.isActive == true { return true }
            for tenant in tenants.values where tenant.isActive
                && !tenant.licensedKeys.isDisjoint(with: candidates) {
                return true
            }
        }

        // Chat-level licensing: chat assigned to a tenant grants access to all members.
        if let chatID, let owner = chatOwnership[chatID],
           tenants[owner]?.isActive == true {
            return true
        }
        // Per-chat whitelisted user IDs (set by tenant owner for this chat).
        // An identified key *is* a userID (`#<id>`, §6), so a caller that only
        // has the key still gets the guest checked: passing the id separately
        // used to be the difference between the tap letting somebody in and the
        // redraw a minute later telling the same person they have no access.
        if let chatID, let account = userID ?? key?.userID {
            let tenant = tenantState(for: chatID)
            if tenant.whitelistedUserIDs.contains(account), tenant.isActive {
                return true
            }
        }
        return false
    }

    /// The sponsor of a group chat: the owner whose *active* subscription opens
    /// paid access to the whole chat. Used for the hero credit under answers.
    /// Returns nil when the chat has no active-tenant owner, or when the asker
    /// is the sponsor themselves (no self-crediting).
    func chatSponsor(chatID: ChatID, asker: UserKey?) -> String? {
        guard let owner = chatOwnership[chatID], tenants[owner]?.isActive == true else {
            return nil
        }
        if let asker = asker.map(resolved), asker == owner {
            return nil
        }
        return displayLabel(forKey: owner)
    }

    /// Same as `chatSponsor`, but rate-limited: the credit line under answers
    /// repeats at most once per `sponsorCreditCooldown` per chat. Consuming the
    /// slot here (rather than in the caller) keeps two parallel generations in
    /// one chat from both printing it.
    func chatSponsorForCredit(chatID: ChatID, asker: UserKey?, now: Date = Date()) -> String? {
        guard let sponsor = chatSponsor(chatID: chatID, asker: asker) else { return nil }
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
    func hasFullModelAccess(key: UserKey?, userID: UserID? = nil, chatID: ChatID? = nil) -> Bool {
        if hasSubscriptionCoverage(key: key, userID: userID, chatID: chatID) {
            return true
        }
        // A wallet belongs to a person, not to a handle: the userID alone is
        // enough, so someone with no @username still spends their balance.
        return userKeys(key: key, userID: userID)
            .contains { (userBalances[$0]?.balance ?? .zero).isPositive }
    }
}
