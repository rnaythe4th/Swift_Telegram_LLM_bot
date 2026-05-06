import Foundation

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
}

struct GenerationSnapshot: Sendable {
    let provider: ServiceProvider
    let model: String
    let temperature: Float
    let options: GenerationOptions
    let messages: [ChatMessage]
}

struct HelpData: Sendable {
    let model: String
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
    private var contexts: [ChatKey: ChatContext] = [:]
    
    var defaultHistoryLength: Int
    var defaultModel: String
    var systemPrompt: String
    var formatOptions: String
    let companyChatId: Int
    let companyMembers: String
    let defaultSuffix: Int?
    private var adminUsernames: Set<String>
    private var whitelistedUserIDs: Set<Int>
    
    // MARK: Presets
    private var _modelPresets: [Preset] = []
    private var _tempPresets: [Preset] = []
    private var _historyLengthPresets: [Preset] = []
    private var _rolePresets: [Preset] = []
    private var _pendingInputs: [ChatKey: PendingInput] = [:]
    
    init(
        model: String,
        systemPrompt: String,
        formatOptions: String,
        companyChatId: Int,
        companyMembers: String,
        defaultHistoryLength: Int,
        defaultSuffix: Int?
    ) {
        self.defaultModel = model
        self.systemPrompt = systemPrompt
        self.formatOptions = formatOptions
        self.companyChatId = companyChatId
        self.companyMembers = companyMembers
        self.defaultHistoryLength = defaultHistoryLength
        self.defaultSuffix = defaultSuffix
        self.adminUsernames = ["maythe4th"]
        self.whitelistedUserIDs = []
    }
    
    private func roleWithCompanyMembers(chatID: Int, role: String) -> String {
        chatID == companyChatId ? role + companyMembers : role
    }
    
    func defaultRole(chatID: Int) -> String {
        roleWithCompanyMembers(chatID: chatID, role: systemPrompt + formatOptions)
    }
    
