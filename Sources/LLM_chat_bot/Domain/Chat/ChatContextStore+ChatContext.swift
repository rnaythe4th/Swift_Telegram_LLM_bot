import Foundation

// Per-chat context: creation, history trimming, pending turns, the settings
// mutations behind /model, /settemp & co.

extension ChatContextStore {
    // MARK: - Chat context helpers

    func roleWithCompanyMembers(chatID: Int, role: String) -> String {
        chatID == companyChatId ? role + companyMembers : role
    }

    func ensure(chatKey: ChatKey) -> ChatContext {
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

    func mutate(chatKey: ChatKey, _ block: (inout ChatContext) -> Void) {
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
        mutate(chatKey: chatKey) {
            $0.reasoningEffort = effort
            $0.activeModeID = nil
        }
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
            // Hand-edited: the chat no longer matches the mode it was in.
            context.activeModeID = nil
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
        mutate(chatKey: chatKey) {
            $0.temp = value
            $0.activeModeID = nil
        }
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
            context.activeModeID = nil
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

    /// Records the answer and its usage. Charging is *not* here: money moves
    /// through a ledger transaction, and the coordinator applies what was
    /// committed with `applyCommittedCharge`. Returns what the turn cost, so
    /// the caller knows what to charge.
    func appendAssistant(
        chatKey: ChatKey,
        generationID: GenerationID,
        content: String,
        usage: StreamUsageSummary? = nil
    ) -> (real: Money, billed: Money) {
        let real = Money.usd(usage?.cost ?? 0)
        let billed = real.multiplied(byPercent: markupPercentValue)
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
        recordProviderSpend(chatID: chatKey.chatID, real: real)
        return (real, billed)
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
        let markup = markupPercentValue
        mutate(chatKey: chatKey) { context in
            context.cumulativeUsage.add(usage, markupPercent: markup)
        }
        accumulateTenantUsage(chatID: chatKey.chatID, usage: usage)
    }

    func resetUsage(chatKey: ChatKey) {
        mutate(chatKey: chatKey) { $0.cumulativeUsage = .zero }
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

    func history(chatKey: ChatKey) -> [ChatMessage] {
        ensure(chatKey: chatKey).history
    }

    /// "↺ Сбросить": back to the settings the bot ships with.
    ///
    /// Deliberately *not* a wipe. The chat's own presets and its usage totals
    /// are not settings — they are things the chat accumulated, and the button
    /// says "сбросить настройки", not "стереть всё" (`/reset_stats` exists for
    /// the totals). Throwing them away silently is what this used to do.
    func resetChat(chatKey: ChatKey) {
        let tenant = tenantState(for: chatKey.chatID)
        let role = roleWithCompanyMembers(chatID: chatKey.chatID, role: tenant.defaultRole + formatOptions)
        let previous = contexts[chatKey]
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
            cumulativeUsage: previous?.cumulativeUsage ?? .zero,
            chatModelPresets: previous?.chatModelPresets ?? [],
            chatTempPresets: previous?.chatTempPresets ?? [],
            chatHistoryLengthPresets: previous?.chatHistoryLengthPresets ?? [],
            chatRolePresets: previous?.chatRolePresets ?? []
        )
        dirtyContexts.insert(chatKey)
        // "Стандартные настройки" means the working mode, when there is one:
        // the tenant defaults are a bare model id, the mode is the combination
        // the owner actually vouches for.
        if let working = modeConfigValue.defaultMode {
            applyMode(chatKey: chatKey, modeID: working.id)
        }
    }
}
