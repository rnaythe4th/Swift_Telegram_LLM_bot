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

final class GenerationCoordinator: Sendable {
    let telegram: TelegramGatewayPort
    let state: ChatContextStore
    let sessionRegistry: SessionRegistry
    private let mediaResolver: MediaResolverPort
    private let gateways: ProviderGatewayRegistry
    let logger: LoggerPort
    private let botUsername: String
    private let generationLimiter: GenerationLimiter
    let metrics: RuntimeMetrics?
    /// Charging for an answer moves money, so it goes where all money goes.
    let ledger: LedgerPort
    /// A spending ceiling that stops paid models is something the owner has to
    /// hear about, not discover in the logs (§6.1).
    let alerter: OwnerAlerter?

    init(
        telegram: TelegramGatewayPort,
        state: ChatContextStore,
        sessionRegistry: SessionRegistry,
        mediaResolver: MediaResolverPort,
        gateways: ProviderGatewayRegistry,
        logger: LoggerPort,
        botUsername: String,
        generationLimiter: GenerationLimiter,
        ledger: LedgerPort,
        alerter: OwnerAlerter? = nil,
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
        self.ledger = ledger
        self.alerter = alerter
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

        // Free-tier gate with a daily premium "taste" (see the gate itself in
        // +Monetization.swift). A nil verdict means the turn cannot be answered
        // at all — the user has been told why.
        guard let premium = try await resolveDailyPremium(origin: origin, chatKey: chatKey) else { return }
        let premiumTicket = premium.ticket
        let lastPremiumCall = premium.lastCall

        // Billing: covered by a subscription, charged to a wallet, or free-tier
        // (which is what makes it ad-eligible).
        let billing = await resolveBillingMode(origin: origin, chatKey: chatKey)
        let billedTo = billing.billedTo
        let adEligible = billing.adEligible

        let generationID = await sessionRegistry.register(chatKey: chatKey)

        let typingTask = startTypingIndicator(chatKey: chatKey)
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

    /// Typing runs while the answer has nowhere to appear yet: waiting for a
    /// slot on the global limiter and for the first placeholder. Once the
    /// stream starts the visible progress is the draft animation or the
    /// placeholder being edited, so the caller's `defer` stops it as soon as
    /// `streamReply` has handed the work to its task.
    private func startTypingIndicator(chatKey: ChatKey) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                try? await self.telegram.sendChatAction(
                    chatID: chatKey.chatID,
                    threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                    action: "typing"
                )
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    /// Internal, not private: the gate and the offers in +Monetization.swift
    /// speak to the user through it too.
    func sendUserFeedback(chatKey: ChatKey, text: String) async throws {
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
