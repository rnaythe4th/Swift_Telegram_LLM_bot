import Foundation

/// Outreach around a sponsor's subscription end (roadmap step 8): one renewal
/// reminder before the end date, then winback offers after it.
enum SubscriptionNotice: Sendable, Equatable {
    /// Sent `daysBefore` days before `paidUntil`. Several waves are allowed
    /// (e.g. "за 3 дня" and "завтра"), each deduplicated on its own key.
    case expiring(daysBefore: Int)
    /// Sent `dayOffset` days after `paidUntil`.
    case winback(dayOffset: Int)

    /// Stable key for the per-cycle "already sent" set stored on the tenant.
    var key: String {
        switch self {
        case .expiring(let days): return "expiring\(days)"
        case .winback(let day): return "winback\(day)"
        }
    }

    /// Key written by builds that only supported one pre-expiry reminder. A
    /// cycle that already carries it must not be reminded again by the widest
    /// wave, so in-flight subscriptions survive the upgrade without a resend.
    static let legacyExpiringKey = "expiring"

    var isWinback: Bool {
        if case .winback = self { return true }
        return false
    }
}

/// Super-admin-tunable schedule for renewal reminders and winback offers.
/// Persisted as one `bot_config` row (`GlobalConfigKey.reminders`) so the whole
/// cadence is changeable live, without a redeploy.
struct SubscriptionReminderConfig: Codable, Sendable, Equatable {
    /// Master switch — off means the sweep sends nothing at all.
    var enabled: Bool
    /// Days before the end at which the sponsor is reminded, e.g. `[3, 1]`
    /// ("за три дня" and "завтра"). Empty = no pre-expiry reminder at all.
    /// One reminder converts the people who were going to renew anyway; the
    /// last-day one catches those who meant to and forgot.
    var expiryReminderDays: [Int]
    /// Days after expiry at which winback offers go out, e.g. `[1, 7]`.
    var winbackDays: [Int]
    /// Discount a winback offer attaches to the sponsor's next purchase.
    var winbackDiscountPercent: Int
    /// How long a granted winback discount stays valid.
    var winbackOfferHours: Int
    /// How often the background sweep scans subscriptions.
    var sweepIntervalMinutes: Int
    /// Also post the notice to the sponsor's group chats: any member can renew,
    /// and the sponsor may be long gone. Never more than one per cycle per chat.
    var notifyChats: Bool
    /// Days of silence after which a *lapsed wallet* gets one offer to come
    /// back (0 = off). Subscriptions expire loudly; a pay-as-you-go balance
    /// just runs out and the person drifts away — same churn, no signal.
    /// The audience is deliberately tiny: only people who really paid in.
    var walletWinbackDays: Int

    static let `default` = SubscriptionReminderConfig(
        enabled: true,
        expiryReminderDays: [3, 1],
        winbackDays: [1, 7],
        winbackDiscountPercent: 30,
        winbackOfferHours: 48,
        sweepIntervalMinutes: 60,
        notifyChats: true,
        walletWinbackDays: 7
    )

    // Bounds: a typo must not be able to spam every sponsor or stall the loop.
    static let daysBeforeRange = 1...30
    static let winbackDayRange = 1...90
    static let discountRange = 0...90
    static let offerHoursRange = 1...720
    static let sweepIntervalRange = 5...1440
    static let walletWinbackRange = 0...180
    static let maxWinbackWaves = 5
    static let maxExpiryWaves = 3

    /// Widest pre-expiry wave — the horizon "who is about to lapse" is measured
    /// against. 0 when pre-expiry reminders are off.
    var daysBeforeExpiry: Int { expiryReminderDays.max() ?? 0 }

    /// A winback wave only fires inside this window after its day offset. Past
    /// it the subscription counts as long gone, so switching the feature on (or
    /// coming back from downtime) never blasts everyone who ever churned.
    var winbackCatchUpWindow: TimeInterval {
        max(86_400, Double(winbackOfferHours) * 3600)
    }

    /// Clamped copy. Every setter and the decoder go through this, so stored or
    /// hand-typed values can never put the sweep outside sane bounds.
    var normalized: SubscriptionReminderConfig {
        var copy = self
        copy.expiryReminderDays = Array(
            Set(expiryReminderDays.filter { Self.daysBeforeRange.contains($0) })
        ).sorted(by: >).prefix(Self.maxExpiryWaves).map { $0 }
        copy.winbackDays = Array(
            Set(winbackDays.filter { Self.winbackDayRange.contains($0) })
        ).sorted().prefix(Self.maxWinbackWaves).map { $0 }
        copy.winbackDiscountPercent = Self.clamp(winbackDiscountPercent, Self.discountRange)
        copy.winbackOfferHours = Self.clamp(winbackOfferHours, Self.offerHoursRange)
        copy.sweepIntervalMinutes = Self.clamp(sweepIntervalMinutes, Self.sweepIntervalRange)
        copy.walletWinbackDays = Self.clamp(walletWinbackDays, Self.walletWinbackRange)
        return copy
    }

