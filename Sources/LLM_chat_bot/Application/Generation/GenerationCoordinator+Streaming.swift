import Foundation

// Delivering the answer as it is generated: native drafts in private chats,
// message edits everywhere else.

extension GenerationCoordinator {
    func streamReply(
        gateway: ProviderGatewayPort,
        request: ProviderGatewayRequest,
        fallbackModel: String,
        options: GenerationOptions,
        chatKey: ChatKey,
        replyToMessageID: Int?,
        generationID: GenerationID,
        isPrivateChat: Bool,
        adEligible: Bool,
        billedTo: UserKey?,
        sponsorLine: String?,
        premiumTicket: DailyPremiumTicket?,
        lastPremiumCall: Int?
    ) async throws {
        let stopMarkup = InlineKeyboardMarkup(inline_keyboard: [[
            .init(text: "⏹ Остановить", callback_data: BotCallbackAction.stop(generationID).rawData)
        ]])

        // On failure just rethrow: processContent's catch owns the cleanup
        // (cancelPendingTurn + finishGeneration) — doing it here too would
        // release the generation slot twice.
        let placeholder = try await telegram.sendMessage(
            .init(
                chatID: chatKey.chatID,
                threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                replyTo: replyToMessageID,
                text: "💭 <i>Думаю…</i>",
                replyMarkup: stopMarkup
            )
        )

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
                    controlMessage: placeholder,
                    adEligible: adEligible,
                    billedTo: billedTo,
                    sponsorLine: sponsorLine,
                    premiumTicket: premiumTicket,
                    lastPremiumCall: lastPremiumCall
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
                    stopMarkup: stopMarkup,
                    adEligible: adEligible,
                    billedTo: billedTo,
                    sponsorLine: sponsorLine,
                    premiumTicket: premiumTicket,
                    lastPremiumCall: lastPremiumCall
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
        replyToMessageID: Int?,
        generationID: GenerationID,
        controlMessage: TelegramMessage,
        adEligible: Bool,
        billedTo: UserKey?,
        sponsorLine: String?,
        premiumTicket: DailyPremiumTicket?,
        lastPremiumCall: Int?
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
            // Silence, not slowness, is what kills a turn (§4.5).
            let stream = gateway.stream(request).withIdleTimeout()

            for try await event in stream {
                if Task.isCancelled {
                    isCancelled = true
                    break
                }

                switch event {
                case .text(let chunk):
                    fullAccumulator += chunk
                    messageAccumulator += chunk

                    // Budget in *rendered* characters: escaping (`&` → `&amp;`)
                    // is what actually counts against Telegram's 4096.
                    if MessageSplitter.renderedLength(messageAccumulator) >= MessageSplitter.charLimit {
                        let (done, remaining) = MessageSplitter.splitRendered(messageAccumulator)
                        let prefix = isFirstMessage ? "" : "<i>↑ продолжение</i>\n\n"
                        // Close what the cut left open before the marker, or
                        // the note lands inside the block it follows — inside a
                        // code listing it would read as part of the code. The
                        // continuation re-opens the same tags (splitRendered).
                        let closers = MessageSplitter.closingTagMarkup(in: done)
                        _ = await persist(prefix + done + closers + "\n\n<i>↓ продолжение ниже</i>")
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
            _ = await persist("⚠️ <b>Не получилось ответить</b>\n" + UserFacingError.message(error))
            await removeControlMessage()
            await state.cancelPendingTurn(chatKey: chatKey, generationID: generationID)
            await refundPremium(premiumTicket)
            await finishGeneration(generationID)
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

        // A stream can stop mid-tag (cancelled, or the model just ended there),
        // and the sanitizer closes dangling tags only at the very end — which
        // would put the notice or the footer inside the answer's last block.
        let closers = MessageSplitter.closingTagMarkup(in: messageAccumulator)

        let finalText: String
        if isCancelled {
            let stopNotice = await cancellationNotice(for: generationID)
            finalText = messageAccumulator.isEmpty
                ? stopNotice
                : (isFirstMessage ? "" : "<i>↑ продолжение</i>\n\n") + messageAccumulator + closers + "\n\n" + stopNotice
        } else {
            let footer = await makeFooter(
                streamMeta: streamMeta,
                fallbackModel: fallbackModel,
                options: options,
                billedTo: billedTo,
                hasContent: !fullAccumulator.isEmpty,
                sponsorLine: sponsorLine
            )

            let prefix = isFirstMessage ? "" : "<i>↑ продолжение</i>\n\n"
            finalText = messageAccumulator.isEmpty
                ? "<i>Пустой ответ.</i>\(footer)"
                : prefix + messageAccumulator + closers + footer
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
            await refundPremium(premiumTicket)
        } else if !fullAccumulator.isEmpty {
            let cost = await state.appendAssistant(chatKey: chatKey, generationID: generationID, content: fullAccumulator, usage: streamMeta?.usage)
            let depleted = await chargeForAnswer(
                billedTo: billedTo, cost: cost, generationID: generationID
            )
            if depleted {
                await sendBalanceEmptyNotice(chatKey: chatKey)
            }
            if let limit = lastPremiumCall {
                await sendLastPremiumCallNotice(chatKey: chatKey, isGroup: false, limit: limit)
            }
            if adEligible {
                await maybeServeAd(chatKey: chatKey, isPrivate: true)
            }
        } else {
            await state.cancelPendingTurn(chatKey: chatKey, generationID: generationID)
            await refundPremium(premiumTicket)
        }
        await finishGeneration(generationID)
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
        stopMarkup: InlineKeyboardMarkup,
        adEligible: Bool,
        billedTo: UserKey?,
        sponsorLine: String?,
        premiumTicket: DailyPremiumTicket?,
        lastPremiumCall: Int?
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
        var continuationFailed = false

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
            let (done, remaining) = MessageSplitter.splitRendered(messageAccumulator)
            try? await telegram.editMessage(
                .init(
                    chatID: chatKey.chatID,
                    messageID: currentPlaceholder.message_id,
                    text: done + MessageSplitter.closingTagMarkup(in: done) + "\n\n<i>↓ продолжение ниже</i>",
                    replyMarkup: stopMarkup
                )
            )
            guard let next = await sendContinuationPlaceholder() else {
                // Nowhere to put the rest of the answer. Not a cancellation:
                // reporting it as one would tell the user they pressed Stop.
                throw ContinuationUnavailable()
            }
            currentPlaceholder = next
            messageAccumulator = remaining
            lastLength = 0
            lastEdit = clock.now
            isFirstMessage = false
        }

        do {
            try Task.checkCancellation()
            // Silence, not slowness, is what kills a turn (§4.5).
            let stream = gateway.stream(request).withIdleTimeout()

            for try await event in stream {
                if Task.isCancelled {
                    isCancelled = true
                    break
                }

                switch event {
                case .text(let chunk):
                    fullAccumulator += chunk
                    messageAccumulator += chunk

                    // Rendered length, not raw: the escaped text is what
                    // Telegram measures (see `MessageSplitter.splitRendered`).
                    if MessageSplitter.renderedLength(messageAccumulator) >= MessageSplitter.charLimit {
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
        } catch is ContinuationUnavailable {
            // Keep what has already been streamed and say what happened — the
            // alternative (an error message replacing the placeholder) throws
            // away the part of the answer the user can already read.
            continuationFailed = true
        } catch is CancellationError {
            isCancelled = true
        } catch {
            logger.error("stream failed: \(error)")
            let userText = "⚠️ <b>Не получилось ответить</b>\n" + UserFacingError.message(error)
            try? await self.telegram.editMessage(
                .init(
                    chatID: chatKey.chatID,
                    messageID: currentPlaceholder.message_id,
                    text: userText,
                    replyMarkup: emptyMarkup
                )
            )
            await self.state.cancelPendingTurn(chatKey: chatKey, generationID: generationID)
            await self.refundPremium(premiumTicket)
            await self.finishGeneration(generationID)
            return
        }

        if Task.isCancelled {
            isCancelled = true
        }

        // See the draft path: the trailer must sit outside whatever block the
        // answer stopped inside.
        let closers = MessageSplitter.closingTagMarkup(in: messageAccumulator)

        var finalText: String
        if isCancelled {
            let stopNotice = await self.cancellationNotice(for: generationID)
            finalText = messageAccumulator.isEmpty
                ? stopNotice
                : (isFirstMessage ? "" : "<i>↑ продолжение</i>\n\n") + messageAccumulator + closers + "\n\n" + stopNotice
        } else {
            let footer = await makeFooter(
                streamMeta: streamMeta,
                fallbackModel: fallbackModel,
                options: options,
                billedTo: billedTo,
                hasContent: !fullAccumulator.isEmpty,
                sponsorLine: sponsorLine
            )

            let prefix = isFirstMessage ? "" : "<i>↑ продолжение</i>\n\n"
            finalText = messageAccumulator.isEmpty
                ? "<i>Пустой ответ.</i>\(footer)"
                : prefix + messageAccumulator + closers + footer
        }
        if continuationFailed {
            finalText += "\n\n⚠️ <i>Ответ пришлось оборвать: не удалось отправить продолжение. Повторите запрос.</i>"
        }

        try? await self.telegram.editMessage(
            .init(
                chatID: chatKey.chatID,
                messageID: currentPlaceholder.message_id,
                text: finalText,
                replyMarkup: emptyMarkup
            )
        )

        // Edit streaming serves groups *and* private chats on Bot API servers
        // without drafts, so the copy has to be chosen per chat, not per mode.
        let isGroup = chatKey.chatID < 0
        if isCancelled {
            await self.state.cancelPendingTurn(chatKey: chatKey, generationID: generationID)
            await self.refundPremium(premiumTicket)
        } else if !fullAccumulator.isEmpty {
            let cost = await self.state.appendAssistant(chatKey: chatKey, generationID: generationID, content: fullAccumulator, usage: streamMeta?.usage)
            let depleted = await self.chargeForAnswer(
                billedTo: billedTo, cost: cost, generationID: generationID
            )
            if depleted {
                await self.sendBalanceEmptyNotice(chatKey: chatKey)
            }
            if let limit = lastPremiumCall {
                await self.sendLastPremiumCallNotice(chatKey: chatKey, isGroup: isGroup, limit: limit)
            }
            if adEligible {
                await self.maybeServeAd(chatKey: chatKey, isPrivate: !isGroup)
            }
        } else {
            await self.state.cancelPendingTurn(chatKey: chatKey, generationID: generationID)
            await self.refundPremium(premiumTicket)
        }
        await self.finishGeneration(generationID)
    }
}
