import Foundation

actor BotState {
    var chatRoles: [Int: [Int64: String]] = [:]
    var chatHistories: [Int: [Int64: [ChatMessage]]] = [:]
    var chatTemps: [Int: [Int64: Float]] = [:]
    var chatShowStats: [Int: [Int64: Bool]] = [:]
    var chatModels: [Int: [Int64: String]] = [:]
    let defaultHistoryLength: Int
    var historyLength: [Int: [Int64: Int]] = [:]
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

    func setMaxHistory(chatID: Int, thread_id: Int64, newMax: Int) {
        if historyLength[chatID] == nil { historyLength[chatID] = [:] }
        historyLength[chatID]![thread_id] = newMax
    }

    func ensureMaxHistory(chatID: Int, thread_id: Int64) -> Int {
        if historyLength[chatID] == nil {
            setMaxHistory(chatID: chatID, thread_id: thread_id, newMax: defaultHistoryLength)
        }
        return historyLength[chatID]![thread_id]!
    }

    func setRole(chatID: Int, thread_id: Int64, role: String) {
        if chatRoles[chatID] == nil { chatRoles[chatID] = [:] }
        chatRoles[chatID]![thread_id] = (chatID == companyChatId) ? role + companyMembers : role
    }

    func ensureRole(chatID: Int, thread_id: Int64) -> String {
        if chatRoles[chatID]?[thread_id] == nil {
            setRole(chatID: chatID, thread_id: thread_id, role: systemPrompt + formatOptions)
        }
        return chatRoles[chatID]![thread_id]!
    }

    func resetHistory(chatID: Int, thread_id: Int64, role: String) {
        if chatHistories[chatID] == nil { chatHistories[chatID] = [:] }
        chatHistories[chatID]![thread_id] = [.init(role: "system", content: role)]
    }

    func ensureHistory(chatID: Int, thread_id: Int64) {
        if chatHistories[chatID] == nil { chatHistories[chatID] = [:] }
        if chatHistories[chatID]![thread_id] == nil {
            let role = ensureRole(chatID: chatID, thread_id: thread_id)
            chatHistories[chatID]![thread_id] = [.init(role: "system", content: role)]
        }
    }

    func trimHistoryIfNeeded(chatID: Int, thread_id: Int64) {
        guard var arr = chatHistories[chatID]?[thread_id] else { return }
        if arr.count >= ensureMaxHistory(chatID: chatID, thread_id: thread_id), arr.count > 1 {
            // оставляем системное 0, удаляем 1..2
            let hi = min(2, arr.count - 1)
            arr.removeSubrange(1...hi)
            chatHistories[chatID]![thread_id] = arr
        }
    }

    func appendUser(chatID: Int, thread_id: Int64, content: String, username: String?) {
        chatHistories[chatID]![thread_id]!.append(.init(role: "user", content: content, name: username))
    }

    func appendAssistant(chatID: Int, thread_id: Int64, content: String) {
        chatHistories[chatID]![thread_id]!.append(.init(role: "assistant", content: content))
    }

    func temp(chatID: Int, thread_id: Int64) -> Float {
        chatTemps[chatID]?[thread_id] ?? 1.5
    }

    func setTemp(chatID: Int, thread_id: Int64, value: Float) {
        if chatTemps[chatID] == nil { chatTemps[chatID] = [:] }
        chatTemps[chatID]![thread_id] = value
    }

    func setModel(chatID: Int, thread_id: Int64, newModel: String) -> String {
        let currentModel = ensureModel(chatID: chatID, thread_id: thread_id)
        if chatModels[chatID] == nil { chatModels[chatID] = [:] }
        chatModels[chatID]![thread_id] = newModel
        return currentModel
    }

    func ensureModel(chatID: Int, thread_id: Int64) -> String {
        if chatModels[chatID] == nil { chatModels[chatID] = [:] }
        if chatModels[chatID]![thread_id] == nil {
            chatModels[chatID]![thread_id] = defaultModel
        }
        return chatModels[chatID]![thread_id]!
    }

    func model(chatID: Int, thread_id: Int64) -> String {
        ensureModel(chatID: chatID, thread_id: thread_id)
    }

    func showStats(chatID: Int, thread_id: Int64) -> Bool {
        chatShowStats[chatID]?[thread_id] ?? false
    }

    func toggleShowStats(chatID: Int, thread_id: Int64) -> Bool {
        if chatShowStats[chatID] == nil { chatShowStats[chatID] = [:] }
        let new = !(chatShowStats[chatID]![thread_id] ?? false)
        chatShowStats[chatID]![thread_id] = new
        return new
    }

    func messages(chatID: Int, thread_id: Int64) -> [ChatMessage] {
        chatHistories[chatID]![thread_id]!
    }
}
