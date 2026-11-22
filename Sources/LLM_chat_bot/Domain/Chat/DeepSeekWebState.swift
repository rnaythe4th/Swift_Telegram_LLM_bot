import Foundation

struct DeepSeekWebAccount: Codable, Sendable {
    var epoch = UUID()
    var workerMarker: UUID?
    var quotaUntil: Date?
    var busyUntil: Date?
}

struct DeepSeekWebOperation: Codable, Sendable {
    enum Stage: String, Codable, Sendable {
        case queued, sending, confirmed, delivering
    }

    let id: UUID
    let contextEpoch: UUID
    let updateID: Int64
    let question: String
    let role: String
    let asker: String?
    let messageID: Int
    let telegramThreadID: Int64?
    let replyToMessageID: Int?
    let createdAt: Date
    let listening: [DeepSeekWebTranscriptLine]
    let listeningThrough: Int
    let reply: DeepSeekWebQuote?
    let deepThink: Bool?

    var requesterID: UserID?
    var stage: Stage = .queued
    var workerOperationID: UUID?
    var candidateRemoteChatID: String?
    var prompt: String?
    var remoteChatID: String?
    var remoteTail: String?
    var response: String?
    var deliveryMessageIDs: [Int] = []
    var deliveryInFlight: Bool?
    var plannedListeningThrough: Int?
    var sentListeningSequences: [Int] = []
    var usedListening = false
}

struct DeepSeekWebQuote: Codable, Sendable {
    let sequence: Int?
    let author: String
    let text: String
    let usesListening: Bool
}

struct DeepSeekWebTranscriptLine: Codable, Sendable {
    let sequence: Int
    let messageID: Int
    let timestamp: Date
    let author: String
    let text: String
    let reply: DeepSeekWebQuote?
}

struct DeepSeekWebTurn: Codable, Sendable {
    let question: String
    let answer: String
    let questionMessageID: Int
    let answerMessageIDs: [Int]
    let usesListening: Bool
}

struct DeepSeekWebChatState: Codable, Sendable {
    var version = 1
    var contextEpoch = UUID()
    var revision = UUID()
    var accountEpoch: UUID?
    var remoteChatID: String?
    var remoteTail: String?
    var remoteUnits = 0
    var listeningBoundary = 0
    var listeningThrough = 0
    var sentListeningSequences: [Int] = []
    var nativeMessageIDs: [Int] = []
    var history: [DeepSeekWebTurn] = []
    var operations: [DeepSeekWebOperation] = []
    var usesListening = false
    var hasUncertainDelivery = false
    var groupAllowed = false
    var deepThink: Bool?

    enum CodingKeys: String, CodingKey {
        case version, contextEpoch, revision, accountEpoch, remoteChatID, remoteTail, remoteUnits
        case listeningBoundary, listeningThrough, sentListeningSequences, nativeMessageIDs
        case history, operations, usesListening, hasUncertainDelivery, groupAllowed, deepThink
    }

    mutating func rotate() {
        remoteChatID = nil
        remoteTail = nil
        remoteUnits = 0
        sentListeningSequences = []
        usesListening = false
    }

    mutating func rememberNativeMessages(_ ids: [Int]) {
        nativeMessageIDs = Array((nativeMessageIDs + ids.filter { $0 > 0 }).suffix(900))
    }

    mutating func trimHistory(to limit: Int) {
        var bytes = ChatContext.historyByteBudget
        history = Array(history.suffix(limit).reversed().prefix { turn in
            bytes -= turn.question.utf8.count + turn.answer.utf8.count
            return bytes >= 0
        }.reversed())
    }
}

struct DeepSeekWebPrompt: Sendable {
    let text: String
    let listeningThrough: Int
    let sentListeningSequences: [Int]
    let usedListening: Bool

    static func build(
        operation: DeepSeekWebOperation,
        state: DeepSeekWebChatState,
        maxUTF8Bytes: Int = 12_000,
        maxUTF16Units: Int = 12_000
    ) -> Self? {
        func quote(_ text: String) -> String {
            // Encoding a string escapes newlines and prevents an input value
            // from opening a new section. A Swift String always encodes.
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            return String(decoding: (try? encoder.encode(text)) ?? Data(), as: UTF8.self)
        }

        func fits(_ text: String) -> Bool {
            text.utf8.count <= maxUTF8Bytes && text.utf16.count <= maxUTF16Units
        }

        let role = "Роль бота:\n" + quote(operation.role)
        let asker = operation.asker.map { "Автор: " + quote($0) + "\n" } ?? ""
        let question = "Вопрос:\n" + asker + quote(operation.question)
        let nativeIDs = Set(state.nativeMessageIDs)
        let candidates = operation.listening.filter {
            $0.sequence > state.listeningThrough && !nativeIDs.contains($0.messageID)
        }
        let existing = Set(state.sentListeningSequences)
        var lines: [DeepSeekWebTranscriptLine] = []
        var previous: [DeepSeekWebTurn] = []
        var includeReply = false

        func replyText(_ reply: DeepSeekWebQuote, visible: Set<Int>) -> String {
            if let sequence = reply.sequence, visible.contains(sequence) { return "в ответ на #\(sequence)" }
            return "цитата \(quote(reply.author)): \(quote(reply.text))"
        }

        func render() -> String {
            let visible = existing.union(lines.map(\.sequence))
            var parts = [role]
            if !previous.isEmpty {
                let pairs = previous.map { "Вопрос: \(quote($0.question))\nОтвет: \(quote($0.answer))" }
                parts.append("Предыдущие доставленные ответы:\n" + pairs.joined(separator: "\n\n"))
            }
            if !lines.isEmpty {
                let excerpts = lines.map { line in
                    let reply = line.reply.map { " (\(replyText($0, visible: visible)))" } ?? ""
                    return "#\(line.sequence) [\(line.timestamp.ISO8601Format())] \(quote(line.author))\(reply): \(quote(line.text))"
                }
                parts.append("Цитаты из стенограммы, только для контекста:\n" + excerpts.joined(separator: "\n"))
            }
            if includeReply, let reply = operation.reply {
                parts.append("Связь с предыдущим сообщением: " + replyText(reply, visible: visible))
            }
            parts.append(question)
            return parts.joined(separator: "\n\n")
        }

        guard fits(render()) else { return nil }
        if operation.reply != nil {
            includeReply = true
            if !fits(render()) { includeReply = false }
        }
        for line in candidates.reversed() {
            lines.insert(line, at: 0)
            guard fits(render()) else {
                lines.removeFirst()
                break
            }
        }
        if state.remoteChatID == nil {
            for turn in state.history.reversed() {
                previous.insert(turn, at: 0)
                guard fits(render()) else {
                    previous.removeFirst()
                    break
                }
            }
        }
        return Self(
            text: render(),
            listeningThrough: max(state.listeningThrough, operation.listeningThrough),
            sentListeningSequences: lines.map(\.sequence),
            usedListening: !lines.isEmpty || (includeReply && operation.reply?.usesListening == true)
                || previous.contains(where: \.usesListening)
        )
    }
}

enum DeepSeekWebPersistenceError: Error {
    case unavailable
    case superseded
}

enum DeepSeekWebAdmission: Sendable {
    case inserted
    case duplicate(DeepSeekWebOperation?)
}
