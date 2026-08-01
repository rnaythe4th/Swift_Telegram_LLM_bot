import Foundation

// Persistence side of the store: incremental dirty-batch export, row-based
// restore, payment idempotency and the polling offset.
extension ChatContextStore {

    // MARK: - Snapshot builders

    private func makeContextSnapshot(_ context: ChatContext) -> ChatContextSnapshot {
        ChatContextSnapshot(
            role: context.role,
            history: context.history,
            model: context.model,
            modelProvider: context.modelProviderRouting,
            temp: context.temp,
            showStats: context.showStats,
            maxHistory: context.maxHistory,
            showCost: context.showCost,
            showModel: context.showModel,
            provider: context.provider,
            suffix: context.suffix,
            reasoningEffort: context.reasoningEffort,
            backupNotify: context.backupNotify,
            cumulativeUsage: context.cumulativeUsage,
            chatModelPresets: context.chatModelPresets.isEmpty ? nil : context.chatModelPresets,
            chatTempPresets: context.chatTempPresets.isEmpty ? nil : context.chatTempPresets,
            chatHistoryLengthPresets: context.chatHistoryLengthPresets.isEmpty ? nil : context.chatHistoryLengthPresets,
            chatRolePresets: context.chatRolePresets.isEmpty ? nil : context.chatRolePresets,
            adReplyCounter: context.adReplyCounter == 0 ? nil : context.adReplyCounter,
            adLastShownAt: context.adLastShownAt,
            funnelCounted: context.funnelFirstMessageCounted ? true : nil,
            downgradedFrom: context.downgradedFromModel,
            activeMode: context.activeModeID
        )
    }

    private func makeTenantSnapshot(_ tenant: TenantState) -> TenantStateSnapshot {
        TenantStateSnapshot(
            ownerUsername: tenant.ownerUsername,
            defaultModel: tenant.defaultModel,
            defaultRole: tenant.defaultRole,
            defaultHistoryLength: tenant.defaultHistoryLength,
            modelPresets: tenant.modelPresets,
            tempPresets: tenant.tempPresets,
            historyLengthPresets: tenant.historyLengthPresets,
            rolePresets: tenant.rolePresets,
            whitelistedUserIDs: Array(tenant.whitelistedUserIDs),
            adminUsernames: Array(tenant.adminUsernames),
            licensedUsernames: Array(tenant.licensedUsernames),
            cumulativeUsage: tenant.cumulativeUsage,
            createdAt: tenant.createdAt,
            paidUntil: tenant.paidUntil,
            noticeCycleUntil: tenant.noticeCycleUntil,
            sentNotices: tenant.sentNotices.isEmpty ? nil : Array(tenant.sentNotices),
            winbackDiscount: tenant.winbackDiscount,
            remindersOptOut: tenant.remindersOptOut ? true : nil
        )
    }

    private func makeContext(from snapshot: ChatContextSnapshot) -> ChatContext {
        ChatContext(
            role: snapshot.role,
            history: snapshot.history,
            pendingTurns: [],
            model: snapshot.model,
            modelProviderRouting: snapshot.modelProvider,
            temp: snapshot.temp,
            showStats: snapshot.showStats,
            maxHistory: snapshot.maxHistory,
            showCost: snapshot.showCost,
            showModel: snapshot.showModel,
            provider: snapshot.provider,
            suffix: snapshot.suffix,
            reasoningEffort: snapshot.reasoningEffort,
            backupNotify: snapshot.backupNotify,
            cumulativeUsage: snapshot.cumulativeUsage ?? .zero,
            chatModelPresets: snapshot.chatModelPresets ?? [],
            chatTempPresets: snapshot.chatTempPresets ?? [],
            chatHistoryLengthPresets: snapshot.chatHistoryLengthPresets ?? [],
            chatRolePresets: snapshot.chatRolePresets ?? [],
            adReplyCounter: snapshot.adReplyCounter ?? 0,
            adLastShownAt: snapshot.adLastShownAt,
            funnelFirstMessageCounted: snapshot.funnelCounted ?? false,
            downgradedFromModel: snapshot.downgradedFrom,
            activeModeID: snapshot.activeMode
        )
    }

