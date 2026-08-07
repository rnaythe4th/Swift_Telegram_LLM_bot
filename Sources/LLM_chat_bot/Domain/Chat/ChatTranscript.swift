import Foundation

// Listen mode: what the bot overhears in a group chat.
//
// The ordinary memory (`ChatContext.history`) is a dialogue — the bot's own
// questions and answers, nothing else. A group is not a dialogue: most of what
// is said there is said between people, and the one line addressed to the bot
// («@bot а он прав?») means nothing without the twenty before it.
//
// So a listening chat keeps a second, differently shaped memory: a transcript.
// Every message goes in with its author and its place in the order, replies
// keep their target, and when somebody finally addresses the bot the transcript
// is handed over as *background* while the addressing message stays the task.
//
// It lives inside `ChatContext`, which is keyed by `ChatKey` — so a forum topic
// listens to itself and not to the room next door, the buffer moves with the
// chat when a group is upgraded to a supergroup, and `/forget` erases it along
// with everything else the chat said.

/// Who said a line.
enum TranscriptAuthor: Codable, Sendable, Equatable, Hashable {
    /// A person, stored as their key rather than their name: names are rented,
    /// and a rename must not leave a hundred stored lines attributed to
    /// somebody who no longer exists.
    case member(UserKey)
    /// The bot's own answer. It belongs in the transcript because it is part of
    /// the conversation — and because replying to it is the most common way
    /// anyone addresses the bot at all.
    case bot
}

/// What a message was answering.
struct TranscriptReply: Codable, Sendable, Equatable {
    let messageID: Int
    /// Author of the message answered, when the update told us. Optional
    /// because Telegram omits `from` for messages posted on behalf of a chat.
    let author: TranscriptAuthor?
    /// Opening words of what was answered. Printed only when that message has
    /// already fallen out of the buffer — where a `#N` reference would point at
    /// nothing, and «в ответ на …» would be the only thing keeping the question
    /// intelligible.
    let quote: String

    static let quoteLimit = 80

    init(messageID: Int, author: TranscriptAuthor?, quote: String) {
        self.messageID = messageID
        self.author = author
        self.quote = ChatTranscript.clip(quote, to: Self.quoteLimit)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            messageID: try c.decodeIfPresent(Int.self, forKey: .messageID) ?? 0,
            author: try c.decodeIfPresent(TranscriptAuthor.self, forKey: .author),
            quote: try c.decodeIfPresent(String.self, forKey: .quote) ?? ""
        )
    }
}

/// One overheard message.
struct TranscriptEntry: Codable, Sendable, Equatable {
    /// Place in the conversation — the `#N` the model is asked to reason about.
    /// A running number, not an index: the oldest line falls off the buffer on
    /// every append, and a reference that renumbers itself points at a
    /// different message every time somebody speaks.
    let seq: Int
    /// Telegram's own id, which is what a reply points at.
    let messageID: Int
    let author: TranscriptAuthor
    let text: String
    let at: Date
    let replyTo: TranscriptReply?

    init(seq: Int, messageID: Int, author: TranscriptAuthor, text: String, at: Date, replyTo: TranscriptReply?) {
        self.seq = seq
        self.messageID = messageID
        self.author = author
        self.text = text
        self.at = at
        self.replyTo = replyTo
    }

    /// Hand-written for the same reason `CumulativeUsage`'s is: this is the
    /// payload of a `jsonb` column, and a synthesised decoder throws on the
    /// first key a future build adds and an old row does not have — taking the
    /// whole chat context down with it, not just one line.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            seq: try c.decodeIfPresent(Int.self, forKey: .seq) ?? 0,
            messageID: try c.decodeIfPresent(Int.self, forKey: .messageID) ?? 0,
            author: try c.decodeIfPresent(TranscriptAuthor.self, forKey: .author) ?? .bot,
            text: try c.decodeIfPresent(String.self, forKey: .text) ?? "",
            at: try c.decodeIfPresent(Date.self, forKey: .at) ?? Date(timeIntervalSince1970: 0),
            replyTo: try c.decodeIfPresent(TranscriptReply.self, forKey: .replyTo)
        )
    }

    var byteCount: Int {
        text.utf8.count + (replyTo?.quote.utf8.count ?? 0) + 48
    }
}

