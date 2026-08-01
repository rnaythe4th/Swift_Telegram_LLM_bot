import Foundation

public struct ChatKey: Hashable, Codable, Sendable {
    public let chatID: Int
    public let threadID: Int64
    
    public init(chatID: Int, threadID: Int64) {
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