    private func ensure(chatKey: ChatKey) -> ChatContext {
        if let context = contexts[chatKey] {
            return context
        }
        
        let role = defaultRole(chatID: chatKey.chatID)
        let context = ChatContext(
            role: role,
            history: [.init(role: "system", content: role)],
            pendingTurns: [],
            model: defaultModel,
            temp: 1.5,
            showStats: false,
            maxHistory: defaultHistoryLength,
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
        return context
    }
    
    private func mutate(chatKey: ChatKey, _ block: (inout ChatContext) -> Void) {
        var context = ensure(chatKey: chatKey)
        block(&context)
        contexts[chatKey] = context
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
    
    func fetchHelp(chatKey: ChatKey) -> HelpData {
        let context = ensure(chatKey: chatKey)
        return .init(
            model: context.model,
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
    
    func setModelAndResetHistory(chatKey: ChatKey, newModel: String) -> (old: String, new: String) {
        let old = ensure(chatKey: chatKey).model
        mutate(chatKey: chatKey) { context in
            context.model = newModel
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
    
    func appendAssistant(chatKey: ChatKey, generationID: GenerationID, content: String, usage: StreamUsageSummary? = nil) {
        mutate(chatKey: chatKey) { context in
            guard let index = context.pendingTurns.firstIndex(where: { $0.generationID == generationID }) else {
                return
            }
            context.pendingTurns[index].state = .completed(content)
            flushResolvedTurns(&context)
            context.cumulativeUsage.totalTokens += usage?.totalTokens ?? 0
            context.cumulativeUsage.totalCost += usage?.cost ?? 0
            context.cumulativeUsage.generationCount += 1
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
        mutate(chatKey: chatKey) { context in
            context.cumulativeUsage.totalTokens += usage?.totalTokens ?? 0
            context.cumulativeUsage.totalCost += usage?.cost ?? 0
            context.cumulativeUsage.generationCount += 1
        }
    }

    func resetUsage(chatKey: ChatKey) {
        mutate(chatKey: chatKey) { $0.cumulativeUsage = .zero }
    }

    func isAdmin(username: String?) -> Bool {
        guard let username else { return false }
        return adminUsernames.contains(username.lowercased())
    }
    
    func isWhitelisted(userID: Int) -> Bool {
        whitelistedUserIDs.contains(userID)
    }
    
    func addToWhitelist(userID: Int) {
        whitelistedUserIDs.insert(userID)
    }
    
    func removeFromWhitelist(userID: Int) {
        whitelistedUserIDs.remove(userID)
    }
    
    func listWhitelisted() -> Set<Int> {
        whitelistedUserIDs
    }
    
    func addAdmin(username: String) {
        adminUsernames.insert(username.lowercased())
    }
    
    func removeAdmin(username: String) {
        adminUsernames.remove(username.lowercased())
    }
    
    func listAdmins() -> Set<String> {
        adminUsernames
    }
    
    func setDefaultModel(_ model: String) -> String {
        defaultModel = model
        return model
    }
    
    func setDefaultRole(_ role: String) -> String {
        systemPrompt = role
        return role
    }
    
    func setDefaultHistoryLength(_ length: Int) -> Int {
        defaultHistoryLength = max(1, length)
        return defaultHistoryLength
    }
    
    func privateChats() -> [(chatID: Int, threadID: Int64)] {
        contexts.keys
            .filter { $0.chatID > 0 }
            .map { (chatID: $0.chatID, threadID: $0.threadID) }
    }
    
    func groupChats() -> [(chatID: Int, threadID: Int64)] {
        contexts.keys
            .filter { $0.chatID < 0 }
            .map { (chatID: $0.chatID, threadID: $0.threadID) }
    }
    
    // MARK: - Preset management
    
    func modelPresets() -> [Preset] { _modelPresets }
    func tempPresets() -> [Preset] { _tempPresets }
    func historyLengthPresets() -> [Preset] { _historyLengthPresets }
    func rolePresets() -> [Preset] { _rolePresets }
    
    func setModelPresets(_ presets: [Preset]) { _modelPresets = presets }
    func setTempPresets(_ presets: [Preset]) { _tempPresets = presets }
    func setHistoryLengthPresets(_ presets: [Preset]) { _historyLengthPresets = presets }
    func setRolePresets(_ presets: [Preset]) { _rolePresets = presets }
    
    func addModelPreset(display: String, value: String) -> Preset {
        let preset = Preset(display: display, value: value)
        _modelPresets.append(preset)
        return preset
    }
    
    func removeModelPreset(value: String) -> Bool {
        let count = _modelPresets.count
        _modelPresets.removeAll { $0.value == value }
        return _modelPresets.count < count
    }
    
    func addTempPreset(display: String, value: String) -> Preset {
        let preset = Preset(display: display, value: value)
        _tempPresets.append(preset)
        return preset
    }
    
    func removeTempPreset(value: String) -> Bool {
        let count = _tempPresets.count
        _tempPresets.removeAll { $0.value == value }
        return _tempPresets.count < count
    }
    
    func addHistoryLengthPreset(display: String, value: String) -> Preset {
        let preset = Preset(display: display, value: value)
        _historyLengthPresets.append(preset)
        return preset
    }
    
    func removeHistoryLengthPreset(value: String) -> Bool {
        let count = _historyLengthPresets.count
        _historyLengthPresets.removeAll { $0.value == value }
        return _historyLengthPresets.count < count
    }
    
    func addRolePreset(display: String, value: String) -> Preset {
        let preset = Preset(display: display, value: value)
        _rolePresets.append(preset)
        return preset
    }
    
    func removeRolePreset(value: String) -> Bool {
        let count = _rolePresets.count
        _rolePresets.removeAll { $0.value == value }
        return _rolePresets.count < count
    }

    // MARK: - Generic preset operations

    func presets(for category: PresetCategory) -> [Preset] {
        switch category {
        case .model: return _modelPresets
        case .temp: return _tempPresets
        case .history: return _historyLengthPresets
        case .role: return _rolePresets
        }
    }

    func addPreset(category: PresetCategory, display: String, value: String) -> Preset {
        let preset = Preset(display: display, value: value)
        switch category {
        case .model: _modelPresets.append(preset)
        case .temp: _tempPresets.append(preset)
        case .history: _historyLengthPresets.append(preset)
        case .role: _rolePresets.append(preset)
        }
        return preset
    }

    func removePresetByIndex(category: PresetCategory, index: Int) -> Bool {
        switch category {
        case .model:
            guard index >= 0, index < _modelPresets.count else { return false }
            _modelPresets.remove(at: index)
        case .temp:
            guard index >= 0, index < _tempPresets.count else { return false }
            _tempPresets.remove(at: index)
        case .history:
            guard index >= 0, index < _historyLengthPresets.count else { return false }
            _historyLengthPresets.remove(at: index)
        case .role:
            guard index >= 0, index < _rolePresets.count else { return false }
            _rolePresets.remove(at: index)
        }
        return true
    }

    func editPreset(category: PresetCategory, index: Int, display: String, value: String) -> Bool {
        let preset = Preset(display: display, value: value)
        switch category {
        case .model:
            guard index >= 0, index < _modelPresets.count else { return false }
            _modelPresets[index] = preset
        case .temp:
            guard index >= 0, index < _tempPresets.count else { return false }
            _tempPresets[index] = preset
        case .history:
            guard index >= 0, index < _historyLengthPresets.count else { return false }
            _historyLengthPresets[index] = preset
        case .role:
            guard index >= 0, index < _rolePresets.count else { return false }
            _rolePresets[index] = preset
        }
        return true
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

    func addChatPreset(category: PresetCategory, chatKey: ChatKey, display: String, value: String) -> Preset {
        let preset = Preset(display: display, value: value)
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

    func editChatPreset(category: PresetCategory, chatKey: ChatKey, index: Int, display: String, value: String) -> Bool {
        let preset = Preset(display: display, value: value)
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
    
    func getDefaults() -> (model: String, role: String, historyLength: Int) {
        (defaultModel, systemPrompt, defaultHistoryLength)
    }
    
    func chatsWithBackupNotify() -> [ChatKey] {
        contexts.filter { $0.value.backupNotify }.map(\.key)
    }

    func history(chatKey: ChatKey) -> [ChatMessage] {
        ensure(chatKey: chatKey).history
    }

    func resetChat(chatKey: ChatKey) {
        let role = defaultRole(chatID: chatKey.chatID)
        contexts[chatKey] = ChatContext(
            role: role,
            history: [.init(role: "system", content: role)],
            pendingTurns: [],
            model: defaultModel,
            temp: 1.5,
            showStats: false,
            maxHistory: defaultHistoryLength,
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
    }

    func exportSnapshot(telegramUpdateOffset: Int) -> BotStateSnapshot {
        var ctxSnapshots: [String: ChatContextSnapshot] = [:]
        for (chatKey, context) in contexts {
            ctxSnapshots[chatKey.snapshotKey] = ChatContextSnapshot(
                role: context.role,
                history: context.history,
                model: context.model,
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
                chatRolePresets: context.chatRolePresets.isEmpty ? nil : context.chatRolePresets
            )
        }
        return BotStateSnapshot(
            contexts: ctxSnapshots,
            whitelistedUserIDs: Array(whitelistedUserIDs),
            adminUsernames: Array(adminUsernames),
            defaultModel: defaultModel,
            defaultRole: systemPrompt,
            defaultHistoryLength: defaultHistoryLength,
            telegramUpdateOffset: telegramUpdateOffset,
            modelPresets: _modelPresets,
            tempPresets: _tempPresets,
            historyLengthPresets: _historyLengthPresets,
            rolePresets: _rolePresets
        )
    }

    func restoreFromSnapshot(_ snapshot: BotStateSnapshot) {
        defaultModel = snapshot.defaultModel
        systemPrompt = snapshot.defaultRole
        defaultHistoryLength = snapshot.defaultHistoryLength
        adminUsernames = Set(snapshot.adminUsernames)
        whitelistedUserIDs = Set(snapshot.whitelistedUserIDs)
        _modelPresets = snapshot.modelPresets
        _tempPresets = snapshot.tempPresets
        _historyLengthPresets = snapshot.historyLengthPresets
        _rolePresets = snapshot.rolePresets

        contexts.removeAll()
        for (key, ctxSnapshot) in snapshot.contexts {
            guard let chatKey = ChatKey(snapshotKey: key) else { continue }
            contexts[chatKey] = ChatContext(
                role: ctxSnapshot.role,
                history: ctxSnapshot.history,
                pendingTurns: [],
                model: ctxSnapshot.model,
                temp: ctxSnapshot.temp,
                showStats: ctxSnapshot.showStats,
                maxHistory: ctxSnapshot.maxHistory,
                showCost: ctxSnapshot.showCost,
                showModel: ctxSnapshot.showModel,
                provider: ctxSnapshot.provider,
                suffix: ctxSnapshot.suffix,
                reasoningEffort: ctxSnapshot.reasoningEffort,
                backupNotify: ctxSnapshot.backupNotify,
                cumulativeUsage: ctxSnapshot.cumulativeUsage ?? .zero,
                chatModelPresets: ctxSnapshot.chatModelPresets ?? [],
                chatTempPresets: ctxSnapshot.chatTempPresets ?? [],
                chatHistoryLengthPresets: ctxSnapshot.chatHistoryLengthPresets ?? [],
                chatRolePresets: ctxSnapshot.chatRolePresets ?? []
            )
        }
    }
}
