import Foundation

/// Conversion-funnel event counters for the owner (roadmap step 7). Persisted
/// as a single `bot_config` row (`GlobalConfigKey.funnel`), so the numbers
/// survive restarts and frequent redeploys. These are event counts, not unique
/// users — enough to see where the funnel leaks.
enum FunnelEvent: String, CaseIterable, Sendable {
    case start          // /start received
    case addedToGroup   // bot added to a new group (viral growth, roadmap step 4)
    case onboardingShown // greeting delivered with example buttons (step 9)
    case exampleTapped  // an onboarding example prompt was tapped (step 9)
    case firstMessage   // first LLM turn in a chat (activation)
    case capHit         // daily premium allowance exhausted (hit the wall)
    case capWarned      // last daily premium answer spent (scarcity notice, step 6)
    case promoShown     // built-in self-promo filled the ad slot (step 5)
    case balanceEmpty   // a pay-as-you-go wallet ran dry after a charge (step 5)
    case openPurchase   // purchase page / flow opened
    case invoiceSent    // Telegram invoice sent
    case paid           // first-time subscription activation
    case renewed        // subscription extended
    case creditTopup    // pay-as-you-go credit pack bought
    case expiryReminder // renewal reminder delivered before expiry (step 8)
    case winbackSent    // winback offer delivered after expiry (step 8)
    case winbackRedeemed // a purchase used a live winback discount (step 8)
    case walletWinbackSent // lapsed-wallet offer delivered (step 8, wallets)
    case referralJoined   // someone opened a referral link and was attributed (step 10)
    case referralRewarded // a referral pair was paid after the friend's first answer (step 10)
    case referralPaidBonus // an invited friend paid, and their inviter got the bonus (step 10)

    /// Ordered as the funnel flows, for rendering the super-menu page.
    static let funnelOrder: [FunnelEvent] = [
        .start, .addedToGroup, .onboardingShown, .exampleTapped, .firstMessage,
        .capHit, .capWarned, .promoShown, .balanceEmpty,
        .openPurchase, .invoiceSent, .paid, .renewed, .creditTopup,
        .expiryReminder, .winbackSent, .winbackRedeemed, .walletWinbackSent,
        .referralJoined, .referralRewarded, .referralPaidBonus,
    ]

    /// Human-readable label for the super-menu funnel page.
    var label: String {
        switch self {
        case .start: return "Старт (/start)"
        case .addedToGroup: return "Добавлен в группу"
        case .onboardingShown: return "Примеры показаны"
        case .exampleTapped: return "Тап по примеру"
        case .firstMessage: return "Первое сообщение"
        case .capHit: return "Упёрлись в лимит"
        case .capWarned: return "Предупреждение о последнем ответе"
        case .promoShown: return "Показов само-рекламы"
        case .balanceEmpty: return "Баланс закончился"
        case .openPurchase: return "Открыли покупку"
        case .invoiceSent: return "Счёт выставлен"
        case .paid: return "Оплатили подписку"
        case .renewed: return "Продлили"
        case .creditTopup: return "Пополнили баланс"
        case .expiryReminder: return "Напоминание о продлении"
        case .winbackSent: return "Winback-оффер отправлен"
        case .winbackRedeemed: return "Winback → оплата"
        case .walletWinbackSent: return "Возврат по балансу отправлен"
        case .referralJoined: return "Пришли по реф-ссылке"
        case .referralRewarded: return "Реферал → награда"
        case .referralPaidBonus: return "Реферал → друг оплатил"
        }
    }
}

/// Which surface sent a person to the purchase page. Without it every open
/// looks the same and the pain-point upsells (step 5) cannot be compared with
/// the plain menu button — which is exactly the decision step 7 exists to
/// inform ("куда бить дальше").
enum PurchaseSource: String, CaseIterable, Sendable {
    case menu       // "⚡ Премиум-доступ" in /menu
    case cap        // daily-limit offer (step 6)
    case promo      // built-in self-promo ad (step 5)
    case welcome    // group greeting (step 4)
    case command    // /buy
    case reminder   // renewal reminder / winback (step 8)
    case balance    // "balance ran out" notice (step 5)
    case referral   // referral page
    case model      // model picker, where a paid model is out of reach
    case mode       // a ⭐ reference mode tapped without access
    case tuning     // "⚙️ Тонкая настройка" opened without access

