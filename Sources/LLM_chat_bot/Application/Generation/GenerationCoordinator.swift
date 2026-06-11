import Foundation

private enum ReplyContentResolution {
    case none
    case unsupported(String)
    case content(UserInputContent)
}

final class GenerationCoordinator: @unchecked Sendable {
    private let telegram: TelegramGatewayPort
    private let state: ChatContextStore
    private let sessionRegistry: SessionRegistry
    private let mediaResolver: MediaResolverPort
    private let gateways: ProviderGatewayRegistry
    private let logger: LoggerPort
    private let botUsername: String
    
    init(
        telegram: TelegramGatewayPort,
        state: ChatContextStore,
        sessionRegistry: SessionRegistry,
        mediaResolver: MediaResolverPort,
        gateways: ProviderGatewayRegistry,
        logger: LoggerPort,
        botUsername: String
    ) {
        self.telegram = telegram
        self.state = state
        self.sessionRegistry = sessionRegistry
        self.mediaResolver = mediaResolver
        self.gateways = gateways
        self.logger = logger
        self.botUsername = botUsername
    }
    
    func handleIfNeeded(message: TelegramMessage, chatKey: ChatKey) async throws {
        switch try await resolveProcessableContent(message: message, chatKey: chatKey) {
        case .content(let content):
            try await processContent(message: message, content: content, chatKey: chatKey)
        case .unsupported(let feedback):
            try await sendUserFeedback(chatKey: chatKey, text: feedback)
        case .none:
            break
        }
    }
    
    private func resolveProcessableContent(message: TelegramMessage, chatKey: ChatKey) async throws -> ReplyContentResolution {
        let routing = MessageRoutingPolicy.evaluate(message: message, botUsername: botUsername)
        let refs = extractMediaRefs(from: message)
        
        guard routing.shouldHandle else {
            return .none
        }
        
        let normalizedText = routing.normalizedText
        guard normalizedText != nil || !refs.isEmpty else {
            return .none
        }
        
        if !refs.isEmpty {
            let provider = await state.provider(chatKey: chatKey)
            let adapter = try gateways.gateway(for: provider)
            
            let unsupportedKinds = unsupportedMediaKinds(in: refs, capabilities: adapter.capabilities)
            if !unsupportedKinds.isEmpty {
                let kinds = unsupportedKinds.map(\.displayName).joined(separator: ", ")
                return .unsupported(
                    "⚠️ Провайдер <b>\(provider.commandValue)</b> не поддерживает: \(kinds).\nСмените провайдера через /menu или отправьте только текст."
                )
            }
        }
        
        let resolved = refs.isEmpty ? [] : try await mediaResolver.resolveMedia(refs)
        return .content(.init(text: normalizedText, attachments: resolved))
    }
    
