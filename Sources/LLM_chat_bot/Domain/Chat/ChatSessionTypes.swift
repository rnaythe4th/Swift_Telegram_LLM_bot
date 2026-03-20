import Foundation

public struct ChatKey: Hashable, Codable, Sendable {
    public let chatID: Int
    public let threadID: Int64
    
    public init(chatID: Int, threadID: Int64) {
        self.chatID = chatID
        self.threadID = threadID
    }
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