    var label: String {
        switch self {
        case .menu: return "Меню"
        case .cap: return "Дневной лимит"
        case .promo: return "Само-реклама"
        case .welcome: return "Привет в группе"
        case .command: return "Команда /buy"
        case .reminder: return "Напоминание · winback"
        case .balance: return "Баланс закончился"
        case .referral: return "Приглашения"
        case .model: return "Выбор модели"
        case .mode: return "Режим со звёздочкой"
        case .tuning: return "Тонкая настройка"
        }
    }

    /// Counter key, namespaced under the event so it can never collide with a
    /// `FunnelEvent.rawValue`.
    var counterKey: String { "openPurchase.\(rawValue)" }

    /// Callback suffix (`menu:nav:pay:<raw>`); unknown/absent → the plain menu.
    static func parse(_ raw: String?) -> PurchaseSource {
        guard let raw, let source = PurchaseSource(rawValue: raw) else { return .menu }
        return source
    }
}

/// Period selector for the funnel page. All-time totals answer "how big is
/// this", but only a window answers "is it getting better" — which is the
/// whole point of measuring (step 7 done-when: «числа за период»).
enum FunnelPeriod: String, Sendable, CaseIterable {
    case today
    case week
    case month
    case all

    /// Length of the window in days; nil = everything ever counted.
    var days: Int? {
        switch self {
        case .today: return 1
        case .week: return 7
        case .month: return 30
        case .all: return nil
        }
    }

    var label: String {
        switch self {
        case .today: return "сегодня"
        case .week: return "7 дней"
        case .month: return "30 дней"
        case .all: return "всё время"
        }
    }

    var buttonLabel: String {
        switch self {
        case .today: return "Сегодня"
        case .week: return "7 дней"
        case .month: return "30 дней"
        case .all: return "Всё время"
        }
    }
}

/// Per-day event counts, so the same counters can be read as a window instead
/// of an ever-growing total. Keyed by UTC day number (Unix epoch / 86400) and
/// pruned to `windowDays` — it stays one bounded `bot_config` row
/// (`GlobalConfigKey.funnelDaily`).
struct FunnelDailyLog: Codable, Sendable, Equatable {
    /// A bit more than the longest window offered (30 days), so the oldest
    /// bucket of a 30-day view is never half-pruned.
    static let windowDays = 35

    private(set) var days: [Int: [String: Int]] = [:]

    static let empty = FunnelDailyLog()

    static func dayNumber(_ date: Date = Date()) -> Int {
        Int(date.timeIntervalSince1970 / 86_400)
    }

    mutating func bump(key: String, by amount: Int = 1, now: Date = Date()) {
        days[Self.dayNumber(now), default: [:]][key, default: 0] += amount
        // Pruning is always relative to the real current day, never to the
        // timestamp of the write: a backdated bump must not be able to keep the
        // row growing (or to wipe newer buckets).
        if days.count > Self.windowDays { prune() }
    }

    mutating func prune(now: Date = Date()) {
        let oldestKept = Self.dayNumber(now) - (Self.windowDays - 1)
        days = days.filter { $0.key >= oldestKept }
    }

    /// Counters summed over the last `lastDays` days (1 = today only).
    func counts(lastDays: Int, now: Date = Date()) -> [String: Int] {
        let firstDay = Self.dayNumber(now) - (lastDays - 1)
        var out: [String: Int] = [:]
        for (day, counters) in days where day >= firstDay {
            for (key, value) in counters { out[key, default: 0] += value }
        }
        return out
    }