    private func processContent(message: TelegramMessage, content: UserInputContent, chatKey: ChatKey) async throws {
        let username = message.from?.username

        // Enforce free model restriction for non-tenants
        if let effectiveFree = await state.effectiveFreeModelIDs(),
           !(await state.hasFullModelAccess(username: username, userID: message.from?.id, chatID: chatKey.chatID)) {
            let currentModel = await state.model(chatKey: chatKey)
            if !effectiveFree.contains(currentModel) {
                guard let firstFree = effectiveFree.first else {
                    try await sendUserFeedback(chatKey: chatKey, text: "ℹ️ Бесплатные модели не настроены. Обратитесь к администратору.")
                    return
                }
                await state.setModelOnly(chatKey: chatKey, model: firstFree)
                _ = try? await telegram.sendMessage(.init(
                    chatID: chatKey.chatID,
                    threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                    replyTo: nil,
                    text: "ℹ️ Это платная модель. Переключаю на бесплатную — <code>\(firstFree)</code>\n\nДля доступа к платным моделям: /buy",
                    replyMarkup: nil
                ))
            }
        }

        let generationID = await sessionRegistry.register(chatKey: chatKey)

        let typingTask = Task {
            while !Task.isCancelled {
                try? await self.telegram.sendChatAction(
                    chatID: chatKey.chatID,
                    threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                    action: "typing"
                )
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
        defer { typingTask.cancel() }
        
        var processedContent = content
        if let username, let text = processedContent.text, !text.isEmpty {
            processedContent.text = "Тебе пишет @\(username): \(text)"
        }
        
        let hasAttachments = !processedContent.attachments.isEmpty
        
        let historyContent = hasAttachments
            ? UserInputContent(text: processedContent.text, attachments: [])
            : processedContent
        
        let snapshot = await state.snapshotAndAppend(
            chatKey: chatKey,
            generationID: generationID,
            content: historyContent,
            username: username
        )
        
        let messages: [ChatMessage] = hasAttachments
            ? Array(snapshot.messages.dropLast()) + [ChatMessage.userContent(processedContent, username: username)]
            : snapshot.messages
        
        let provider = snapshot.provider
        
        do {
            let gateway = try gateways.gateway(for: provider)
            
            let plan = ProviderGenerationPlan(
                model: snapshot.model,
                messages: messages,
                temperature: snapshot.temperature,
                includeUsage: snapshot.options.showStats || snapshot.options.showCost,
                reasoningEffort: snapshot.options.reasoningEffort,
                providerRouting: snapshot.providerRouting
            )
            
            let request = gateway.makeRequest(plan)
            let fallbackModel = gateway.fallbackModel(for: plan)
            
            try await streamReply(
                gateway: gateway,
                request: request,
                fallbackModel: fallbackModel,
                options: snapshot.options,
                chatKey: chatKey,
                replyToMessageID: message.message_id,
                generationID: generationID,
                isPrivateChat: message.chat.type == "private"
            )
        } catch {
            await state.cancelPendingTurn(chatKey: chatKey, generationID: generationID)
            await sessionRegistry.finish(generationID: generationID)
            throw error
        }
    }

    private func streamReply(
        gateway: ProviderGatewayPort,
        request: ProviderGatewayRequest,
        fallbackModel: String,
        options: GenerationOptions,
        chatKey: ChatKey,
        replyToMessageID: Int,
        generationID: GenerationID,
        isPrivateChat: Bool
    ) async throws {
        let stopMarkup = InlineKeyboardMarkup(inline_keyboard: [[
            .init(text: "⏹ Остановить", callback_data: BotCallbackAction.stop(generationID).rawData)
        ]])

        let placeholder: TelegramMessage

        do {
            placeholder = try await telegram.sendMessage(
                .init(
                    chatID: chatKey.chatID,
                    threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                    replyTo: replyToMessageID,
                    text: "💭 <i>Думаю…</i>",
                    replyMarkup: stopMarkup
                )
            )
        } catch {
            await state.cancelPendingTurn(chatKey: chatKey, generationID: generationID)
            await sessionRegistry.finish(generationID: generationID)
            throw error
        }

        // Drafts work only in private chats; begin() returns nil when the Bot API
        // server has no sendMessageDraft (then we fall back to edit-based streaming).
        var draft: DraftStreamer?
        if isPrivateChat {
            draft = await DraftStreamer.begin(
                telegram: telegram,
                chatID: chatKey.chatID,
                threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                logger: logger
            )
        }

        let streamTask: Task<Void, Never>
        if let draft {
            streamTask = Task<Void, Never> {
                await self.runDraftStreaming(
                    draft: draft,
                    gateway: gateway,
                    request: request,
                    fallbackModel: fallbackModel,
                    options: options,
                    chatKey: chatKey,
                    replyToMessageID: replyToMessageID,
                    generationID: generationID,
                    controlMessage: placeholder
                )
            }
        } else {
            streamTask = Task<Void, Never> {
                await self.runEditStreaming(
                    gateway: gateway,
                    request: request,
                    fallbackModel: fallbackModel,
                    options: options,
                    chatKey: chatKey,
                    generationID: generationID,
                    placeholder: placeholder,
                    stopMarkup: stopMarkup
                )
            }
        }

        await sessionRegistry.attach(generationID: generationID, task: streamTask)
    }

    /// Streams the reply into a native animated draft (private chats, Bot API 9.3+).
    /// The draft is an ephemeral preview, so every finished part — overflow chunks,
    /// the final text, errors, cancellation notices — is persisted via sendMessage.
    /// The "💭 Думаю…" control message only carries the stop button and is deleted
    /// once the reply is persisted.
    private func runDraftStreaming(
        draft: DraftStreamer,
        gateway: ProviderGatewayPort,
        request: ProviderGatewayRequest,
        fallbackModel: String,
        options: GenerationOptions,
        chatKey: ChatKey,
        replyToMessageID: Int,
        generationID: GenerationID,
        controlMessage: TelegramMessage
    ) async {
        var fullAccumulator = ""
        var messageAccumulator = ""
        var streamMeta: StreamMeta?
        var isCancelled = false
        var isFirstMessage = true
        let threadID: Int64? = chatKey.threadID == 0 ? nil : chatKey.threadID

        // Persists a finished part; Telegram animates the draft into the stored
        // message. Retries rate limits — losing the send here loses the reply,
        // because the draft itself expires.
        func persist(_ text: String) async -> Bool {
            let replyTo = isFirstMessage ? replyToMessageID : nil
            for attempt in 0..<3 {
                do {
                    _ = try await telegram.sendMessage(
                        .init(
                            chatID: chatKey.chatID,
                            threadID: threadID,
                            replyTo: replyTo,
                            text: text,
                            replyMarkup: nil
                        )
                    )
                    isFirstMessage = false
                    return true
                } catch {
                    if let telegramError = error as? TelegramAPIError,
                       let retryAfter = telegramError.retryAfter, attempt < 2 {
                        try? await Task.sleep(nanoseconds: UInt64(retryAfter) * 1_000_000_000)
                    } else {
                        logger.error("draft persist failed: \(error)")
                        return false
                    }
                }
            }
            return false
        }

        func removeControlMessage() async {
            try? await telegram.deleteMessage(chatID: chatKey.chatID, messageID: controlMessage.message_id)
        }

        do {
            try Task.checkCancellation()
            let stream = gateway.stream(request)

            for try await event in stream {
                if Task.isCancelled {
                    isCancelled = true
                    break
                }

                switch event {
                case .text(let chunk):
                    fullAccumulator += chunk
                    messageAccumulator += chunk

                    if messageAccumulator.count >= MessageSplitter.charLimit {
                        let (done, remaining) = MessageSplitter.split(messageAccumulator)
                        let prefix = isFirstMessage ? "" : "<i>↑ продолжение</i>\n\n"
                        _ = await persist(prefix + done + "\n\n<i>↓ продолжение ниже</i>")
                        messageAccumulator = remaining
                        await draft.rotate(initialText: remaining)
                        continue
                    }

                    await draft.update(text: messageAccumulator)

                case .meta(let meta):
                    streamMeta = meta
                }
            }
        } catch is CancellationError {
            isCancelled = true
        } catch {
            logger.error("stream failed: \(error)")
            await draft.finish()
            _ = await persist("⚠️ <b>Ошибка генерации</b>\n" + UserFacingError.message(error))
            await removeControlMessage()
            await state.cancelPendingTurn(chatKey: chatKey, generationID: generationID)
            await sessionRegistry.finish(generationID: generationID)
            return
        }

        if Task.isCancelled {
            isCancelled = true
        }
        if !isCancelled {
            // Let the typewriter catch up so the final message doesn't jump.
            await draft.awaitReveal()
        }
        await draft.finish()

        let finalText: String
        if isCancelled {
            let stopNotice = await cancellationNotice(for: generationID)
            finalText = messageAccumulator.isEmpty
                ? stopNotice
                : (isFirstMessage ? "" : "<i>↑ продолжение</i>\n\n") + messageAccumulator + "\n\n" + stopNotice
        } else {
            let footer = ResponseFooterFormatter.formatFooter(
                meta: streamMeta,
                fallbackModel: fallbackModel,
                showTokens: options.showStats,
                showCost: options.showCost,
                showModel: options.showModel
            ) ?? ""

            let prefix = isFirstMessage ? "" : "<i>↑ продолжение</i>\n\n"
            finalText = messageAccumulator.isEmpty
                ? "<i>Пустой ответ.</i>\(footer)"
                : prefix + messageAccumulator + footer
        }

        if await persist(finalText) {
            await removeControlMessage()
        } else {
            // Last resort: park the text in the control message instead of
            // losing the reply with the expiring draft.
            try? await telegram.editMessage(
                .init(
                    chatID: chatKey.chatID,
                    messageID: controlMessage.message_id,
                    text: finalText,
                    replyMarkup: InlineKeyboardMarkup(inline_keyboard: [])
                )
            )
        }

        if isCancelled {
            await state.cancelPendingTurn(chatKey: chatKey, generationID: generationID)
        } else if !fullAccumulator.isEmpty {
            await state.appendAssistant(chatKey: chatKey, generationID: generationID, content: fullAccumulator, usage: streamMeta?.usage)
        } else {
            await state.cancelPendingTurn(chatKey: chatKey, generationID: generationID)
        }
        await sessionRegistry.finish(generationID: generationID)
    }

    /// Legacy streaming for group chats and Bot API servers without drafts:
    /// the placeholder message is edited in place as chunks arrive.
    private func runEditStreaming(
        gateway: ProviderGatewayPort,
        request: ProviderGatewayRequest,
        fallbackModel: String,
        options: GenerationOptions,
        chatKey: ChatKey,
        generationID: GenerationID,
        placeholder: TelegramMessage,
        stopMarkup: InlineKeyboardMarkup
    ) async {
        let emptyMarkup = InlineKeyboardMarkup(inline_keyboard: [])
        let logger = self.logger
        var fullAccumulator = ""
        var messageAccumulator = ""
        var currentPlaceholder = placeholder
        var streamMeta: StreamMeta?
        var lastLength = 0
        let clock = ContinuousClock()
        var lastEdit = clock.now
        var isCancelled = false
        var isFirstMessage = true

        func sendContinuationPlaceholder() async -> TelegramMessage? {
            try? await telegram.sendMessage(
                .init(
                    chatID: chatKey.chatID,
                    threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                    replyTo: nil,
                    text: "💭 <i>Продолжаю…</i>",
                    replyMarkup: stopMarkup
                )
            )
        }

        func splitAndContinue() async throws {
            let (done, remaining) = MessageSplitter.split(messageAccumulator)
            try? await telegram.editMessage(
                .init(
                    chatID: chatKey.chatID,
                    messageID: currentPlaceholder.message_id,
                    text: done + "\n\n<i>↓ продолжение ниже</i>",
                    replyMarkup: stopMarkup
                )
            )
            guard let next = await sendContinuationPlaceholder() else {
                throw CancellationError()
            }
            currentPlaceholder = next
            messageAccumulator = remaining
            lastLength = 0
            lastEdit = clock.now
            isFirstMessage = false
        }

        do {
            try Task.checkCancellation()
            let stream = gateway.stream(request)

            for try await event in stream {
                if Task.isCancelled {
                    isCancelled = true
                    break
                }

                switch event {
                case .text(let chunk):
                    fullAccumulator += chunk
                    messageAccumulator += chunk

                    if messageAccumulator.count >= MessageSplitter.charLimit {
                        try await splitAndContinue()
                        continue
                    }

                    if clock.now - lastEdit > .seconds(3) || (messageAccumulator.count - lastLength) > 300 {
                        do {
                            try await self.telegram.editMessage(
                                .init(
                                    chatID: chatKey.chatID,
                                    messageID: currentPlaceholder.message_id,
                                    text: messageAccumulator,
                                    replyMarkup: stopMarkup
                                )
                            )
                            lastEdit = clock.now
                            lastLength = messageAccumulator.count
                        } catch {
                            if let telegramError = error as? TelegramAPIError,
                               let retryAfter = telegramError.retryAfter {
                                try? await Task.sleep(nanoseconds: UInt64(retryAfter) * 1_000_000_000)
                            } else {
                                throw error
                            }
                        }
                    }

                case .meta(let meta):
                    streamMeta = meta
                }
            }
        } catch is CancellationError {
            isCancelled = true
        } catch {
            logger.error("stream failed: \(error)")
            let userText = "⚠️ <b>Ошибка генерации</b>\n" + UserFacingError.message(error)
            try? await self.telegram.editMessage(
                .init(
                    chatID: chatKey.chatID,
                    messageID: currentPlaceholder.message_id,
                    text: userText,
                    replyMarkup: emptyMarkup
                )
            )
            await self.state.cancelPendingTurn(chatKey: chatKey, generationID: generationID)
            await self.sessionRegistry.finish(generationID: generationID)
            return
        }

        if Task.isCancelled {
            isCancelled = true
        }

        let finalText: String
        if isCancelled {
            let stopNotice = await self.cancellationNotice(for: generationID)
            finalText = messageAccumulator.isEmpty
                ? stopNotice
                : (isFirstMessage ? "" : "<i>↑ продолжение</i>\n\n") + messageAccumulator + "\n\n" + stopNotice
        } else {
            let footer = ResponseFooterFormatter.formatFooter(
                meta: streamMeta,
                fallbackModel: fallbackModel,
                showTokens: options.showStats,
                showCost: options.showCost,
                showModel: options.showModel
            ) ?? ""

            let prefix = isFirstMessage ? "" : "<i>↑ продолжение</i>\n\n"
            finalText = messageAccumulator.isEmpty
                ? "<i>Пустой ответ.</i>\(footer)"
                : prefix + messageAccumulator + footer
        }

        try? await self.telegram.editMessage(
            .init(
                chatID: chatKey.chatID,
                messageID: currentPlaceholder.message_id,
                text: finalText,
                replyMarkup: emptyMarkup
            )
        )

        if isCancelled {
            await self.state.cancelPendingTurn(chatKey: chatKey, generationID: generationID)
        } else if !fullAccumulator.isEmpty {
            await self.state.appendAssistant(chatKey: chatKey, generationID: generationID, content: fullAccumulator, usage: streamMeta?.usage)
        } else {
            await self.state.cancelPendingTurn(chatKey: chatKey, generationID: generationID)
        }
        await self.sessionRegistry.finish(generationID: generationID)
    }

    private func sendUserFeedback(chatKey: ChatKey, text: String) async throws {
        _ = try await telegram.sendMessage(
            .init(
                chatID: chatKey.chatID,
                threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                replyTo: nil,
                text: text,
                replyMarkup: nil
            )
        )
    }
    
    private func unsupportedMediaKinds(
        in refs: [InboundMediaRef],
        capabilities: ProviderCapabilities
    ) -> [InboundMediaKind] {
        var unsupportedKinds: [InboundMediaKind] = []
        
        for kind in refs.map(\.kind) where !capabilities.supports(kind) && !unsupportedKinds.contains(kind) {
            unsupportedKinds.append(kind)
        }
        
        return unsupportedKinds
    }
    
    private func extractMediaRefs(from message: TelegramMessage) -> [InboundMediaRef] {
        var refs: [InboundMediaRef] = []
        
        // Synthetic merged albums expose one already-selected photo per album item here.
        if let albumPhotos = message.album_photos, !albumPhotos.isEmpty {
            refs.append(contentsOf: albumPhotos.map { .photo(fileID: $0.file_id) })
        } else if let photos = message.photo, let bestPhoto = TelegramPhotoAlbumBuffer.selectPrimaryPhoto(from: photos) {
            refs.append(.photo(fileID: bestPhoto.file_id))
        }
        if let voice = message.voice {
            refs.append(.voice(fileID: voice.file_id, mimeType: voice.mime_type))
        }
        if let video = message.video {
            refs.append(.video(fileID: video.file_id, mimeType: video.mime_type))
        }
        
        return refs
    }
    
    private func cancellationNotice(for generationID: GenerationID) async -> String {
        let reason = await sessionRegistry.cancellationReason(for: generationID) ?? .userRequested
        
        switch reason {
        case .userRequested:
            return "⏹ <i>Остановлено</i>"
        }
    }
}
