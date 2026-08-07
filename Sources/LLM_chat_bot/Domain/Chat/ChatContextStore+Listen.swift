import Foundation

// Listen mode: the switch, the buffer and the two shapes the buffer is read in
// — the prompt the model gets and the page a person reads.
//
// All of it goes through the actor like every other piece of chat state, and
// every mutation marks `dirtyContexts` (via `mutate`), because the transcript
// lives inside `ChatContext` and rides the same write-behind row.

extension ChatContextStore {
    // MARK: - Switch and size

    /// Read-only: never creates a context. This is asked on *every* group
    /// message before anything is captured, and a bot that is merely present in
    /// a chat must not grow a row for it.
    func isListening(chatKey: ChatKey) -> Bool {
        contexts[chatKey]?.listening.isOn ?? false
    }

    func listening(chatKey: ChatKey) -> ChatListening {
        contexts[chatKey]?.listening ?? .off
    }

    /// Explicit on/off rather than a toggle: the button that sets it lives in a
    /// message that outlives the page it was drawn on, and two people tapping
    /// the stale copy of it must not flip listening back and forth.
    ///
    /// Returns whether this call actually changed anything, so the caller knows
    /// whether the chat still has to be told (the announcement is the whole
    /// honesty of the feature — see `BotMenuHandler.listenAnnouncement`).
    @discardableResult
    func setListenMode(chatKey: ChatKey, on: Bool) -> Bool {
        guard listening(chatKey: chatKey).isOn != on else { return false }
        mutate(chatKey: chatKey) { $0.listening.isOn = on }
        return true
    }

    /// Clamped in the domain, like every other chat bound (CLAUDE.md §14): the
    /// value arrives from a button, from a typed number and from rows written
    /// by older builds, and only one of those three is ever validated.
    @discardableResult
    func setListenSize(chatKey: ChatKey, size: Int) -> Int {
        let clamped = ChatTranscript.sizeRange.clamping(size)
        mutate(chatKey: chatKey) { context in
            context.listening.size = clamped
            // Shrinking has to bite now, not on the next message: somebody who
            // just cut the buffer from 300 to 50 did it to stop paying for 300.
            context.listening.transcript.resize(to: clamped)
        }
        return clamped
    }

    @discardableResult
    func clearTranscript(chatKey: ChatKey) -> Int {
        guard contexts[chatKey] != nil else { return 0 }
        var erased = 0
        mutate(chatKey: chatKey) { erased = $0.listening.transcript.clear() }
        return erased
    }

    // MARK: - Capture

    /// Files one overheard message. A no-op when the chat is not listening, so
    /// the caller does not have to hold the answer to that question across an
    /// actor hop.
    func recordOverheard(
        chatKey: ChatKey,
        messageID: Int,
        author: TranscriptAuthor,
        text: String,
        at: Date,
        replyTo: TranscriptReply?
    ) {
        guard isListening(chatKey: chatKey) else { return }
        mutate(chatKey: chatKey) { context in
            context.listening.transcript.append(
                messageID: messageID,
                author: author,
                text: text,
                at: at,
                replyTo: replyTo,
                size: context.listening.size
            )
        }
    }

    // MARK: - Reading

    /// The transcript as the model is shown it: the chat's role with the format
    /// explained, the conversation, then the question on its own.
    ///
    /// nil when the chat is not listening — the caller falls back to the
    /// ordinary dialogue memory, which is what a private chat always uses.
    func listenMessages(
        _ context: ChatContext,
        excluding askedMessageID: Int?,
        question: ChatMessage
    ) -> [ChatMessage]? {
        guard context.listening.isOn else { return nil }
        let lines = context.listening.transcript.lines(
            excluding: askedMessageID,
            label: { [self] in transcriptLabel($0) }
        )
        // Nothing overheard yet — the chat has only just switched listening on,
        // or the one message in the buffer is the question itself. Explaining a
        // transcript that is not there costs tokens and invites the model to
        // apologise for not having it.
        guard let block = ChatTranscript.promptBlock(lines: lines) else {
            return [.init(role: "system", content: context.role), question]
        }
        return [
            .init(role: "system", content: context.role + ChatTranscript.systemAddendum),
            .init(role: "user", content: block),
            question,
        ]
    }

    /// The transcript as a person reads it back: escaped, newest lines kept.
    /// Same buffer, same order, same numbering as the model sees — a report
    /// that shows something else is a report nobody can debug with.
    func transcriptLines(chatKey: ChatKey) -> (lines: [String], total: Int) {
        let listening = listening(chatKey: chatKey)
        return (
            listening.transcript.lines(label: { [self] in transcriptLabel($0) }, escapeText: true),
            listening.transcript.count
        )
    }

    /// What a line is signed with. Resolved now rather than at capture time, so
    /// a rename is reflected in everything the chat ever overheard — and so the
    /// buffer stores keys instead of a hundred copies of the same name.
    ///
    /// `displayLabel` escapes for HTML, and the same label is handed to the
    /// model as well as to the dump page. That is the safe direction of the two:
    /// an `&amp;` in a prompt costs a token, an unescaped `<` in the dump makes
    /// Telegram refuse the whole message and the button reads as broken.
    private func transcriptLabel(_ author: TranscriptAuthor) -> String {
        switch author {
        case .bot: return "🤖 бот"
        case .member(let key): return displayLabel(forKey: key)
        }
    }

    /// The «Тебе пишет …» line in front of a question.
    ///
    /// Outside listen mode it is exactly what it always was, down to the
    /// behaviour of producing nothing when the asker has no @username. Inside
    /// it, two things change: the asker is named through the directory (in a
    /// group "who is asking" is not optional — it is half the question), and a
    /// reply carries the `#N` of the line it answers, which is how the model
    /// knows *which* of a hundred messages the question is about.
    func questionPrefix(
        chatKey: ChatKey,
        asker: UserKey?,
        handle: String?,
        replyTo: TranscriptReply?
    ) -> String {
        guard let context = contexts[chatKey], context.listening.isOn else {
            return handle.map { "Тебе пишет @\($0): " } ?? ""
        }
        let asking = asker.map { displayLabel(forKey: $0) } ?? handle.map { "@\($0)" } ?? "участник чата"
        var marker = ""
        if let replyTo {
            if let target = context.listening.transcript.entries
                .first(where: { $0.messageID == replyTo.messageID && $0.messageID != 0 }) {
                marker = " (в ответ на #\(target.seq))"
            } else if case .bot? = replyTo.author {
                marker = " (в ответ на твоё сообщение)"
            } else if !replyTo.quote.isEmpty {
                let answered = replyTo.author.map { transcriptLabel($0) } ?? "кому-то"
                marker = " (в ответ \(answered): «\(replyTo.quote)»)"
            }
        }
        return "Тебе пишет \(asking)\(marker): "
    }
}
