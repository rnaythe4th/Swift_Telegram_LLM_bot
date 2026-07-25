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
    
    /// Cancels a generation and hands back its chat. The session stays
    /// registered until the stream task actually unwinds through `finish` —
    /// dropping it here would make `activeCount` read zero while the answer is
    /// still being written to history, and graceful shutdown waits on that
    /// count. A second tap on «Стоп» finds the session already cancelled and
    /// gets nil, so the chat is not told twice.
    func cancel(generationID: GenerationID, reason: CancellationReason = .userRequested) -> ChatKey? {
        guard let session = sessions[generationID], cancellationReasons[generationID] == nil else { return nil }
        cancellationReasons[generationID] = reason
        session.task?.cancel()
        return session.chatKey
    }
    
    func cancellationReason(for generationID: GenerationID) -> CancellationReason? {
        cancellationReasons[generationID]
    }

    /// Number of in-flight generations — used by graceful shutdown to wait for
    /// streams to complete and by /metrics.
    var activeCount: Int {
        sessions.count
    }
}