    private static func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// The notice due for a subscription ending at `paidUntil`, given what was
    /// already delivered in this cycle. Pure decision — no store, no network —
    /// so the schedule can be reasoned about in one place.
    func dueNotice(paidUntil: Date, alreadySent: Set<String>, now: Date) -> SubscriptionNotice? {
        guard enabled else { return nil }
        if now >= paidUntil {
            // After expiry: the latest winback wave whose catch-up window is
            // still open. Later waves win, so downtime never replays old ones.
            let elapsed = now.timeIntervalSince(paidUntil)
            for day in winbackDays.sorted(by: >) {
                let offset = Double(day) * 86_400
                guard elapsed >= offset, elapsed < offset + winbackCatchUpWindow else { continue }
                let notice = SubscriptionNotice.winback(dayOffset: day)
                return alreadySent.contains(notice.key) ? nil : notice
            }
            return nil
        }
        // Before expiry: the *nearest* wave whose lead time has been reached.
        // Checking ascending means "завтра" wins over "за три дня", and a wave
        // missed during downtime is skipped rather than replayed late.
        guard !expiryReminderDays.isEmpty else { return nil }
        let remaining = paidUntil.timeIntervalSince(now)
        let widest = expiryReminderDays.max()
        for day in expiryReminderDays.sorted() {
            guard remaining <= Double(day) * 86_400 else { continue }
            let notice = SubscriptionNotice.expiring(daysBefore: day)
            if alreadySent.contains(notice.key) { return nil }
            // A cycle reminded by an older build carries the legacy key; that
            // counts as the widest wave having gone out already.
            if day == widest, alreadySent.contains(SubscriptionNotice.legacyExpiringKey) { return nil }
            return notice
        }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case enabled, expiryReminderDays, daysBeforeExpiry, winbackDays, winbackDiscountPercent
        case winbackOfferHours, sweepIntervalMinutes, notifyChats, walletWinbackDays
    }

    init(
        enabled: Bool,
        expiryReminderDays: [Int],
        winbackDays: [Int],
        winbackDiscountPercent: Int,
        winbackOfferHours: Int,
        sweepIntervalMinutes: Int,
        notifyChats: Bool,
        walletWinbackDays: Int
    ) {
        self.enabled = enabled
        self.expiryReminderDays = expiryReminderDays
        self.winbackDays = winbackDays
        self.winbackDiscountPercent = winbackDiscountPercent
        self.winbackOfferHours = winbackOfferHours
        self.sweepIntervalMinutes = sweepIntervalMinutes
        self.notifyChats = notifyChats
        self.walletWinbackDays = walletWinbackDays
    }

    /// Missing fields fall back to the defaults, so a row written by an older
    /// build (or a partially edited one) still decodes. A row that only carries
    /// the single `daysBeforeExpiry` of earlier builds becomes a one-wave list.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = SubscriptionReminderConfig.default
        let days: [Int]
        if let list = try c.decodeIfPresent([Int].self, forKey: .expiryReminderDays) {
            days = list
        } else if let legacy = try c.decodeIfPresent(Int.self, forKey: .daysBeforeExpiry) {
            days = legacy > 0 ? [legacy] : []
        } else {
            days = fallback.expiryReminderDays
        }
        self.init(
            enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? fallback.enabled,
            expiryReminderDays: days,
            winbackDays: try c.decodeIfPresent([Int].self, forKey: .winbackDays) ?? fallback.winbackDays,
            winbackDiscountPercent: try c.decodeIfPresent(Int.self, forKey: .winbackDiscountPercent) ?? fallback.winbackDiscountPercent,
            winbackOfferHours: try c.decodeIfPresent(Int.self, forKey: .winbackOfferHours) ?? fallback.winbackOfferHours,
            sweepIntervalMinutes: try c.decodeIfPresent(Int.self, forKey: .sweepIntervalMinutes) ?? fallback.sweepIntervalMinutes,
            notifyChats: try c.decodeIfPresent(Bool.self, forKey: .notifyChats) ?? fallback.notifyChats,
            walletWinbackDays: try c.decodeIfPresent(Int.self, forKey: .walletWinbackDays) ?? fallback.walletWinbackDays
        )
        self = self.normalized
    }

    /// Also writes the legacy single-value field, so rolling the binary back
    /// keeps a working (if narrower) schedule instead of resetting to defaults.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(expiryReminderDays, forKey: .expiryReminderDays)
        try c.encode(daysBeforeExpiry, forKey: .daysBeforeExpiry)
        try c.encode(winbackDays, forKey: .winbackDays)
        try c.encode(winbackDiscountPercent, forKey: .winbackDiscountPercent)
        try c.encode(winbackOfferHours, forKey: .winbackOfferHours)
        try c.encode(sweepIntervalMinutes, forKey: .sweepIntervalMinutes)
        try c.encode(notifyChats, forKey: .notifyChats)
        try c.encode(walletWinbackDays, forKey: .walletWinbackDays)
    }
}