    private func makeTenant(from snapshot: TenantStateSnapshot) -> TenantState {
        TenantState(
            ownerUsername: snapshot.ownerUsername,
            defaultModel: snapshot.defaultModel,
            defaultRole: snapshot.defaultRole,
            defaultHistoryLength: snapshot.defaultHistoryLength,
            modelPresets: snapshot.modelPresets,
            tempPresets: snapshot.tempPresets,
            historyLengthPresets: snapshot.historyLengthPresets,
            rolePresets: snapshot.rolePresets,
            whitelistedUserIDs: Set(snapshot.whitelistedUserIDs),
            adminUsernames: Set(snapshot.adminUsernames),
            licensedUsernames: Set((snapshot.licensedUsernames ?? []).map { $0.lowercased() }),
            cumulativeUsage: snapshot.cumulativeUsage ?? .zero,
            createdAt: snapshot.createdAt,
            paidUntil: snapshot.paidUntil,
            noticeCycleUntil: snapshot.noticeCycleUntil,
            sentNotices: Set(snapshot.sentNotices ?? []),
            winbackDiscount: snapshot.winbackDiscount,
            remindersOptOut: snapshot.remindersOptOut ?? false
        )
    }

    // MARK: - Dirty batch export

    /// Everything that changed since the last drain, and nothing else. Each set
    /// is emptied as it is read, so a change is written exactly once — and a
    /// new mutable entity that forgets to mark its set is a value that silently
    /// never reaches the database (which is why every set is drained here, in
    /// one place, and why `StorePersistenceTests` checks the areas).
    func drainDirtyBatch() -> PersistenceBatch {
        var batch = PersistenceBatch()

        for userID in dirtyUsers {
            if let identity = userDirectoryValue.identity(userID: userID) {
                batch.users.append(UserRow(identity: identity))
            }
        }
        for key in dirtyContexts {
            if let context = contexts[key] {
                batch.contexts.append(ChatContextRow(key: key, snapshot: makeContextSnapshot(context)))
            }
        }
        batch.deletedContexts = Array(deletedContexts)
        for owner in dirtyTenants {
            if let tenant = tenants[owner] {
                batch.tenants.append(TenantRow(username: owner, snapshot: makeTenantSnapshot(tenant)))
            }
        }
        batch.deletedTenants = Array(deletedTenants)
        for chatID in dirtyChats {
            batch.chats.append(ChatRow(
                chatID: chatID,
                meta: chatMetaByID[chatID],
                ownerKey: chatOwnership[chatID]
            ))
        }
        batch.deletedChats = Array(deletedChats)
        for token in dirtyInvites {
            if let record = inviteRecords[token] {
                batch.invites.append(InviteRow(token: token, record: record))
            }
        }
        batch.deletedInvites = Array(deletedInvites)
        for subject in dirtyPremiumUsage {
            if let usage = premiumDailyUsage[subject] {
                batch.premiumUsage.append(PremiumUsageRow(subject: subject, usage: usage))
            }
        }
        batch.deletedPremiumUsage = Array(deletedPremiumUsage)
        for userID in dirtyReferrals {
            if let record = referralLedgerValue.records[String(userID)] {
                batch.referrals.append(ReferralRow(invitedUserID: userID, record: record))
            }
        }
        batch.deletedReferrals = Array(deletedReferrals)
        for userID in dirtyReferralTallies {
            if let tally = referralLedgerValue.tallies[String(userID)] {
                batch.referralTallies.append(ReferralTallyRow(inviterUserID: userID, tally: tally))
            }
        }
        batch.deletedReferralTallies = Array(deletedReferralTallies)
        for userID in dirtyTrafficAttributions {
            if let attribution = trafficSourceLedgerValue.attributions[String(userID)] {
                batch.trafficAttributions.append(TrafficAttributionRow(userID: userID, attribution: attribution))
            }
        }
        batch.deletedTrafficAttributions = Array(deletedTrafficAttributions)
        for cell in dirtyFunnelDays {
            let count = funnelDailyValue.count(day: cell.day, event: cell.event)
            batch.funnelDays.append(FunnelDayRow(day: cell.day, event: cell.event, count: count))
        }
        for id in dirtyCryptoInvoices {
            if let invoice = _cryptoInvoices[id] {
                batch.cryptoInvoices.append(CryptoInvoiceRow(invoice: invoice))
            }
        }
        batch.deletedCryptoInvoices = Array(deletedCryptoInvoices)
        for id in dirtyExternalOrders {
            if let order = _externalOrders[id] {
                batch.externalOrders.append(ExternalOrderRow(order: order))
            }
        }
        batch.deletedExternalOrders = Array(deletedExternalOrders)
        batch.configs = dirtyConfigs.map(currentConfigValue)

        dirtyUsers.removeAll()
        dirtyContexts.removeAll()
        deletedContexts.removeAll()
        dirtyTenants.removeAll()
        deletedTenants.removeAll()
        dirtyChats.removeAll()
        deletedChats.removeAll()
        dirtyInvites.removeAll()
        deletedInvites.removeAll()
        dirtyPremiumUsage.removeAll()
        deletedPremiumUsage.removeAll()
        dirtyReferrals.removeAll()
        deletedReferrals.removeAll()
        dirtyReferralTallies.removeAll()
        deletedReferralTallies.removeAll()
        dirtyTrafficAttributions.removeAll()
        deletedTrafficAttributions.removeAll()
        dirtyFunnelDays.removeAll()
        dirtyCryptoInvoices.removeAll()
        deletedCryptoInvoices.removeAll()
        dirtyExternalOrders.removeAll()
        deletedExternalOrders.removeAll()
        dirtyConfigs.removeAll()
        return batch
    }

