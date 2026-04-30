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
    var reasoning: Bool
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
    let reasoning: Bool
    let testModeSuffix: Int?
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
            reasoning: false
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
            reasoning: context.reasoning,
            testModeSuffix: context.suffix
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
    
    func toggleReasoning(chatKey: ChatKey) -> Bool {
        mutate(chatKey: chatKey) { $0.reasoning.toggle() }
        return ensure(chatKey: chatKey).reasoning
    }
    
    func setReasoning(chatKey: ChatKey, enabled: Bool) {
        mutate(chatKey: chatKey) { $0.reasoning = enabled }
    }
    
    func reasoningEnabled(chatKey: ChatKey) -> Bool {
        ensure(chatKey: chatKey).reasoning
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
                reasoningEnabled: context.reasoning
            ),
            messages: messages
        )
    }
    
    func appendAssistant(chatKey: ChatKey, generationID: GenerationID, content: String) {
        mutate(chatKey: chatKey) { context in
            guard let index = context.pendingTurns.firstIndex(where: { $0.generationID == generationID }) else {
                return
            }
            
            context.pendingTurns[index].state = .completed(content)
            flushResolvedTurns(&context)
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
    
    func getDefaults() -> (model: String, role: String, historyLength: Int) {
        (defaultModel, systemPrompt, defaultHistoryLength)
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
            reasoning: false
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
                reasoning: context.reasoning
            )
        }
        return BotStateSnapshot(
            contexts: ctxSnapshots,
            whitelistedUserIDs: Array(whitelistedUserIDs),
            adminUsernames: Array(adminUsernames),
            defaultModel: defaultModel,
            defaultRole: systemPrompt,
            defaultHistoryLength: defaultHistoryLength,
            telegramUpdateOffset: telegramUpdateOffset
        )
    }

    func restoreFromSnapshot(_ snapshot: BotStateSnapshot) {
        defaultModel = snapshot.defaultModel
        systemPrompt = snapshot.defaultRole
        defaultHistoryLength = snapshot.defaultHistoryLength
        adminUsernames = Set(snapshot.adminUsernames)
        whitelistedUserIDs = Set(snapshot.whitelistedUserIDs)

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
                reasoning: ctxSnapshot.reasoning
            )
        }
    }
}
