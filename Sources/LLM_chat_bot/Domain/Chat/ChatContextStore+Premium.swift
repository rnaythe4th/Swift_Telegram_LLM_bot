import Foundation

// Daily premium taste for the free tier: the counter that gates paid
// models and the refund when a turn produced nothing.

extension ChatContextStore {
    // MARK: - Daily premium "taste" (free-tier)

    enum DailyPremiumDecision: Sendable {
        /// One unit was consumed; the paid model may answer this turn.
        /// `remaining` counts what is left *after* this turn — 0 means the pain
        /// point is one message away, which is worth saying out loud.
        case allowed(remaining: Int, limit: Int)
        /// Today's allowance is spent; caller should fall back to free + upsell.
        /// `limit == 0` means the free premium taste is switched off entirely —
        /// a different message, not "you used 0 of 0".
        case exhausted(limit: Int)
    }

    /// Counter key: a group shares one allowance (social pressure — "кто-нибудь
    /// откройте премиум"), a private chat counts per person.
    private func dailyPremiumKey(chatID: Int, userID: Int?, isGroup: Bool) -> String {
        isGroup ? "c\(chatID)" : "u\(userID ?? chatID)"
    }

    /// Drops entries from previous days. Called on every write, so the row
    /// tracks "free chats active today" rather than growing forever.
    private func pruneDailyPremiumUsage(today: Int) {
        guard premiumDailyUsage.contains(where: { $0.value.day != today }) else { return }
        premiumDailyUsage = premiumDailyUsage.filter { $0.value.day == today }
    }

    /// Consumes one unit of today's free premium allowance for a free-tier
    /// chat/user and reports whether a paid-model answer is allowed. Counter
    /// resets at the UTC day boundary. `.exhausted` does not consume a unit.
    func consumeDailyPremium(chatID: Int, userID: Int?, isGroup: Bool) -> DailyPremiumDecision {
        let limit = dailyPremiumLimitValue
        guard limit > 0 else { return .exhausted(limit: limit) }
        let key = dailyPremiumKey(chatID: chatID, userID: userID, isGroup: isGroup)
        let today = FunnelDailyLog.dayNumber()
        var entry = premiumDailyUsage[key] ?? DailyPremiumUsage(day: today, used: 0)
        if entry.day != today { entry = DailyPremiumUsage(day: today, used: 0) }
        guard entry.used < limit else { return .exhausted(limit: limit) }
        entry.used += 1
        premiumDailyUsage[key] = entry
        pruneDailyPremiumUsage(today: today)
        dirtyConfigs.insert(.dailyPremiumUsage)
        return .allowed(remaining: max(0, limit - entry.used), limit: limit)
    }

    /// Gives a consumed unit back when the turn produced no answer (provider
    /// error, cancellation, empty reply). Without this a failed generation
    /// silently costs a free user one of their few smart answers of the day.
    func refundDailyPremium(chatID: Int, userID: Int?, isGroup: Bool) {
        let key = dailyPremiumKey(chatID: chatID, userID: userID, isGroup: isGroup)
        let today = FunnelDailyLog.dayNumber()
        guard var entry = premiumDailyUsage[key], entry.day == today, entry.used > 0 else { return }
        entry.used -= 1
        premiumDailyUsage[key] = entry
        dirtyConfigs.insert(.dailyPremiumUsage)
    }

    /// Read-only view for the menu: how much of today's taste is left.
    func remainingDailyPremium(chatID: Int, userID: Int?, isGroup: Bool) -> (remaining: Int, limit: Int) {
        let limit = dailyPremiumLimitValue
        guard limit > 0 else { return (0, 0) }
        let key = dailyPremiumKey(chatID: chatID, userID: userID, isGroup: isGroup)
        let entry = premiumDailyUsage[key]
        let used = (entry?.day == FunnelDailyLog.dayNumber()) ? (entry?.used ?? 0) : 0
        return (max(0, limit - used), limit)
    }

    /// May this person point the chat at a paid model right now?
    enum PaidModelAccess: Sendable {
        /// Subscription, sponsor or a positive balance — no daily ceiling.
        case full
        /// Free tier with today's premium taste still unspent.
        case dailyTaste(remaining: Int, limit: Int)
        /// Free tier, allowance spent (or switched off) — only free models.
        case none
    }

    /// Paid-model gate for the pickers (`/model`, menu). Full access aside, a
    /// free-tier chat with units left today must be able to *choose* a smart
    /// model: otherwise the daily taste is reachable only by chats that happened
    /// to have a paid model set before the cap parked it, and nobody can opt in.
    func paidModelAccess(username: String?, userID: Int?, chatID: Int) -> PaidModelAccess {
        if hasFullModelAccess(username: username, userID: userID, chatID: chatID) { return .full }
        let left = remainingDailyPremium(chatID: chatID, userID: userID, isGroup: chatID < 0)
        return left.remaining > 0 ? .dailyTaste(remaining: left.remaining, limit: left.limit) : .none
    }
}
