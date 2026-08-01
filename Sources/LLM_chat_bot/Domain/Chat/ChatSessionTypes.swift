import Foundation

/// One conversation context: a chat, and the forum topic inside it. Topics keep
/// separate memory, so the pair is the key.
struct ChatKey: Hashable, Codable, Sendable {
    let chatID: ChatID
    let threadID: Int64

    init(chatID: ChatID, threadID: Int64) {
        self.chatID = chatID
        self.threadID = threadID
    }

    /// Forum topics are separate contexts; thread 0 is the main one.
    var isThread: Bool { threadID != 0 }
}

struct GenerationID: Hashable, Sendable {
    let raw: UUID

    init() {
        self.raw = UUID()
    }

    init(raw: UUID) {
        self.raw = raw
    }
}
