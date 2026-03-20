import Foundation

actor ChatUpdateDispatcher {
    private struct PendingOperation {
        let token: UUID
        let task: Task<Void, Never>
    }
    
    private var pendingByChat: [ChatKey: PendingOperation] = [:]
    
    func submit(chatKey: ChatKey, operation: @escaping @Sendable () async -> Void) {
        let previousTask = pendingByChat[chatKey]?.task
        let token = UUID()
        
        let task = Task { [self] in
            if let previousTask {
                await previousTask.value
            }
            
            await operation()
            clearIfCurrent(chatKey: chatKey, token: token)
        }
        
        pendingByChat[chatKey] = PendingOperation(token: token, task: task)
    }
    
    private func clearIfCurrent(chatKey: ChatKey, token: UUID) {
        guard pendingByChat[chatKey]?.token == token else {
            return
        }
        
        pendingByChat.removeValue(forKey: chatKey)
    }
}
