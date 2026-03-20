import Foundation

actor SessionRegistry {
    enum CancellationReason: Sendable, Equatable {
        case userRequested
    }
    
    private struct ActiveSession {
        let chatKey: ChatKey
        var task: Task<Void, Never>?
    }
    
    private var sessions: [GenerationID: ActiveSession] = [:]
    private var cancellationReasons: [GenerationID: CancellationReason] = [:]
    
    func register(chatKey: ChatKey) -> GenerationID {
        let generationID = GenerationID()
        sessions[generationID] = .init(chatKey: chatKey, task: nil)
        return generationID
    }
    
    func attach(generationID: GenerationID, task: Task<Void, Never>) {
        guard var existing = sessions[generationID] else {
            task.cancel()
            return
        }
        existing.task = task
        sessions[generationID] = existing
    }
    
    func finish(generationID: GenerationID) {
        cancellationReasons.removeValue(forKey: generationID)
        sessions[generationID] = nil
    }
    
    func cancel(generationID: GenerationID, reason: CancellationReason = .userRequested) -> ChatKey? {
        if let session = sessions[generationID] {
            cancellationReasons[generationID] = reason
            session.task?.cancel()
            sessions[generationID] = nil
            return session.chatKey
        }
        
        return nil
    }
    
    func cancellationReason(for generationID: GenerationID) -> CancellationReason? {
        cancellationReasons[generationID]
    }
}
