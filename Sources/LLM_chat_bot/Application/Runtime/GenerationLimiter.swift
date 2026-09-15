import Foundation

/// FIFO semaphore capping the number of concurrent LLM streams. Protects the
/// process from memory/socket exhaustion when hundreds of chats fire at once;
/// excess generations wait their turn (per-chat ordering is preserved by
/// ChatUpdateDispatcher upstream).
actor GenerationLimiter {
    private let maxConcurrent: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    func acquire() async {
        if active < maxConcurrent {
            active += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            active = max(0, active - 1)
        } else {
            // Hand the slot directly to the next waiter; `active` stays the same.
            waiters.removeFirst().resume()
        }
    }

    var activeCount: Int { active }
    var waitingCount: Int { waiters.count }
}