    /// Wallets changed outside a ledger transaction (a rename adopting one).
    /// Drained separately because money is written through `LedgerPort`, not
    /// through the write-behind batch.
    func drainDirtyWallets() -> (changed: [String: UserBalance], removed: [String]) {
        var changed: [String: UserBalance] = [:]
        for key in dirtyWallets {
            if let wallet = userBalances[key] { changed[key] = wallet }
        }
        let removed = Array(deletedWallets)
        dirtyWallets.removeAll()
        deletedWallets.removeAll()
        return (changed, removed)
    }

    var dirtyEntityCount: Int {
        dirtyUsers.count + dirtyContexts.count + deletedContexts.count
            + dirtyTenants.count + deletedTenants.count
            + dirtyChats.count + deletedChats.count
            + dirtyInvites.count + deletedInvites.count
            + dirtyPremiumUsage.count + deletedPremiumUsage.count
            + dirtyReferrals.count + deletedReferrals.count
            + dirtyReferralTallies.count + deletedReferralTallies.count
            + dirtyTrafficAttributions.count + deletedTrafficAttributions.count
            + dirtyFunnelDays.count
            + dirtyCryptoInvoices.count + deletedCryptoInvoices.count
            + dirtyExternalOrders.count + deletedExternalOrders.count
            + dirtyWallets.count + deletedWallets.count
            + dirtyConfigs.count
    }