    // JSON object keys must be strings, day numbers are ints.
    enum CodingKeys: String, CodingKey { case days }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try container.decodeIfPresent([String: [String: Int]].self, forKey: .days) ?? [:]
        for (key, counters) in stored {
            guard let day = Int(key) else { continue }
            days[day] = counters
        }
        prune()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var stored: [String: [String: Int]] = [:]
        for (day, counters) in days { stored[String(day)] = counters }
        try container.encode(stored, forKey: .days)
    }
}

/// Retention proxy computed from the two timestamps the user directory already
/// keeps (first sighting + last sighting). It answers "did this person ever
/// come back a day / a week after they arrived" — not the textbook "were they
/// active exactly on day 1". Real cohort retention needs per-day activity
/// records; this costs one optional field and answers the question that
/// matters (возвращаются ли люди вообще).
struct RetentionSnapshot: Sendable, Equatable {
    var cohortD1 = 0
    var returnedD1 = 0
    var cohortD7 = 0
    var returnedD7 = 0

    func percent(_ part: Int, _ whole: Int) -> String {
        guard whole > 0 else { return "—" }
        return String(format: "%.0f%%", Double(part) / Double(whole) * 100)
    }

    var d1Label: String { percent(returnedD1, cohortD1) }
    var d7Label: String { percent(returnedD7, cohortD7) }
}

/// Aggregated funnel numbers for `/metrics` (JSON) and the super-menu page:
/// the persisted event counters (all-time plus windows) and live tallies
/// computed from tenant/directory state, which need no separate counter.
struct FunnelReport: Sendable {
    var counters: [String: Int]
    /// Windowed views of the same counters (roadmap step 7: «за период»).
    var todayCounters: [String: Int] = [:]
    var weekCounters: [String: Int] = [:]
    var monthCounters: [String: Int] = [:]
    var retention = RetentionSnapshot()
    var sponsorsActive: Int
    var sponsorsExpired: Int
    var sponsorsUnlimited: Int
    /// Active sponsors inside the pre-expiry reminder window (roadmap step 8).
    var sponsorsExpiringSoon: Int
    /// Winback offers currently valid.
    var winbackOffersActive: Int
    /// Referral attributions waiting for the friend's first answer (step 10).
    var referralPending: Int
    /// Referral pairs already paid.
    var referralRewarded: Int
    /// What the referral program has paid out so far, in USD cents.
    var referralPaidCents: Int
    /// Invited friends who became paying customers.
    var referralConversions: Int

    func count(_ event: FunnelEvent) -> Int { counters[event.rawValue] ?? 0 }

    func counters(for period: FunnelPeriod) -> [String: Int] {
        switch period {
        case .today: return todayCounters
        case .week: return weekCounters
        case .month: return monthCounters
        case .all: return counters
        }
    }

    func count(_ event: FunnelEvent, in period: FunnelPeriod) -> Int {
        counters(for: period)[event.rawValue] ?? 0
    }

    func count(source: PurchaseSource, in period: FunnelPeriod) -> Int {
        counters(for: period)[source.counterKey] ?? 0
    }

    /// Flat string→int view for the `/metrics` JSON payload (all-time).
    var flat: [String: Int] {
        var out = counters
        out["sponsors_active"] = sponsorsActive
        out["sponsors_expired"] = sponsorsExpired
        out["sponsors_unlimited"] = sponsorsUnlimited
        out["sponsors_expiring_soon"] = sponsorsExpiringSoon
        out["winback_offers_active"] = winbackOffersActive
        out["referral_pending"] = referralPending
        out["referral_rewarded"] = referralRewarded
        out["referral_paid_cents"] = referralPaidCents
        out["referral_conversions"] = referralConversions
        out["retention_cohort_d1"] = retention.cohortD1
        out["retention_returned_d1"] = retention.returnedD1
        out["retention_cohort_d7"] = retention.cohortD7
        out["retention_returned_d7"] = retention.returnedD7
        return out
    }
}
