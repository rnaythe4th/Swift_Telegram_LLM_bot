import Foundation

/// Conversion-funnel event counters for the owner (roadmap step 7). Persisted
/// as a single `bot_config` row (`GlobalConfigKey.funnel`), so the numbers
/// survive restarts and frequent redeploys. These are event counts, not unique
/// users — enough to see where the funnel leaks; cohort/time-windowed retention
/// (D1/D7) needs per-user timestamps and is left for a later step.
enum FunnelEvent: String, CaseIterable, Sendable {
    case start          // /start received
    case firstMessage   // first LLM turn in a chat (activation)
    case capHit         // daily premium allowance exhausted (hit the wall)
    case openPurchase   // purchase page / flow opened
    case invoiceSent    // Telegram invoice sent
    case paid           // first-time subscription activation
    case renewed        // subscription extended
    case creditTopup    // pay-as-you-go credit pack bought

    /// Ordered as the funnel flows, for rendering the super-menu page.
    static let funnelOrder: [FunnelEvent] = [
        .start, .firstMessage, .capHit, .openPurchase, .invoiceSent, .paid, .renewed, .creditTopup,
    ]

    /// Human-readable label for the super-menu funnel page.
    var label: String {
        switch self {
        case .start: return "Старт (/start)"
        case .firstMessage: return "Первое сообщение"
        case .capHit: return "Упёрлись в лимит"
        case .openPurchase: return "Открыли покупку"
        case .invoiceSent: return "Счёт выставлен"
        case .paid: return "Оплатили подписку"
        case .renewed: return "Продлили"
        case .creditTopup: return "Пополнили баланс"
        }
    }
}

/// Aggregated funnel numbers for `/metrics` (JSON) and the super-menu page:
/// the persisted event counters plus sponsor tallies computed live from tenant
/// state (active vs. churned vs. unlimited), which need no separate counter.
struct FunnelReport: Sendable {
    var counters: [String: Int]
    var sponsorsActive: Int
    var sponsorsExpired: Int
    var sponsorsUnlimited: Int

    func count(_ event: FunnelEvent) -> Int { counters[event.rawValue] ?? 0 }

    /// Flat string→int view for the `/metrics` JSON payload.
    var flat: [String: Int] {
        var out = counters
        out["sponsors_active"] = sponsorsActive
        out["sponsors_expired"] = sponsorsExpired
        out["sponsors_unlimited"] = sponsorsUnlimited
        return out
    }
}
