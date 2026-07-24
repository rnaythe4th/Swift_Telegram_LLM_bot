import Foundation

/// Token-bucket limiter for outbound Telegram Bot API calls.
///
/// Telegram enforces roughly 30 messages/second bot-wide, ~1 message/second
/// sustained per private chat and 20 messages/minute per group. Exceeding the
/// limits produces 429 storms in which whole replies can be lost, so every
/// outbound message waits for a token here before hitting the network.
///
/// Draft updates (`sendMessageDraft`) are cosmetic: they get their own global
/// bucket and are dropped (not queued) when the budget is exhausted — the
/// typewriter loop simply catches up on a later tick.
actor TelegramRateLimiter {
    private struct Bucket {
        var tokens: Double
        var lastRefill: ContinuousClock.Instant
        let capacity: Double
        let refillPerSecond: Double

        init(capacity: Double, refillPerSecond: Double, now: ContinuousClock.Instant) {
            self.tokens = capacity
            self.lastRefill = now
            self.capacity = capacity
            self.refillPerSecond = refillPerSecond
        }

        mutating func refill(now: ContinuousClock.Instant) {
            let elapsed = (now - lastRefill) / .seconds(1)
            guard elapsed > 0 else { return }
            tokens = min(capacity, tokens + elapsed * refillPerSecond)
            lastRefill = now
        }

        /// Consumes a token, or returns the suggested wait until one is available.
        mutating func consume(now: ContinuousClock.Instant) -> Duration? {
            refill(now: now)
            if tokens >= 1 {
                tokens -= 1
                return nil
            }
            let missing = 1 - tokens
            return .seconds(missing / refillPerSecond)
        }
    }

    private let clock = ContinuousClock()
    // Bot-wide budget for real messages, kept under Telegram's ~30/s.
    private var globalMessages: Bucket
    // Separate budget for ephemeral draft updates so streaming previews can
    // never starve actual message delivery.
    private var globalDrafts: Bucket
    // Small shared budget for cosmetic calls (typing indicators).
    private var globalCosmetic: Bucket
    private var perChat: [Int: Bucket] = [:]
    private static let maxTrackedChats = 4096

    init() {
        // Budgets sum to ~29/s sustained — just under Telegram's ~30/s cap.
        let now = ContinuousClock().now
        self.globalMessages = Bucket(capacity: 18, refillPerSecond: 18, now: now)
        self.globalDrafts = Bucket(capacity: 8, refillPerSecond: 8, now: now)
        self.globalCosmetic = Bucket(capacity: 3, refillPerSecond: 3, now: now)
    }

    private func chatBucket(for chatID: Int, now: ContinuousClock.Instant) -> Bucket {
        if let bucket = perChat[chatID] { return bucket }
        pruneIfNeeded(now: now)
        // Private chats: ~1/s sustained with a small burst.
        // Groups/channels (negative IDs): 20 per minute with a small burst.
        let bucket = chatID > 0
            ? Bucket(capacity: 3, refillPerSecond: 1.0, now: now)
            : Bucket(capacity: 4, refillPerSecond: 20.0 / 60.0, now: now)
        perChat[chatID] = bucket
        return bucket
    }

    private func pruneIfNeeded(now: ContinuousClock.Instant) {
        guard perChat.count >= Self.maxTrackedChats else { return }
        // Drop buckets that are fully refilled — they carry no throttling state.
        perChat = perChat.filter { _, bucket in
            var copy = bucket
            copy.refill(now: now)
            return copy.tokens < copy.capacity - 0.01
        }
    }

    /// Waits until both the global and the per-chat budget allow one message.
    /// Used for sendMessage / editMessage / sendInvoice and similar calls whose
    /// loss would be user-visible.
    func waitForMessageSlot(chatID: Int) async {
        while true {
            let wait = nextMessageWait(chatID: chatID)
            guard let wait else { return }
            try? await Task.sleep(for: wait)
        }
    }

    /// Waits for the global message budget only (callback answers, deletes).
    func waitForGlobalSlot() async {
        while true {
            let now = clock.now
            guard let wait = globalMessages.consume(now: now) else { return }
            try? await Task.sleep(for: max(wait, .milliseconds(20)))
        }
    }

    /// Non-blocking draft budget. Returns false when the draft update should be
    /// skipped this tick.
    func tryTakeDraftSlot() -> Bool {
        globalDrafts.consume(now: clock.now) == nil
    }

    /// Non-blocking cosmetic budget (typing indicators).
    func tryTakeCosmeticSlot() -> Bool {
        globalCosmetic.consume(now: clock.now) == nil
    }

    private func nextMessageWait(chatID: Int) -> Duration? {
        let now = clock.now
        var chat = chatBucket(for: chatID, now: now)
        // Check the per-chat budget first without consuming the global token.
        chat.refill(now: now)
        if chat.tokens < 1 {
            let missing = 1 - chat.tokens
            perChat[chatID] = chat
            return max(.seconds(missing / chat.refillPerSecond), .milliseconds(50))
        }
        if let wait = globalMessages.consume(now: now) {
            perChat[chatID] = chat
            return max(wait, .milliseconds(20))
        }
        chat.tokens -= 1
        perChat[chatID] = chat
        return nil
    }
}