/// A time-limited price cut attached to one sponsor's account (winback offer).
/// Consumed by the next subscription purchase, whatever the payment method.
struct SubscriptionDiscount: Codable, Sendable, Equatable {
    var percent: Int
    var expiresAt: Date

    /// `grace` lets checkout still honor an invoice opened moments before the
    /// offer ran out — the user must not be charged the full price silently.
    func isActive(now: Date = Date(), grace: TimeInterval = 0) -> Bool {
        percent > 0 && expiresAt.addingTimeInterval(grace) > now
    }

    /// Applies the cut to an integer price (Stars, USD cents, minor units).
    func apply(to amount: Int) -> Int {
        guard percent > 0, amount > 0 else { return amount }
        return max(1, Int((Double(amount) * Double(100 - percent) / 100.0).rounded()))
    }
}

/// One notice the sweep decided to send, with the channels it can go out on.
struct SubscriptionNoticeTarget: Sendable {
    /// Storage key of the sponsor — pass it back to the store,
    /// keys round-trip unchanged. Use `label` for anything a person reads.
    let key: UserKey
    /// Ready-to-print name: `@username` / first name / `id <n>`.
    let label: String
    let notice: SubscriptionNotice
    let paidUntil: Date
    /// The sponsor's DM with the bot — known only if they ever wrote to it
    /// (Telegram forbids bot-initiated conversations).
    let privateChatID: Int?
    /// Group chats this sponsor covers; any member there can renew. Always
    /// filled (the text quotes the count); whether they are actually notified
    /// is the sender's decision, per `notifyChats`.
    let groupChatIDs: [Int]
}

/// Subscription prices for one user with any active winback discount applied.
/// Every purchase path reads prices from here, so a discount can never be
/// advertised and then not honored at checkout.
struct SubscriptionPricing: Sendable {
    var discount: SubscriptionDiscount?
    var starsFull: Int?
    var stars: Int?
    var cryptoCentsFull: Int?
    var cryptoCents: Int?
    var cardMinorUnitsFull: Int?
    var cardMinorUnits: Int?
    /// Card amounts pre-formatted with their currency (the store knows it).
    var cardLabelFull: String?
    var cardLabel: String?
    /// Hosted checkout (§7 «Внешняя касса»). Here rather than computed at the
    /// call site for the same reason as the card: a winback discount lives on
    /// the account, and a price quoted anywhere but here would drift from the
    /// price actually charged.
    var externalMinorUnitsFull: Int?
    var externalMinorUnits: Int?
    var externalLabelFull: String?
    var externalLabel: String?

    /// True only when the discount actually changes a quoted price.
    var hasDiscount: Bool {
        guard discount != nil else { return false }
        return stars != starsFull
            || cryptoCents != cryptoCentsFull
            || cardMinorUnits != cardMinorUnitsFull
            || externalMinorUnits != externalMinorUnitsFull
    }
}

/// Monitoring snapshot behind the super-admin reminders page.
struct SubscriptionLifecycleStats: Sendable {
    struct Row: Sendable {
        /// Storage key; `label` is what the interface prints.
        let key: UserKey
        let label: String
        let paidUntil: Date
        /// Reachable = has a DM with the bot or at least one covered group.
        let reachable: Bool
        let optedOut: Bool
    }

    var sponsors: Int = 0
    var expiringSoon: [Row] = []
    var recentlyExpired: [Row] = []
    var activeDiscounts: [(label: String, discount: SubscriptionDiscount)] = []
    var unreachable: Int = 0
    var optedOut: Int = 0
}
