import Foundation

/// Outreach around a sponsor's subscription end (roadmap step 8): one renewal
/// reminder before the end date, then winback offers after it.
enum SubscriptionNotice: Sendable, Equatable {
    /// Sent `daysBeforeExpiry` days before `paidUntil`.
    case expiring
    /// Sent `dayOffset` days after `paidUntil`.
    case winback(dayOffset: Int)

    /// Stable key for the per-cycle "already sent" set stored on the tenant.
    var key: String {
        switch self {
        case .expiring: return "expiring"
        case .winback(let day): return "winback\(day)"
        }
    }

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
    /// Remind the sponsor this many days before the subscription ends (0 = no
    /// pre-expiry reminder).
    var daysBeforeExpiry: Int
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

    static let `default` = SubscriptionReminderConfig(
        enabled: true,
        daysBeforeExpiry: 3,
        winbackDays: [1, 7],
        winbackDiscountPercent: 30,
        winbackOfferHours: 48,
        sweepIntervalMinutes: 60,
        notifyChats: true
    )

    // Bounds: a typo must not be able to spam every sponsor or stall the loop.
    static let daysBeforeRange = 0...30
    static let winbackDayRange = 1...90
    static let discountRange = 0...90
    static let offerHoursRange = 1...720
    static let sweepIntervalRange = 5...1440
    static let maxWinbackWaves = 5

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
        copy.daysBeforeExpiry = Self.clamp(daysBeforeExpiry, Self.daysBeforeRange)
        copy.winbackDays = Array(
            Set(winbackDays.filter { Self.winbackDayRange.contains($0) })
        ).sorted().prefix(Self.maxWinbackWaves).map { $0 }
        copy.winbackDiscountPercent = Self.clamp(winbackDiscountPercent, Self.discountRange)
        copy.winbackOfferHours = Self.clamp(winbackOfferHours, Self.offerHoursRange)
        copy.sweepIntervalMinutes = Self.clamp(sweepIntervalMinutes, Self.sweepIntervalRange)
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
        guard daysBeforeExpiry > 0 else { return nil }
        let lead = Double(daysBeforeExpiry) * 86_400
        guard paidUntil.timeIntervalSince(now) <= lead else { return nil }
        return alreadySent.contains(SubscriptionNotice.expiring.key) ? nil : .expiring
    }

    enum CodingKeys: String, CodingKey {
        case enabled, daysBeforeExpiry, winbackDays, winbackDiscountPercent
        case winbackOfferHours, sweepIntervalMinutes, notifyChats
    }

    init(
        enabled: Bool,
        daysBeforeExpiry: Int,
        winbackDays: [Int],
        winbackDiscountPercent: Int,
        winbackOfferHours: Int,
        sweepIntervalMinutes: Int,
        notifyChats: Bool
    ) {
        self.enabled = enabled
        self.daysBeforeExpiry = daysBeforeExpiry
        self.winbackDays = winbackDays
        self.winbackDiscountPercent = winbackDiscountPercent
        self.winbackOfferHours = winbackOfferHours
        self.sweepIntervalMinutes = sweepIntervalMinutes
        self.notifyChats = notifyChats
    }

    /// Missing fields fall back to the defaults, so a row written by an older
    /// build (or a partially edited one) still decodes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = SubscriptionReminderConfig.default
        self.init(
            enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? fallback.enabled,
            daysBeforeExpiry: try c.decodeIfPresent(Int.self, forKey: .daysBeforeExpiry) ?? fallback.daysBeforeExpiry,
            winbackDays: try c.decodeIfPresent([Int].self, forKey: .winbackDays) ?? fallback.winbackDays,
            winbackDiscountPercent: try c.decodeIfPresent(Int.self, forKey: .winbackDiscountPercent) ?? fallback.winbackDiscountPercent,
            winbackOfferHours: try c.decodeIfPresent(Int.self, forKey: .winbackOfferHours) ?? fallback.winbackOfferHours,
            sweepIntervalMinutes: try c.decodeIfPresent(Int.self, forKey: .sweepIntervalMinutes) ?? fallback.sweepIntervalMinutes,
            notifyChats: try c.decodeIfPresent(Bool.self, forKey: .notifyChats) ?? fallback.notifyChats
        )
        self = self.normalized
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
    let username: String
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

    /// True only when the discount actually changes a quoted price.
    var hasDiscount: Bool {
        guard discount != nil else { return false }
        return stars != starsFull || cryptoCents != cryptoCentsFull || cardMinorUnits != cardMinorUnitsFull
    }
}

/// Monitoring snapshot behind the super-admin reminders page.
struct SubscriptionLifecycleStats: Sendable {
    struct Row: Sendable {
        let username: String
        let paidUntil: Date
        /// Reachable = has a DM with the bot or at least one covered group.
        let reachable: Bool
        let optedOut: Bool
    }

    var sponsors: Int = 0
    var expiringSoon: [Row] = []
    var recentlyExpired: [Row] = []
    var activeDiscounts: [(username: String, discount: SubscriptionDiscount)] = []
    var unreachable: Int = 0
    var optedOut: Int = 0
}