/// The buffer itself: a bounded, append-only view of what was said.
///
/// The caps live here rather than at the call sites (CLAUDE.md §14): this is a
/// collection *users* grow — one message at a time, as fast as they can type —
/// and it is re-sent to the model on every answer and rewritten into a `jsonb`
/// row twice a second while the chat is busy. `append` is the only way in, and
/// it cannot be made to overflow.
struct ChatTranscript: Codable, Sendable, Equatable {
    private(set) var entries: [TranscriptEntry]
    /// Next `#N`. Kept across trims and across restarts so a reference the model
    /// was given in one answer still means the same message in the next.
    private(set) var nextSeq: Int

    static let empty = ChatTranscript(entries: [], nextSeq: 1)

    // MARK: - Bounds

    /// How many messages a chat may ask to keep. The lower bound is where the
    /// feature stops being worth its cost; the upper one is where the prompt
    /// stops being worth its price.
    static let sizeRange = 10...300
    static let defaultSize = 100

    /// One message is clipped to this. A pasted log or a wall of text is one
    /// person's message, and without a per-line cap it evicts the other
    /// ninety-nine — the conversation is what this buffer is for, not the
    /// contents of any single line of it.
    static let entryTextLimit = 400

    /// Ceiling on the whole buffer, in the units the wire and the column both
    /// charge for. `sizeRange.upperBound` messages at `entryTextLimit` each
    /// would be ~120 KB — a quarter of a megabyte of prompt on *every* answer,
    /// re-paid every turn. This is the number that actually bounds the bill;
    /// the message count is the number people understand.
    static let byteBudget = 60_000

    // MARK: - Writing

    /// Files one message. Returns false when there was nothing to overhear.
    @discardableResult
    mutating func append(
        messageID: Int,
        author: TranscriptAuthor,
        text: String,
        at: Date,
        replyTo: TranscriptReply?,
        size: Int
    ) -> Bool {
        let clipped = Self.clip(text, to: Self.entryTextLimit)
        guard !clipped.isEmpty else { return false }
        // Telegram re-delivers on retry, and an album arrives as several
        // updates: the same message must not be counted twice.
        if entries.last?.messageID == messageID, messageID != 0 { return false }

        entries.append(
            TranscriptEntry(
                seq: nextSeq,
                messageID: messageID,
                author: author,
                text: clipped,
                at: at,
                replyTo: replyTo
            )
        )
        nextSeq += 1
        trim(to: size)
        return true
    }

    mutating func clear() -> Int {
        let erased = entries.count
        entries = []
        return erased
    }

    /// Applies a new size to what is already stored. Growing changes nothing
    /// (the buffer fills from here on); shrinking has to take effect at once,
    /// because that is the only reason anybody shrinks it.
    mutating func resize(to size: Int) {
        trim(to: size)
    }

    /// Both bounds, oldest first. `size` arrives from stored state and from a
    /// typed value, so it is clamped here rather than trusted — the same
    /// discipline `trimHistory` applies to `maxHistory`.
    private mutating func trim(to size: Int) {
        let cap = Self.sizeRange.clamping(size)
        if entries.count > cap {
            entries.removeFirst(entries.count - cap)
        }
        var bytes = entries.reduce(0) { $0 + $1.byteCount }
        while bytes > Self.byteBudget, entries.count > 1 {
            bytes -= entries.removeFirst().byteCount
        }
    }