    private func currentConfigValue(for key: GlobalConfigKey) -> GlobalConfigValue {
        switch key {
        case .starsPrice:
            return .starsPrice(_starsPrice)
        case .starsPerUsd:
            return .starsPerUsd(_starsPerUsd)
        case .freeModels:
            return .freeModels(_freeModelIDs)
        case .crypto:
            return .crypto(cryptoConfigSnapshot())
        case .card:
            return .card(_cardConfig)
        case .superAdmins:
            return .superAdmins(Array(superAdminUsernames.subtracting([rootSuperAdminKey, rootSuperAdminUsername])).sorted())
        case .pollingOffset:
            return .pollingOffset(pollingOffsetValue ?? 0)
        case .ads:
            return .ads(adCampaignList)
        case .markup:
            return .markup(markupPercentValue)
        case .funnel:
            return .funnel(funnelCounters)
        case .dailyPremiumLimit:
            return .dailyPremiumLimit(dailyPremiumLimitValue)
        case .selfPromo:
            return .selfPromo(selfPromoConfigValue)
        case .modes:
            return .modes(modeConfigValue)
        case .reminders:
            return .reminders(reminderConfigValue)
        case .onboarding:
            return .onboarding(onboardingConfigValue)
        case .referrals:
            return .referrals(referralConfigValue)
        case .referralTotals:
            return .referralTotals(referralLedgerValue.totals)
        case .trafficTotals:
            return .trafficTotals(trafficSourceLedgerValue.totals)
        case .externalPayments:
            return .externalPayments(_externalPaymentConfig)
        case .spendPolicy:
            return .spendPolicy(spendPolicyValue)
        }
    }

    /// Queues the whole current state for the next flush.
    func markAllDirty() {
        dirtyUsers.formUnion(userDirectoryValue.identities.keys)
        dirtyContexts.formUnion(contexts.keys)
        dirtyTenants.formUnion(tenants.keys)
        dirtyChats.formUnion(Set(chatMetaByID.keys).union(chatOwnership.keys))
        dirtyInvites.formUnion(inviteRecords.keys)
        dirtyPremiumUsage.formUnion(premiumDailyUsage.keys)
        dirtyWallets.formUnion(userBalances.keys)
        dirtyReferrals.formUnion(referralLedgerValue.records.keys.compactMap(Int.init))
        dirtyReferralTallies.formUnion(referralLedgerValue.tallies.keys.compactMap(Int.init))
        dirtyTrafficAttributions.formUnion(trafficSourceLedgerValue.attributions.keys.compactMap(Int.init))
        dirtyFunnelDays.formUnion(funnelDailyValue.allCells)
        dirtyCryptoInvoices.formUnion(_cryptoInvoices.keys)
        dirtyExternalOrders.formUnion(_externalOrders.keys)
        dirtyConfigs.formUnion(GlobalConfigKey.allCases)
    }

    // MARK: - Polling offset (long-polling mode only)

    func pollingOffset() -> Int? {
        pollingOffsetValue
    }

    func setPollingOffset(_ offset: Int) {
        guard pollingOffsetValue != offset else { return }
        pollingOffsetValue = offset
        dirtyConfigs.insert(.pollingOffset)
    }

    // MARK: - Restore

