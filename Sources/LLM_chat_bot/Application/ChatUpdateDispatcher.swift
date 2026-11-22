import Foundation

/// Serializes message handling per chat (so history/settings can never
/// interleave within one chat) while different chats run fully in parallel.
///
/// The per-chat queue is bounded: a chat flooding the bot cannot grow an
/// unbounded task chain and eat memory for everyone else.
actor ChatUpdateDispatcher {
    enum SubmitResult: Sendable {
        case accepted
        /// Queue full — update dropped. `shouldNotify` is true only for the
        /// first drop of a burst so the chat gets exactly one warning.
        case rejected(shouldNotify: Bool)
    }

    private struct PendingOperation {
        let token: UUID
        let task: Task<Void, Never>
    }

    private let maxQueuedPerChat: Int
    private var pendingByChat: [ChatKey: PendingOperation] = [:]
    private var queueDepth: [ChatKey: Int] = [:]
    private var notifiedFullChats: Set<ChatKey> = []

    init(maxQueuedPerChat: Int = 16) {
        self.maxQueuedPerChat = maxQueuedPerChat
    }

    @discardableResult
    func submit(chatKey: ChatKey, operation: @escaping @Sendable () async -> Void) -> SubmitResult {
        schedule(chatKey: chatKey, operation: operation).0
    }

    func submitAndWait(
        chatKey: ChatKey, operation: @escaping @Sendable () async -> Void
    ) async -> SubmitResult {
        let (result, task) = schedule(chatKey: chatKey, operation: operation)
        await task?.value
        return result
    }

    private func schedule(
        chatKey: ChatKey, operation: @escaping @Sendable () async -> Void
    ) -> (SubmitResult, Task<Void, Never>?) {
        let depth = queueDepth[chatKey] ?? 0
        if depth >= maxQueuedPerChat {
            let shouldNotify = !notifiedFullChats.contains(chatKey)
            notifiedFullChats.insert(chatKey)
            return (.rejected(shouldNotify: shouldNotify), nil)
        }
        queueDepth[chatKey] = depth + 1

        let previousTask = pendingByChat[chatKey]?.task
        let token = UUID()

        let task = Task { [self] in
            if let previousTask {
                await previousTask.value
            }

            await operation()
            finishOperation(chatKey: chatKey, token: token)
        }

        pendingByChat[chatKey] = PendingOperation(token: token, task: task)
        return (.accepted, task)
    }

    private func finishOperation(chatKey: ChatKey, token: UUID) {
        let depth = (queueDepth[chatKey] ?? 1) - 1
        if depth <= 0 {
            queueDepth.removeValue(forKey: chatKey)
            notifiedFullChats.remove(chatKey)
        } else {
            queueDepth[chatKey] = depth
        }

        if pendingByChat[chatKey]?.token == token {
            pendingByChat.removeValue(forKey: chatKey)
        }
    }

    var totalQueuedOperations: Int {
        queueDepth.values.reduce(0, +)
    }
}
