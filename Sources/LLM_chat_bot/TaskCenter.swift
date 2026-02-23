import Foundation

actor TaskCenter {
    private var tasks: [StreamKey: Task<Void, Never>] = [:]

    func register(key: StreamKey, task: Task<Void, Never>) {
        tasks[key] = task
        print("[TaskCenter] register key=\(key), active=\(tasks.count)")
    }

    func cancel(key: StreamKey) {
        print("[TaskCenter] cancel key=\(key), hadTask=\(tasks[key] != nil)")
        tasks[key]?.cancel()
        tasks[key] = nil
        print("[TaskCenter] active after cancel=\(tasks.count)")
    }

    func cancelAll(in chatID: Int, threadID: Int64) {
        print("[TaskCenter] cancelAll chatID=\(chatID), threadID=\(threadID), activeBefore=\(tasks.count)")
        for (k, t) in tasks where k.chatID == chatID && k.threadID == threadID {
            t.cancel()
            tasks[k] = nil
            print("[TaskCenter] cancelled key=\(k)")
        }
        print("[TaskCenter] active after cancelAll=\(tasks.count)")
    }

    func latest(for chatID: Int, threadID: Int64) -> StreamKey? {
        // Not strictly LIFO, but returning any one active key is fine for /stop.
        return tasks.keys.first(where: { $0.chatID == chatID && $0.threadID == threadID })
    }
}
