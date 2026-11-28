import Foundation

extension ChatContextStore {
    func webState(chatKey: ChatKey) -> DeepSeekWebChatState? {
        contexts[chatKey]?.deepSeekWeb
    }

    func webListeningAllowed(chatKey: ChatKey) -> Bool {
        !chatKey.chatID.isGroup || contexts[chatKey]?.deepSeekWeb?.groupAllowed == true
    }

    func webGroupNoticeEpoch(chatKey: ChatKey) -> UUID? {
        guard chatKey.chatID.isGroup else { return nil }
        let context = ensure(chatKey: chatKey)
        guard context.provider == .deepseekWeb, let web = context.deepSeekWeb,
              !web.groupAllowed, web.groupNoticeSent != true else { return nil }
        return web.contextEpoch
    }

    func allowWebListening(chatKey: ChatKey) {
        guard chatKey.chatID.isGroup, let context = contexts[chatKey],
              let web = context.deepSeekWeb, !web.groupAllowed else { return }
        let boundary = context.listening.transcript.nextSeq - 1
        mutateWeb(chatKey: chatKey, contextEpoch: web.contextEpoch) {
            $0.groupAllowed = true
            $0.listeningBoundary = boundary
            $0.listeningThrough = boundary
        }
    }

    /// A nil setting toggles the current value, including the deployment default.
    func setWebDeepThink(chatKey: ChatKey, enabled: Bool?) -> Bool? {
        let context = ensure(chatKey: chatKey)
        guard let web = context.deepSeekWeb else { return nil }
        let next = enabled ?? !(web.deepThink ?? webDeepThinkDefault)
        guard mutateWeb(chatKey: chatKey, contextEpoch: web.contextEpoch, { $0.deepThink = next }) else { return nil }
        return next
    }

    func setWebSearch(chatKey: ChatKey, enabled: Bool) -> Bool {
        let context = ensure(chatKey: chatKey)
        guard let web = context.deepSeekWeb else { return false }
        return mutateWeb(chatKey: chatKey, contextEpoch: web.contextEpoch) { $0.webSearch = enabled }
    }

    func webOperations() -> [(ChatKey, DeepSeekWebOperation)] {
        contexts.flatMap { key, context in
            (context.deepSeekWeb?.operations ?? []).map { (key, $0) }
        }.sorted { lhs, rhs in
            if lhs.1.createdAt != rhs.1.createdAt { return lhs.1.createdAt < rhs.1.createdAt }
            return lhs.1.updateID < rhs.1.updateID
        }
    }