    // MARK: - Reading

    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }
    var byteCount: Int { entries.reduce(0) { $0 + $1.byteCount } }

    /// The conversation as lines, oldest last — newest kept when there is not
    /// room for all of them, because the end of a conversation is what a
    /// question is about.
    ///
    /// - Parameters:
    ///   - excluding: the message that is *asking*. It is already in the buffer
    ///     (everything is filed on the way in), and it is about to be sent
    ///     separately as the task — printing it twice invites the model to
    ///     answer the transcript instead of the question.
    ///   - label: how an author is named. Resolved by the caller against the
    ///     live directory, so a renamed member reads correctly in lines stored
    ///     under their old name.
    ///   - escapeText: on for a page the *user* reads (the text is arbitrary
    ///     and lands in HTML), off for the model.
    func lines(
        excluding: Int? = nil,
        label: (TranscriptAuthor) -> String,
        escapeText: Bool = false
    ) -> [String] {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM HH:mm"
        formatter.timeZone = TimeZone(identifier: "UTC")

        var kept: [String] = []
        var bytes = 0
        for entry in entries.reversed() {
            if let excluding, entry.messageID == excluding, entry.messageID != 0 { continue }
            let body = escapeText ? MessageText.escaped(entry.text) : entry.text
            let reply = replyMarker(for: entry, label: label)
            let line = "#\(entry.seq) [\(formatter.string(from: entry.at))] \(label(entry.author))\(reply): \(body)"
            bytes += line.utf8.count
            if !kept.isEmpty, bytes > Self.byteBudget { break }
            kept.append(line)
        }
        return Array(kept.reversed())
    }

    /// «(в ответ на #12)» when the target is still in the buffer, «(в ответ
    /// @bob: «…»)» when it is not. A reply whose target has scrolled out is the
    /// case that matters: without the quote the question loses its subject.
    private func replyMarker(for entry: TranscriptEntry, label: (TranscriptAuthor) -> String) -> String {
        guard let reply = entry.replyTo else { return "" }
        if let target = entries.first(where: { $0.messageID == reply.messageID && $0.messageID != 0 }) {
            return " (в ответ на #\(target.seq))"
        }
        let who = reply.author.map(label) ?? "кому-то"
        guard !reply.quote.isEmpty else { return " (в ответ \(who))" }
        return " (в ответ \(who): «\(reply.quote)»)"
    }

    // MARK: - Prompt shape

    /// Added to the chat's own role when it is listening. Explains the format —
    /// the numbering is useless to the model unless it is told what it means —
    /// and, at the end where it is obeyed, what the transcript is *not*: a
    /// conversation to join.
    static let systemAddendum = """


        Ты подключён к групповому чату и видишь его стенограмму.
        Формат строки: «#номер [дд.ММ ЧЧ:мм UTC] Автор: текст». Пометка «(в ответ на #N)» \
        значит, что сообщение отвечало на строку #N.
        Стенограмма — это фон, а не задание. Отвечай только на последнее сообщение, \
        адресованное тебе, опираясь на стенограмму как на контекст. Не пересказывай её, \
        не отвечай за других участников и не продолжай их разговор. Если в стенограмме \
        нет нужного, так и скажи.
        """

    /// Wraps the lines into the one message the transcript travels in.
    static func promptBlock(lines: [String]) -> String? {
        guard !lines.isEmpty else { return nil }
        return """
        📋 Стенограмма чата, последние сообщения (\(lines.count)):

        \(lines.joined(separator: "\n"))

        — конец стенограммы —
        """
    }

    // MARK: - Helpers

    /// Trimmed, collapsed to one line and cut to `limit`.
    ///
    /// Newlines go because a transcript is line-per-message: a message
    /// containing its own newlines would otherwise forge extra lines, and the
    /// model has no way to tell a forged `#12 @admin:` from a real one.
    static func clip(_ raw: String, to limit: Int) -> String {
        let flattened = raw
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit)) + "…"
    }
}

/// Listen mode as the chat holds it: the switch, the size and the buffer.
struct ChatListening: Codable, Sendable, Equatable {
    var isOn: Bool
    var size: Int
    var transcript: ChatTranscript

    static let off = ChatListening(isOn: false, size: ChatTranscript.defaultSize, transcript: .empty)

    init(isOn: Bool = false, size: Int = ChatTranscript.defaultSize, transcript: ChatTranscript = .empty) {
        self.isOn = isOn
        self.size = ChatTranscript.sizeRange.clamping(size)
        self.transcript = transcript
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isOn: try c.decodeIfPresent(Bool.self, forKey: .isOn) ?? false,
            size: try c.decodeIfPresent(Int.self, forKey: .size) ?? ChatTranscript.defaultSize,
            transcript: try c.decodeIfPresent(ChatTranscript.self, forKey: .transcript) ?? .empty
        )
    }

    /// What the buffer currently costs to carry, in the terms the settings page
    /// speaks: characters of prompt, and a rough count of tokens for them.
    /// Deliberately approximate — the point is the order of magnitude, which is
    /// what tells somebody that 300 messages is a different decision from 50.
    var promptCost: (characters: Int, tokens: Int) {
        let characters = transcript.entries.reduce(0) { $0 + $1.text.count + 32 }
        return (characters, characters / 3)
    }
}
