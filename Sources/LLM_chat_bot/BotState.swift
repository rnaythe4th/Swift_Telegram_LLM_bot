import Foundation

struct ChatContext {
    var role: String
    var history: [ChatMessage]
    var model: String
    var temp: Float
    var showStats: Bool
    var maxHistory: Int
    var showCost: Bool
    var showModel: Bool
    var provider: ServiceProvider
}

struct GenerationStateSnapshot: Sendable {
    let provider: ServiceProvider
    let model: String
    let temperature: Float
    let showStats: Bool
    let messages: [ChatMessage]
    let showCost: Bool
    let showModel: Bool
}

actor ChatContextStore {
    private var contexts: [StreamKey: ChatContext] = [:]
    let defaultHistoryLength: Int
    var serviceProvider: ServiceProvider = .openrouter
    let defaultModel: String

    let systemPrompt: String
    let formatOptions: String
    let companyChatId: Int
    let companyMembers: String

    init(model: String, systemPrompt: String, formatOptions: String, companyChatId: Int, companyMembers: String, defaultHistoryLength: Int) {
        self.systemPrompt = systemPrompt
        self.formatOptions = formatOptions
        self.companyChatId = companyChatId
        self.companyMembers = companyMembers
        self.defaultHistoryLength = defaultHistoryLength
        self.defaultModel = model
    }

    private func key(chatID: Int, thread_id: Int64) -> StreamKey {
        .init(chatID: chatID, threadID: thread_id)
    }

    private func roleWithCompanyMembers(chatID: Int, role: String) -> String {
        (chatID == companyChatId) ? role + companyMembers : role
    }

    func defaultRole(chatID: Int) -> String {
        roleWithCompanyMembers(chatID: chatID, role: systemPrompt + formatOptions)
    }

    private func ensureContext(chatID: Int, thread_id: Int64) -> StreamKey {
        let contextKey = key(chatID: chatID, thread_id: thread_id)
        if contexts[contextKey] == nil {
            let role = defaultRole(chatID: chatID)
            contexts[contextKey] = ChatContext(
                role: role,
                history: [.init(role: "system", content: role)],
                model: defaultModel,
                temp: 1.5,
                showStats: false,
                maxHistory: defaultHistoryLength,
                showCost: false,
                showModel: true,
                provider: self.serviceProvider
            )
        }
        return contextKey
    }

    private func getContext(chatID: Int, thread_id: Int64) -> ChatContext {
        let contextKey = ensureContext(chatID: chatID, thread_id: thread_id)
        return contexts[contextKey]!
    }

    private func mutateContext(chatID: Int, thread_id: Int64, _ mutate: (inout ChatContext) -> Void) {
        let contextKey = ensureContext(chatID: chatID, thread_id: thread_id)
        var context = contexts[contextKey]!
        mutate(&context)
        contexts[contextKey] = context
    }

    func getCurrentMaxHistory(chatID: Int, thread_id: Int64) -> Int {
        getContext(chatID: chatID, thread_id: thread_id).maxHistory
    }
    
    func setMaxHistory(chatID: Int, thread_id: Int64, newMax: Int) {
        mutateContext(chatID: chatID, thread_id: thread_id) {
            $0.maxHistory = newMax
        }
    }
    
    func getCurrentRole(chatID: Int, thread_id: Int64) -> String {
        getContext(chatID: chatID, thread_id: thread_id).role
    }

    func setRoleAndResetHistory(chatID: Int, thread_id: Int64, role: String) -> String {
        let contextKey = ensureContext(chatID: chatID, thread_id: thread_id)
        var context = contexts[contextKey]!
        let effectiveRole = roleWithCompanyMembers(chatID: chatID, role: role)

        context.role = effectiveRole
        context.history = [.init(role: "system", content: effectiveRole)]
        contexts[contextKey] = context

        return effectiveRole
    }

    func clearHistory(chatID: Int, thread_id: Int64) {
        let contextKey = ensureContext(chatID: chatID, thread_id: thread_id)
        var context = contexts[contextKey]!
        context.history = [.init(role: "system", content: context.role)]
        contexts[contextKey] = context
    }

    func appendAssistant(chatID: Int, thread_id: Int64, content: String) {
        mutateContext(chatID: chatID, thread_id: thread_id) { context in
            context.history.append(.init(role: "assistant", content: content))
        }
    }

    func temp(chatID: Int, thread_id: Int64) -> Float {
        getContext(chatID: chatID, thread_id: thread_id).temp
    }

    func setTemp(chatID: Int, thread_id: Int64, value: Float) {
        mutateContext(chatID: chatID, thread_id: thread_id) {
            $0.temp = value
        }
    }
    
    func getCurrentModel(chatID: Int, thread_id: Int64) -> String {
        getContext(chatID: chatID, thread_id: thread_id).model
    }

    func setModelAndResetHistory(chatID: Int, thread_id: Int64, newModel: String) -> (oldModel: String, newModel: String) {
        let contextKey = ensureContext(chatID: chatID, thread_id: thread_id)
        var context = contexts[contextKey]!
        let oldModel = context.model

        context.model = newModel
        context.history = [.init(role: "system", content: context.role)]
        contexts[contextKey] = context

        return (oldModel: oldModel, newModel: context.model)
    }
    
    func getShowStats(chatID: Int, thread_id: Int64) -> Bool {
        getContext(chatID: chatID, thread_id: thread_id).showStats
    }

    func toggleShowStats(chatID: Int, thread_id: Int64) -> Bool {
        var newValue = false
        mutateContext(chatID: chatID, thread_id: thread_id) { context in
            context.showStats.toggle()
            newValue = context.showStats
        }
        return newValue
    }
    
    func getShowCost(chatID: Int, thread_id: Int64) -> Bool {
        getContext(chatID: chatID, thread_id: thread_id).showCost
    }
    
    func toggleShowCost(chatID: Int, thread_id: Int64) -> Bool {
        var newValue: Bool = false
        mutateContext(chatID: chatID, thread_id: thread_id) { context in
            context.showCost.toggle()
            newValue = context.showCost
        }
        return newValue
    }
    
    func getShowModel(chatID: Int, thread_id: Int64) -> Bool {
        getContext(chatID: chatID, thread_id: thread_id).showModel
    }
    
    func toggleShowModel(chatID: Int, thread_id: Int64) -> Bool {
        var newValue: Bool = false
        mutateContext(chatID: chatID, thread_id: thread_id) { context in
            context.showModel.toggle()
            newValue = context.showModel
        }
        return newValue
    }
    
    func changeProvider(chatID: Int, thread_id: Int64, newProvider: ServiceProvider) -> String {
        let oldProvider = getContext(chatID: chatID, thread_id: thread_id).provider.rawValue
        mutateContext(chatID: chatID, thread_id: thread_id) { context in
            context.provider = newProvider
        }
        return oldProvider
    }
    
    func getProvider(chatID: Int, thread_id: Int64) -> ServiceProvider {
        getContext(chatID: chatID, thread_id: thread_id).provider
    }
    
    func prepareGeneration(chatID: Int, thread_id: Int64, userContent: String, username: String?) -> GenerationStateSnapshot {
        let contextKey = ensureContext(chatID: chatID, thread_id: thread_id)
        var context = contexts[contextKey]!

        if context.history.isEmpty {
            context.history = [.init(role: "system", content: context.role)]
        }

        if context.history.count >= context.maxHistory, context.history.count > 1 {
            let hi = min(2, context.history.count - 1)
            context.history.removeSubrange(1...hi)
        }

        context.history.append(.init(role: "user", content: userContent, name: username))
        contexts[contextKey] = context

        return GenerationStateSnapshot(
            provider: context.provider,
            model: context.model,
            temperature: context.temp,
            showStats: context.showStats,
            messages: context.history,
            showCost: context.showCost,
            showModel: context.showModel
        )
    }
}