    func webCandidate(
        chatKey: ChatKey,
        operationID: UUID,
        updateID: Int64,
        question: String,
        messageID: Int,
        telegramThreadID: Int64?,
        reply: TranscriptReply?,
        replyToMessageID: Int? = nil,
        asker: UserKey? = nil,
        attachments: [InboundMediaRef]? = nil,
        albumUpdateIDs: [Int64]? = nil,
        now: Date = Date()
    ) -> DeepSeekWebOperation? {
        let context = ensure(chatKey: chatKey)
        guard context.provider == .deepseekWeb, let web = context.deepSeekWeb, web.version == 1 else { return nil }
        // A snapshot survives queue waits and transcript eviction. Only
        // replies whose source we can locate in this topic are eligible.
        let entries = context.listening.isOn && webListeningAllowed(chatKey: chatKey)
            ? context.listening.transcript.entries.filter { $0.seq > web.listeningBoundary }
            : []
        let boundary = max(web.listeningBoundary, entries.last?.seq ?? 0)
        let window = Array(entries.filter { $0.messageID != messageID }.suffix(80))
        let byMessageID = Dictionary(
            entries.lazy.filter { $0.messageID > 0 }.map { ($0.messageID, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let nativeIDs = Set(web.nativeMessageIDs)

        func quote(_ reference: TranscriptReply) -> DeepSeekWebQuote? {
            guard reference.messageID > 0 else { return nil }
            if let native = web.history.last(where: { $0.answerMessageIDs.contains(reference.messageID) }) {
                return DeepSeekWebQuote(
                    sequence: nil,
                    author: "бот",
                    text: ChatTranscript.clip(native.answer, to: TranscriptReply.quoteLimit),
                    usesListening: native.usesListening
                )
            }
            guard let entry = byMessageID[reference.messageID] else { return nil }
            return DeepSeekWebQuote(
                sequence: nativeIDs.contains(entry.messageID) ? nil : entry.seq,
                author: transcriptLabel(entry.author),
                text: ChatTranscript.clip(entry.text, to: TranscriptReply.quoteLimit),
                usesListening: true
            )
        }

        return DeepSeekWebOperation(
            id: operationID,
            contextEpoch: web.contextEpoch,
            updateID: updateID,
            question: question,
            role: context.role,
            asker: asker.map { displayLabel(forKey: $0) },
            messageID: messageID,
            telegramThreadID: telegramThreadID,
            replyToMessageID: replyToMessageID,
            createdAt: now,
            listening: window.map { entry in
                DeepSeekWebTranscriptLine(
                    sequence: entry.seq, messageID: entry.messageID, timestamp: entry.at,
                    author: transcriptLabel(entry.author), text: entry.text, reply: entry.replyTo.flatMap(quote)
                )
            },
            listeningThrough: boundary,
            reply: reply.flatMap(quote),
            deepThink: web.deepThink,
            webSearch: web.webSearch,
            requesterID: asker?.userID,
            attachments: attachments,
            albumUpdateIDs: albumUpdateIDs
        )
    }

    @discardableResult
    func mutateWeb(
        chatKey: ChatKey,
        contextEpoch: UUID,
        _ block: @Sendable (inout DeepSeekWebChatState) -> Void
    ) -> Bool {
        guard var context = contexts[chatKey], context.provider == .deepseekWeb,
              var state = context.deepSeekWeb, state.version == 1, state.contextEpoch == contextEpoch
        else { return false }
        block(&state)
        state.revision = UUID()
        context.deepSeekWeb = state
        contexts[chatKey] = context
        dirtyContexts.insert(chatKey)
        return true
    }

    func finishWebDelivery(chatKey: ChatKey, contextEpoch: UUID, operationID: UUID) -> Bool {
        guard var context = contexts[chatKey], context.provider == .deepseekWeb,
              var web = context.deepSeekWeb, web.contextEpoch == contextEpoch,
              let index = web.operations.firstIndex(where: { $0.id == operationID }),
              let answer = web.operations[index].response
        else { return false }
        let operation = web.operations[index]
        guard !operation.deliveryMessageIDs.isEmpty else { return false }
        web.operations.remove(at: index)
        web.rememberNativeMessages([operation.messageID] + operation.deliveryMessageIDs)
        web.history.append(
            DeepSeekWebTurn(
                question: operation.question,
                answer: answer,
                questionMessageID: operation.messageID,
                answerMessageIDs: operation.deliveryMessageIDs,
                usesListening: web.usesListening || operation.usedListening
            )
        )
        web.trimHistory(to: context.maxHistory)
        web.revision = UUID()
        context.deepSeekWeb = web
        if context.listening.isOn, let lastMessageID = operation.deliveryMessageIDs.last {
            context.listening.transcript.append(
                messageID: lastMessageID,
                author: .bot,
                text: answer,
                at: Date(),
                replyTo: nil,
                size: context.listening.size
            )
        }
        contexts[chatKey] = context
        dirtyContexts.insert(chatKey)
        return true
    }

    /// The candidate stays out of write-behind until the admission transaction
    /// commits both the operation and the Telegram update marker.
    func webAdmissionRow(chatKey: ChatKey, operation: DeepSeekWebOperation) -> ChatContextRow? {
        guard var context = contexts[chatKey], context.provider == .deepseekWeb,
              var web = context.deepSeekWeb, web.contextEpoch == operation.contextEpoch else { return nil }
        guard !web.operations.contains(where: { $0.id == operation.id }) else { return nil }
        web.operations.append(operation)
        context.deepSeekWeb = web
        return ChatContextRow(key: chatKey, snapshot: makeContextSnapshot(context))
    }

    func acceptWebAdmission(chatKey: ChatKey, operation: DeepSeekWebOperation) {
        guard var context = contexts[chatKey], context.provider == .deepseekWeb,
              var web = context.deepSeekWeb, web.contextEpoch == operation.contextEpoch,
              !web.operations.contains(where: { $0.id == operation.id }) else { return }
        web.operations.append(operation)
        context.deepSeekWeb = web
        contexts[chatKey] = context
        dirtyContexts.insert(chatKey)
    }

    func webCheckpointRevision(chatKey: ChatKey, contextEpoch: UUID?) throws -> UUID? {
        if let contextEpoch, let state = contexts[chatKey]?.deepSeekWeb, state.contextEpoch == contextEpoch {
            return state.revision
        }
        if contextEpoch == nil, contexts[chatKey] == nil { return nil }
        throw DeepSeekWebPersistenceError.superseded
    }

    func webBindingAvailable(chatKey: ChatKey, accountEpoch: UUID, remoteChatID: String) -> Bool {
        !contexts.contains { key, context in
            key != chatKey && context.provider == .deepseekWeb && context.deepSeekWeb?.accountEpoch == accountEpoch
                && context.deepSeekWeb?.remoteChatID == remoteChatID
        }
    }

    /// Web/API boundaries also fence admissions still waiting on Postgres.
    func resetWebContext(
        _ context: inout ChatContext,
        chatKey: ChatKey,
        keepingIndependentTurns: Bool = false
    ) {
        guard context.provider == .deepseekWeb || context.deepSeekWeb != nil else { return }
        let previous = context.deepSeekWeb
        let boundary = context.listening.transcript.nextSeq - 1
        context.deepSeekWeb = DeepSeekWebChatState(
            accountEpoch: previous?.accountEpoch,
            listeningBoundary: boundary,
            listeningThrough: boundary,
            history: keepingIndependentTurns ? previous?.history.filter { !$0.usesListening } ?? [] : [],
            groupAllowed: previous?.groupAllowed ?? false,
            groupNoticeSent: previous?.groupNoticeSent,
            deepThink: previous?.deepThink,
            webSearch: previous?.webSearch
        )
        _overheardPreroll.removeValue(forKey: chatKey)
    }

    /// Previous account slots lose their chat IDs and queued work together.
    /// A binding's stored epoch is checked again at each asynchronous stage.
    func webResetForAccount(chatKey: ChatKey, accountEpoch: UUID) {
        guard var context = contexts[chatKey], context.provider == .deepseekWeb,
              let web = context.deepSeekWeb, web.accountEpoch != accountEpoch else { return }
        if web.accountEpoch != nil {
            resetWebContext(&context, chatKey: chatKey)
        }
        context.deepSeekWeb?.accountEpoch = accountEpoch
        context.deepSeekWeb?.revision = UUID()
        contexts[chatKey] = context
        dirtyContexts.insert(chatKey)
    }

    /// Keep confirmed ownership when Telegram renumbers a chat, but invalidate
    /// jobs that addressed the old Telegram ID.
    func fenceMigratedWebContext(_ context: inout ChatContext) {
        guard var web = context.deepSeekWeb else { return }
        if web.operations.contains(where: { $0.stage == .sending }) { web.rotate() }
        if web.operations.contains(where: { $0.stage == .confirmed || $0.stage == .delivering }) {
            web.hasUncertainDelivery = true
        }
        web.contextEpoch = UUID()
        web.revision = UUID()
        web.operations = []
        context.deepSeekWeb = web
    }
}
