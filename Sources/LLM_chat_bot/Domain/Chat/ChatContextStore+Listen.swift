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
    /// Switching on adopts the pre-roll — what this process has already
    /// overheard in the chat (`_overheardPreroll`). Telegram cannot hand a bot
    /// the history of a conversation, so this is the whole of "start with what
    /// came before" that exists: only into an empty buffer, so re-enabling
    /// after a wipe does not resurrect what somebody just erased.
    ///
    /// Returns whether anything changed and how many older messages came with
    /// it — the chat is told both, because the announcement is the whole
    /// honesty of the feature (`BotMenuHandler.listenAnnouncement`).
    @discardableResult
    func setListenMode(chatKey: ChatKey, on: Bool) -> ListenSwitchOutcome {
        guard listening(chatKey: chatKey).isOn != on else { return .unchanged }
        var seeded = 0
        mutate(chatKey: chatKey) { context in
            context.listening.isOn = on
            guard on, context.listening.transcript.isEmpty else { return }
            guard let preroll = _overheardPreroll[chatKey] else { return }
            let adopted = preroll.seed(size: context.listening.size)
            guard !adopted.isEmpty else { return }
            context.listening.transcript = adopted
            seeded = adopted.count
        }
        // Spent whether or not anything was taken: what was adopted now lives
        // in the chat's own buffer (a second copy would double it back in on
        // the next switch), and what was not adopted is a backlog for a chat
        // that is recording anyway — kept, it would just sit there.
        if on { _overheardPreroll[chatKey] = nil }
        return ListenSwitchOutcome(changed: true, seeded: seeded)
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

    /// «Забыть услышанное» — and that has to mean all of it.
    ///
    /// The pre-roll goes too. Leaving it would make the button a lie in the one
    /// way that matters: switch listening off and on again and the messages
    /// somebody just erased come back, because a second copy of them was
    /// sitting in memory the whole time.
    @discardableResult
    func clearTranscript(chatKey: ChatKey) -> Int {
        var erased = _overheardPreroll.removeValue(forKey: chatKey)?.count ?? 0
        guard contexts[chatKey] != nil else { return erased }
        mutate(chatKey: chatKey) { erased += $0.listening.transcript.clear() }
        return erased
    }


    // MARK: - Capture

    /// Files one overheard message — into the chat's own transcript when it is
    /// listening, into the pre-roll when it is not.
    ///
    /// The second half is what makes "switch it on and it already knows what we
    /// were talking about" possible at all: the bot is handed these messages
    /// either way, and dropping them meant every chat that ever enabled
    /// listening started blind. Nothing about the pre-roll is written down or
    /// leaves the process until somebody asks for it — see `_overheardPreroll`.
    func recordOverheard(
        chatKey: ChatKey,
        messageID: Int,
        author: TranscriptAuthor,
        text: String,
        at: Date,
        replyTo: TranscriptReply?
    ) {
        guard isListening(chatKey: chatKey) else {
            var preroll = _overheardPreroll[chatKey] ?? .empty
            preroll.append(
                messageID: messageID,
                author: author,
                text: text,
                at: at,
                replyTo: replyTo,
                size: ChatTranscript.seedLimit
            )
            _overheardPreroll[chatKey] = preroll
            prunePreroll()
            return
        }
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

    /// Keeps the pre-roll from growing with the number of groups the bot is in.
    /// The quietest chats go first: a conversation nobody has added to in hours
    /// is the one least likely to be worth seeding, and the time bound in
    /// `seed` would have dropped it anyway.
    private func prunePreroll() {
        guard _overheardPreroll.count > Self.prerollChatCap else { return }
        let stale = _overheardPreroll
            .sorted { ($0.value.lastActivity ?? .distantPast) < ($1.value.lastActivity ?? .distantPast) }
            .prefix(_overheardPreroll.count - Self.prerollChatCap)
        for (key, _) in stale { _overheardPreroll[key] = nil }
    }

    /// How much of this chat's recent conversation the bot is holding but not
    /// using. The settings page shows it, so «включить» is a promise with a
    /// number on it instead of a leap of faith.
    ///
    /// Counted through the same `seed` the switch will run, with the same size
    /// — a chat keeping 30 messages must not be shown "подхвачу 100" and then
    /// handed 30.
    func prerollCount(chatKey: ChatKey) -> Int {
        guard let preroll = _overheardPreroll[chatKey] else { return 0 }
        return preroll.seed(size: listening(chatKey: chatKey).size).count
    }

    /// How many chats the pre-roll is holding. For the bound, which is the only
    /// thing about an in-memory map that can go wrong quietly.
    func prerollChatCount() -> Int { _overheardPreroll.count }

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
