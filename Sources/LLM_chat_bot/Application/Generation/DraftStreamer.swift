import Foundation

/// Streams a partial LLM reply into a Telegram private chat using the native
/// `sendMessageDraft` animation (Bot API 9.3+).
///
/// The smooth "letter by letter" look comes from the size of each draft delta,
/// not from the client alone: large deltas render as jumps. So instead of
/// pushing the raw accumulator as fast as the network allows, a typewriter loop
/// reveals the accumulated text in small steps every tick (~80 ms), adapting
/// the step size to the backlog so it keeps up with fast providers.
///
/// The draft is an ephemeral 30-second preview, so the loop also re-sends the
/// last text while the provider is silent, and the caller must persist the
/// final result via `sendMessage`.
actor DraftStreamer {
    private let telegram: TelegramGatewayPort
    private let chatID: ChatID
    private let threadID: Int64?
    private let logger: LoggerPort
    // Log only the first send failure per draft to avoid flooding.
    private var didLogSendFailure = false

    private var draftID: Int
    // Full accumulated text from the provider (reveal target).
    private var latestText = ""
    // How many characters of latestText are currently revealed in the draft.
    private var revealedLength = 0
    private var lastSentText = ""
    private var lastSendTime: ContinuousClock.Instant?
    private var backoffUntil: ContinuousClock.Instant?
    private var senderTask: Task<Void, Never>?

    private let clock = ContinuousClock()
    // Per the sendMessageDraft streaming guidance: update the draft on a fixed
    // short interval rather than per chunk.
    private static let tickInterval: Duration = .milliseconds(80)
    // Baseline reveal speed: 8 chars per tick ≈ 100 chars/sec.
    private static let minRevealStep = 8
    // Refresh the ephemeral preview while the provider is silent (reasoning
    // models can stall well past the 30-second draft TTL).
    private static let keepaliveInterval: Duration = .seconds(15)

    private init(telegram: TelegramGatewayPort, chatID: ChatID, threadID: Int64?, logger: LoggerPort) {
        self.telegram = telegram
        self.chatID = chatID
        self.threadID = threadID
        self.logger = logger
        self.draftID = Self.makeDraftID()
    }

    /// Returns a started streamer showing the native "Thinking…" placeholder,
    /// or nil when the Bot API server does not support drafts (caller falls
    /// back to edit-based streaming).
    static func begin(
        telegram: TelegramGatewayPort,
        chatID: ChatID,
        threadID: Int64?,
        logger: LoggerPort
    ) async -> DraftStreamer? {
        let streamer = DraftStreamer(telegram: telegram, chatID: chatID, threadID: threadID, logger: logger)
        do {
            try await streamer.start()
        } catch {
            logger.warning("sendMessageDraft unavailable, falling back to edit streaming: \(error)")
            return nil
        }
        logger.info("draft streaming started (chat \(chatID))")
        return streamer
    }

    private func start() async throws {
        try await send(text: "")
        startSenderLoop()
    }

    /// Hands the freshest accumulated text to the typewriter loop. Cheap — no
    /// network call happens here.
    func update(text: String) {
        latestText = text
    }

    /// Starts a fresh draft (new `draft_id`) after the previous part was
    /// persisted via `sendMessage`. The old draft is resolved by that message;
    /// the remainder is re-revealed from the start of the new draft.
    func rotate(initialText: String) {
        draftID = Self.makeDraftID()
        latestText = initialText
        revealedLength = 0
        lastSentText = ""
        lastSendTime = nil
    }

    /// Waits (bounded) for the typewriter to catch up with the full text, so
    /// the final persisted message doesn't land as one big jump. Call after
    /// the stream completed, before `finish()`.
    func awaitReveal(timeout: Duration = .seconds(2)) async {
        let deadline = clock.now + timeout
        while senderTask != nil, revealedLength < latestText.count, clock.now < deadline {
            try? await Task.sleep(for: Self.tickInterval)
        }
    }

    /// Stops the typewriter loop. Call right before persisting the final message.
    func finish() {
        senderTask?.cancel()
        senderTask = nil
    }

    private func startSenderLoop() {
        senderTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                await self?.tick()
            }
        }
    }

    private func tick() async {
        if let backoffUntil, clock.now < backoffUntil { return }

        let target = latestText
        if revealedLength < target.count {
            // Adaptive step: smooth at the baseline, accelerates with backlog
            // so the reveal never lags far behind a fast stream.
            let backlog = target.count - revealedLength
            let step = max(Self.minRevealStep, backlog / 8)
            revealedLength = min(target.count, revealedLength + step)

            let prefix = Self.trimDanglingTag(String(target.prefix(revealedLength)))
            guard prefix != lastSentText else { return }
            do {
                try await send(text: prefix)
            } catch let error as TelegramAPIError where error.retryAfter != nil {
                backoffUntil = clock.now + .seconds(error.retryAfter ?? 1)
            } catch {
                // Best effort — the final sendMessage persists the reply anyway.
                if !didLogSendFailure {
                    didLogSendFailure = true
                    logger.warning("draft update failed (chat \(chatID)): \(error)")
                }
            }
        } else if let lastSendTime, clock.now - lastSendTime >= Self.keepaliveInterval {
            try? await send(text: lastSentText)
        }
    }

    private func send(text: String) async throws {
        try await telegram.sendMessageDraft(
            .init(chatID: chatID, threadID: threadID, draftID: draftID, text: text)
        )
        lastSentText = text
        lastSendTime = clock.now
        backoffUntil = nil
    }

    // A reveal cut can land inside an HTML tag; the sanitizer would then show
    // the fragment literally for one tick. Trim back to the last complete tag.
    private static func trimDanglingTag(_ text: String) -> String {
        guard let lastOpen = text.lastIndex(of: "<") else { return text }
        if text[lastOpen...].contains(">") { return text }
        return String(text[..<lastOpen])
    }

    private static func makeDraftID() -> Int {
        // Non-zero, random to avoid collisions between concurrent generations
        // in the same chat.
        Int.random(in: 1...Int(Int32.max))
    }
}