    func restore(from state: PersistedBotState) {
        // The directory comes first: `defaultOwnerKey` / `rootSuperAdminKey`
        // resolve through it, so seeding the owner rows before it is loaded
        // would file them under the wrong key until that person next writes.
        userDirectoryValue = .empty
        for row in state.users {
            userDirectoryValue.restore(row.identity)
        }

        contexts.removeAll()
        for row in state.contexts {
            contexts[row.key] = makeContext(from: row.snapshot)
        }

        tenants.removeAll()
        for row in state.tenants {
            tenants[row.username.lowercased()] = makeTenant(from: row.snapshot)
        }
        ensureDefaultOwnerTenant()

        chatMetaByID = [:]
        chatOwnership.removeAll()
        for row in state.chats {
            if let meta = row.meta { chatMetaByID[row.chatID] = meta }
            if let owner = row.ownerKey, !owner.isEmpty { chatOwnership[row.chatID] = owner.lowercased() }
        }

        superAdminUsernames = [rootSuperAdminKey]
        for name in state.configs.superAdmins ?? [] {
            let lowered = name.lowercased()
            if !lowered.isEmpty { superAdminUsernames.insert(lowered) }
        }

        rebuildUserTenantMap()

        _starsPrice = state.configs.starsPrice
        if let rate = state.configs.starsPerUsd { _starsPerUsd = rate }
        _freeModelIDs = state.configs.freeModelIDs ?? []
        restoreCryptoConfig(state.configs.crypto)
        restoreCryptoInvoices(state.cryptoInvoices.map(\.invoice))
        _cardConfig = state.configs.card ?? .empty
        pollingOffsetValue = state.configs.pollingOffset

        inviteRecords = [:]
        for row in state.invites { inviteRecords[row.token] = row.record }

        adCampaignList = state.configs.ads ?? []
        markupPercentValue = state.configs.markup ?? 30

        userBalances = state.wallets

        funnelCounters = state.configs.funnel ?? [:]
        funnelDailyValue = FunnelDailyLog(rows: state.funnelDays.map { (day: $0.day, event: $0.event, count: $0.count) })
        dailyPremiumLimitValue = state.configs.dailyPremiumLimit ?? 5
        // Yesterday's counters are dead weight — a restore is as good a moment
        // to drop them as a write is. They are dropped from storage too, so the
        // table tracks "free chats active today" rather than growing forever.
        let today = FunnelDailyLog.dayNumber()
        premiumDailyUsage = [:]
        for row in state.premiumUsage {
            if row.usage.day == today {
                premiumDailyUsage[row.subject] = row.usage
            } else {
                deletedPremiumUsage.insert(row.subject)
            }
        }

        selfPromoConfigValue = (state.configs.selfPromo ?? .default).normalized
        modeConfigValue = (state.configs.modes ?? .default).normalized
        reminderConfigValue = (state.configs.reminders ?? .default).normalized
        onboardingConfigValue = (state.configs.onboarding ?? .default).normalized
        referralConfigValue = (state.configs.referrals ?? .default).normalized
        spendPolicyValue = state.configs.spendPolicy ?? .default

        referralLedgerValue = .empty
        referralLedgerValue.totals = state.configs.referralTotals ?? .empty
        for row in state.referrals { referralLedgerValue.records[String(row.invitedUserID)] = row.record }
        for row in state.referralTallies { referralLedgerValue.tallies[String(row.inviterUserID)] = row.tally }

        trafficSourceLedgerValue = .empty
        trafficSourceLedgerValue.totals = state.configs.trafficTotals ?? .empty
        for row in state.trafficAttributions {
            trafficSourceLedgerValue.attributions[String(row.userID)] = row.attribution
            var tally = trafficSourceLedgerValue.tallies[row.attribution.tag]
                ?? TrafficSourceTally(firstSeenAt: row.attribution.joinedAt)
            tally.joined += 1
            if row.attribution.activatedAt != nil { tally.activated += 1 }
            if row.attribution.paidAt != nil { tally.payers += 1 }
            tally.payments += row.attribution.payments
            tally.firstSeenAt = Swift.min(tally.firstSeenAt, row.attribution.joinedAt)
            tally.lastSeenAt = Swift.max(tally.lastSeenAt, row.attribution.joinedAt)
            trafficSourceLedgerValue.tallies[row.attribution.tag] = tally
        }

        restoreExternalPayments(
            config: state.configs.externalPayments,
            orders: state.externalOrders.map(\.order)
        )
    }

    // MARK: - Shared restore helpers

    private func ensureDefaultOwnerTenant() {
        guard tenants[defaultOwnerKey] == nil else { return }
        tenants[defaultOwnerKey] = TenantState(
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
    }

    /// The userID → tenant map is derived data: rebuilt from whitelists.
    private func rebuildUserTenantMap() {
        userTenantMap.removeAll()
        for (owner, tenant) in tenants {
            for userID in tenant.whitelistedUserIDs {
                userTenantMap[userID] = owner
            }
        }
    }
}
