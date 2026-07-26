import Foundation

// Identity: UserKey ↔ @username, adoption of records left under a
// stale handle, directory pruning.

extension ChatContextStore {
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
    ///
    /// The fallback is *sanitized*, not raw. This is the one place free-form
    /// text (a hand-typed `/tenant adduser` argument) could become a storage
    /// key, and a storage key is not inert: it is written into database filters
    /// and printed into HTML. A key that keeps only username characters cannot
    /// reach into either, and cannot impersonate an identified `#<userID>` key.
    func userKeyOrRaw(_ username: String) -> String {
        let trimmed = username.trimmingCharacters(in: .whitespaces)
        // An already-resolved key round-trips untouched — callers pass
        // `#<userID>` deliberately (CLAUDE.md §6).
        if UserKey.userID(from: trimmed) != nil { return trimmed }
        if let resolved = userKey(username: trimmed) { return resolved }
        return UserKey.sanitizedPendingFallback(trimmed)
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
        // A configured owner account wins over everything stored: that is the
        // point of configuring it — root stops depending on who currently holds
        // a @username, or on what an earlier run happened to pin.
        if let pinnedOwnerUserID { return UserKey.forUserID(pinnedOwnerUserID) }
        return userDirectoryValue.rootKey ?? userKey(username: rootSuperAdminUsername) ?? rootSuperAdminUsername
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
}
