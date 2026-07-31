import Foundation

// Persistence side of the store: incremental dirty-batch export, row-based
// restore, one-time migration from the legacy whole-state snapshot, payment
// idempotency and the polling offset.
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

    func drainDirtyBatch() -> PersistenceBatch {
        var batch = PersistenceBatch()
        for key in dirtyContexts {
            if let context = contexts[key] {
                batch.contexts.append(ChatContextRow(key: key, snapshot: makeContextSnapshot(context)))
            }
        }
        for owner in dirtyTenants {
            if let tenant = tenants[owner] {
                batch.tenants.append(TenantRow(username: owner, snapshot: makeTenantSnapshot(tenant)))
            }
        }
        batch.deletedTenants = Array(deletedTenants)
        for chatID in dirtyOwnership {
            if let owner = chatOwnership[chatID] {
                batch.ownership.append(OwnershipRow(chatID: chatID, owner: owner))
            }
        }
        batch.deletedOwnership = Array(deletedOwnership)
        batch.configs = dirtyConfigs.map(currentConfigValue)

        dirtyContexts.removeAll()
        dirtyTenants.removeAll()
        deletedTenants.removeAll()
        dirtyOwnership.removeAll()
        deletedOwnership.removeAll()
        dirtyConfigs.removeAll()
        return batch
    }

    var dirtyEntityCount: Int {
        dirtyContexts.count + dirtyTenants.count + deletedTenants.count
            + dirtyOwnership.count + deletedOwnership.count + dirtyConfigs.count
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
        case .processedPayments:
            return .processedPayments(processedPaymentChargeIDs)
        case .pollingOffset:
            return .pollingOffset(pollingOffsetValue ?? 0)
        case .chatMeta:
            var byStringKey: [String: ChatMetaInfo] = [:]
            for (chatID, info) in chatMetaByID { byStringKey[String(chatID)] = info }
            return .chatMeta(byStringKey)
        case .invites:
            return .invites(inviteRecords)
        case .ads:
            return .ads(adCampaignList)
        case .markup:
            return .markup(markupPercentValue)
        case .balances:
            return .balances(userBalances)
        case .funnel:
            return .funnel(funnelCounters)
        case .funnelDaily:
            return .funnelDaily(funnelDailyValue)
        case .dailyPremiumLimit:
            return .dailyPremiumLimit(dailyPremiumLimitValue)
        case .dailyPremiumUsage:
            return .dailyPremiumUsage(premiumDailyUsage)
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
        case .referralLedger:
            return .referralLedger(referralLedgerValue)
        case .trafficSources:
            return .trafficSources(trafficSourceLedgerValue)
        case .userDirectory:
            return .userDirectory(userDirectoryValue)
        }
    }

    /// Queues the whole current state for the next flush. Used right after a
    /// legacy-snapshot import so every entity lands in the new tables.
    func markAllDirty() {
        dirtyContexts.formUnion(contexts.keys)
        dirtyTenants.formUnion(tenants.keys)
        dirtyOwnership.formUnion(chatOwnership.keys)
        dirtyConfigs.formUnion(GlobalConfigKey.allCases)
    }

    // MARK: - Payment idempotency

    func isPaymentProcessed(chargeID: String) -> Bool {
        processedPaymentChargeIDs.contains(chargeID)
    }

    func markPaymentProcessed(chargeID: String) {
        guard !processedPaymentChargeIDs.contains(chargeID) else { return }
        processedPaymentChargeIDs.append(chargeID)
        if processedPaymentChargeIDs.count > 500 {
            processedPaymentChargeIDs.removeFirst(processedPaymentChargeIDs.count - 500)
        }
        dirtyConfigs.insert(.processedPayments)
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

    // MARK: - Row-based restore (new schema)

    func restore(from state: PersistedBotState) {
        // The directory comes first: `defaultOwnerKey` / `rootSuperAdminKey`
        // resolve through it, so seeding the owner rows before it is loaded
        // would file them under the wrong key until that person next writes.
        userDirectoryValue = state.configs.userDirectory ?? .empty

        contexts.removeAll()
        for row in state.contexts {
            contexts[row.key] = makeContext(from: row.snapshot)
        }

        tenants.removeAll()
        for row in state.tenants {
            tenants[row.username.lowercased()] = makeTenant(from: row.snapshot)
        }
        ensureDefaultOwnerTenant()

        chatOwnership.removeAll()
        for row in state.ownership {
            chatOwnership[row.chatID] = row.owner.lowercased()
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
        _cardConfig = state.configs.card ?? .empty
        processedPaymentChargeIDs = state.configs.processedPayments ?? []
        pollingOffsetValue = state.configs.pollingOffset

        chatMetaByID = [:]
        for (key, info) in state.configs.chatMeta ?? [:] {
            if let chatID = Int(key) { chatMetaByID[chatID] = info }
        }
        inviteRecords = state.configs.invites ?? [:]
        adCampaignList = state.configs.ads ?? []
        markupPercentValue = state.configs.markup ?? 30
        userBalances = state.configs.balances ?? [:]
        funnelCounters = state.configs.funnel ?? [:]
        funnelDailyValue = state.configs.funnelDaily ?? .empty
        dailyPremiumLimitValue = state.configs.dailyPremiumLimit ?? 5
        // Yesterday's counters are dead weight — a restore is as good a moment
        // to drop them as a write is.
        premiumDailyUsage = (state.configs.dailyPremiumUsage ?? [:])
            .filter { $0.value.day == FunnelDailyLog.dayNumber() }
        selfPromoConfigValue = (state.configs.selfPromo ?? .default).normalized
        modeConfigValue = (state.configs.modes ?? .default).normalized
        reminderConfigValue = (state.configs.reminders ?? .default).normalized
        onboardingConfigValue = (state.configs.onboarding ?? .default).normalized
        referralConfigValue = (state.configs.referrals ?? .default).normalized
        referralLedgerValue = state.configs.referralLedger ?? .empty
        trafficSourceLedgerValue = state.configs.trafficSources ?? .empty
    }

    // MARK: - Legacy snapshot restore (one-time migration path)

    func restoreFromSnapshot(_ snapshot: BotStateSnapshot) {
        contexts.removeAll()
        for (key, ctxSnapshot) in snapshot.contexts {
            guard let chatKey = ChatKey(snapshotKey: key) else { continue }
            contexts[chatKey] = makeContext(from: ctxSnapshot)
        }

        chatOwnership.removeAll()
        for (chatIDStr, owner) in snapshot.chatOwnership ?? [:] {
            if let chatID = Int(chatIDStr) {
                chatOwnership[chatID] = owner.lowercased()
            }
        }

        tenants.removeAll()
        if let tenantsSnapshot = snapshot.tenants, !tenantsSnapshot.isEmpty {
            for (owner, ts) in tenantsSnapshot {
                tenants[owner] = makeTenant(from: ts)
            }
        } else {
            // Migrate from pre-tenant snapshot format
            tenants[defaultOwnerKey] = TenantState(
                ownerUsername: defaultOwnerKey,
                defaultModel: snapshot.defaultModel ?? initialDefaultModel,
                defaultRole: snapshot.defaultRole ?? initialDefaultRole,
                defaultHistoryLength: snapshot.defaultHistoryLength ?? initialDefaultHistoryLength,
                modelPresets: snapshot.modelPresets ?? [],
                tempPresets: snapshot.tempPresets ?? [],
                historyLengthPresets: snapshot.historyLengthPresets ?? [],
                rolePresets: snapshot.rolePresets ?? [],
                whitelistedUserIDs: Set(snapshot.whitelistedUserIDs ?? []),
                adminUsernames: Set(
                    (snapshot.adminUsernames ?? [])
                        .map { $0.lowercased() }
                        .filter { $0 != defaultOwnerKey }
                ),
                licensedUsernames: [],
                cumulativeUsage: .zero,
                createdAt: Date(),
                paidUntil: nil
            )
        }
        ensureDefaultOwnerTenant()

        superAdminUsernames = [rootSuperAdminKey]
        for u in snapshot.superAdminUsernames ?? [] {
            let lc = u.lowercased()
            if !lc.isEmpty { superAdminUsernames.insert(lc) }
        }

        rebuildUserTenantMap()

        _starsPrice = snapshot.starsPrice
        _freeModelIDs = snapshot.freeModelIDs ?? []
        restoreCryptoConfig(snapshot.crypto)
        pollingOffsetValue = snapshot.telegramUpdateOffset
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
