import Foundation

// The generation pipeline: access gate, billing mode, history snapshot and the
// hand-off to a streamer. Delivery and monetization live in the +*.swift files.

private enum ReplyContentResolution {
    case none
    case unsupported(String)
    case content(UserInputContent)
}

/// The answer outgrew one message and the continuation message could not be
/// sent, so there is nowhere left to stream. Its own type because the only
/// alternative on hand — `CancellationError` — makes the bot report «⏹
/// Остановлено» to a user who stopped nothing.
struct ContinuationUnavailable: Error {}

/// Everything a turn needs to know about who asked and where. A real Telegram
/// message yields one; so does a synthetic turn started from a button (an
/// onboarding example, roadmap step 9), which has no message of its own.
struct GenerationOrigin: Sendable {
    let user: TelegramUser?
    let isPrivate: Bool
    /// Message the reply should quote; nil = plain reply.
    let replyToMessageID: Int?

    init(user: TelegramUser?, isPrivate: Bool, replyToMessageID: Int?) {
        self.user = user
        self.isPrivate = isPrivate
        self.replyToMessageID = replyToMessageID
    }

    init(message: TelegramMessage) {
        self.init(
            user: message.from,
            isPrivate: message.chat.type == "private",
            replyToMessageID: message.message_id
        )
    }
}

final class GenerationCoordinator: @unchecked Sendable {
    let telegram: TelegramGatewayPort
    let state: ChatContextStore
    let sessionRegistry: SessionRegistry
    private let mediaResolver: MediaResolverPort
    private let gateways: ProviderGatewayRegistry
    let logger: LoggerPort
    private let botUsername: String
    private let generationLimiter: GenerationLimiter
    private let metrics: RuntimeMetrics?

    init(
        telegram: TelegramGatewayPort,
        state: ChatContextStore,
        sessionRegistry: SessionRegistry,
        mediaResolver: MediaResolverPort,
        gateways: ProviderGatewayRegistry,
        logger: LoggerPort,
        botUsername: String,
        generationLimiter: GenerationLimiter,
        metrics: RuntimeMetrics? = nil
    ) {
        self.telegram = telegram
        self.state = state
        self.sessionRegistry = sessionRegistry
        self.mediaResolver = mediaResolver
        self.gateways = gateways
        self.logger = logger
        self.botUsername = botUsername
        self.generationLimiter = generationLimiter
        self.metrics = metrics
    }

    /// Releases the concurrency slot and closes the session. Every generation
    /// that passed `generationLimiter.acquire()` must end through here exactly
    /// once, whatever path it takes.
    func finishGeneration(_ generationID: GenerationID) async {
        await generationLimiter.release()
        await sessionRegistry.finish(generationID: generationID)
    }

    func handleIfNeeded(message: TelegramMessage, chatKey: ChatKey) async throws {
        switch try await resolveProcessableContent(message: message, chatKey: chatKey) {
        case .content(let content):
            try await processContent(origin: GenerationOrigin(message: message), content: content, chatKey: chatKey)
        case .unsupported(let feedback):
            try await sendUserFeedback(chatKey: chatKey, text: feedback)
        case .none:
            break
        }
    }

