import Foundation

public struct ChatKey: Hashable, Codable, Sendable {
    public let chatID: Int
    public let threadID: Int64
    
    public init(chatID: Int, threadID: Int64) {
        self.chatID = chatID
        self.threadID = threadID
    }

    var snapshotKey: String {
        "\(chatID):\(threadID)"
    }

    init?(snapshotKey: String) {
        let parts = snapshotKey.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let chatID = Int(parts[0]),
              let threadID = Int64(parts[1]) else { return nil }
        self.init(chatID: chatID, threadID: threadID)
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