    /// Runs a ready-made prompt as a normal turn — the onboarding example
    /// buttons (roadmap step 9). Skips only the routing policy (the tap *is* the
    /// explicit address to the bot); the free-tier gate, billing, ads and
    /// history all behave exactly as for a typed message.
    func runReadyPrompt(text: String, chatKey: ChatKey, origin: GenerationOrigin) async throws {
        try await processContent(
            origin: origin,
            content: UserInputContent(text: text, attachments: []),
            chatKey: chatKey
        )
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
                    "⚠️ Этот сервис ИИ не понимает: \(kinds).\nВыберите другой в /menu → 🔌 Сервис ИИ или отправьте только текст."
                )
            }
        }
        
        let resolved = refs.isEmpty ? [] : try await mediaResolver.resolveMedia(refs)
        return .content(.init(text: normalizedText, attachments: resolved))
    }
    
    func processContent(origin: GenerationOrigin, content: UserInputContent, chatKey: ChatKey) async throws {
        let username = origin.user?.username

        // Funnel: count this chat's first real message (activation, once per chat).
        await state.markFirstMessageIfNeeded(chatKey: chatKey)

        // Referral (roadmap step 10): the invited friend's first real turn is
        // what releases the two-sided reward — in a DM or in a group, since a
        // friend who goes straight to a group chat did exactly what we wanted.
        // Attribution alone pays nothing, so a farm of idle accounts earns
        // nothing; both notices are delivered to DMs (see the method).
        if let userID = origin.user?.id {
            await payReferralIfDue(userID: userID, username: username)
            // Paid traffic: a click that never produced an answer is not an
            // activation, so the campaign is credited here rather than at
            // /start. Idempotent — this runs on every turn.
            await state.markTrafficSourceActivation(userID: userID)
        }

        // Free-tier gate with a daily premium "taste": a sender without full
        // access who selected a paid model gets N smart-model answers per day
        // (group = shared per chat, private = per user). Once the daily
        // allowance is spent, the chat falls back to the first free model and an
        // upgrade is pitched at the pain point. Free models are unlimited
        // (retention); sponsored chats never reach here (hasFullModelAccess).
        let hasAccess = await state.hasFullModelAccess(
            username: username,
            userID: origin.user?.id,
            chatID: chatKey.chatID
        )
        /// Set when this turn spent a daily-premium unit — refunded if the turn
        /// produces no answer; `lastPremiumCall` carries the limit when this was
        /// the last unit of the day (scarcity notice after the answer lands).
        var premiumTicket: DailyPremiumTicket?
        var lastPremiumCall: Int?
        if hasAccess {
            // Access is back (subscription, sponsor, referral or a top-up): give
            // back the paid model the cap had parked, otherwise the purchase
            // silently changes nothing and the chat keeps answering on the
            // fallback (roadmap steps 2 and 6).
            if let restored = await state.restoreDowngradedModel(chatKey: chatKey) {
                try? await sendUserFeedback(
                    chatKey: chatKey,
                    text: "⚡ Дневной лимит вам больше не мешает — вернул умную модель <code>\(restored)</code>. Сменить: /menu → 🤖 Модель"
                )
            }
        } else {
            // Which models are free comes from OpenRouter's catalogue plus the
            // super-admin's pins. When neither is available the set is unknown —
            // and an unknown set must not mean "everything is free": that is the
            // one failure mode that hands every paid model to every user at the
            // owner's expense, silently, for as long as the catalogue is
            // unreachable. Unknown is therefore treated as "assume paid": the
            // daily allowance still applies, and only the fallback is missing.
            let effectiveFree = await state.effectiveFreeModelIDs()
            if effectiveFree == nil {
                logger.warning("free-model set unknown (OpenRouter catalogue unavailable) — treating paid models as capped")
            }
            // A fresh daily allowance gives the parked paid model back — quietly.
            // The gate below only fires while the chat model *is* paid, so a chat
            // sitting on the cap fallback would never reach `consumeDailyPremium`
            // again and the whole daily taste would die after its first day. The
            // purchase path above announces the restore; a new day is routine.
            if await state.remainingDailyPremium(
                chatID: chatKey.chatID,
                userID: origin.user?.id,
                isGroup: !origin.isPrivate
            ).remaining > 0 {
                await state.restoreDowngradedModel(chatKey: chatKey)
            }
            let currentModel = await state.model(chatKey: chatKey)
            if !(effectiveFree?.contains(currentModel) ?? false) {
                let isGroup = !origin.isPrivate
                let decision = await state.consumeDailyPremium(
                    chatID: chatKey.chatID,
                    userID: origin.user?.id,
                    isGroup: isGroup
                )
                switch decision {
                case .allowed(let remaining, let limit):
                    // Daily premium taste: let the paid model answer this turn.
                    // The unit is booked now and given back if the turn ends
                    // without an answer (see `refundPremium`).
                    premiumTicket = DailyPremiumTicket(
                        chatID: chatKey.chatID,
                        userID: origin.user?.id,
                        isGroup: isGroup
                    )
                    lastPremiumCall = remaining == 0 ? limit : nil
                case .exhausted(let limit):
                    await state.bumpFunnel(.capHit)
                    // The fallback is resolved here rather than before the
                    // allowance is spent: a turn that stays inside the daily
                    // quota needs no fallback at all, so an unreachable
                    // catalogue must not cost the user a unit for nothing.
                    guard let firstFree = await state.firstFreeModel() else {
                        // Nothing free to fall back to. Refusing is the only
                        // honest option — the alternative is answering on a paid
                        // model, for free, to someone who has spent their quota.
                        try await sendUserFeedback(
                            chatKey: chatKey,
                            text: "ℹ️ Умные ответы на сегодня закончились, а бесплатные модели сейчас недоступны. Попробуйте позже или откройте премиум: /buy"
                        )
                        return
                    }
                    await state.downgradeModelToFree(chatKey: chatKey, freeModel: firstFree)
                    try? await sendDailyLimitOffer(chatKey: chatKey, isGroup: isGroup, limit: limit, freeModel: firstFree)
                }
            }
        }

        // Billing: a chat covered by a tenant subscription costs the sender
        // nothing; otherwise a sender with a positive balance pays per message
        // (marked-up). Everyone else is free-tier → sees ads.
        let covered = await state.hasSubscriptionCoverage(
            username: username,
            userID: origin.user?.id,
            chatID: chatKey.chatID
        )
        // Wallet key, not a handle: charges follow the person through a rename
        // and work for someone who never set a @username.
        var billedTo: String? = nil
        if !covered {
            billedTo = await state.billingKey(username: username, userID: origin.user?.id)
        }
        let adEligible = !covered && billedTo == nil

        let generationID = await sessionRegistry.register(chatKey: chatKey)

        // Typing runs while the answer has nowhere to appear yet: waiting for a
        // slot on the global limiter and for the first placeholder. Once the
        // stream starts the visible progress is the draft animation or the
        // placeholder being edited, so `defer` stops it as soon as
        // `streamReply` has handed the work to its task.
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

        // Global concurrency cap: with hundreds of chats firing at once the
        // excess waits here (typing indicator already running) instead of
        // exhausting sockets/memory.
        await generationLimiter.acquire()
        await metrics?.increment(MetricName.generationsStarted)
        
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

            let sponsorLine = await sponsorCreditLine(
                chatID: chatKey.chatID,
                askerUsername: origin.user?.username,
                isPrivate: origin.isPrivate
            )

            try await streamReply(
                gateway: gateway,
                request: request,
                fallbackModel: fallbackModel,
                options: snapshot.options,
                chatKey: chatKey,
                replyToMessageID: origin.replyToMessageID,
                generationID: generationID,
                isPrivateChat: origin.isPrivate,
                adEligible: adEligible,
                billedTo: billedTo,
                sponsorLine: sponsorLine,
                premiumTicket: premiumTicket,
                lastPremiumCall: lastPremiumCall
            )
        } catch {
            await state.cancelPendingTurn(chatKey: chatKey, generationID: generationID)
            await refundPremium(premiumTicket)
            await finishGeneration(generationID)
            throw error
        }
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
    
    func cancellationNotice(for generationID: GenerationID) async -> String {
        let reason = await sessionRegistry.cancellationReason(for: generationID) ?? .userRequested
        
        switch reason {
        case .userRequested:
            return "⏹ <i>Остановлено</i>"
        }
    }
}
