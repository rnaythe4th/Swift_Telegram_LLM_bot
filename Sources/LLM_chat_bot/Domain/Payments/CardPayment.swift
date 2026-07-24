import Foundation

/// Fiat currencies offered for card payments through Telegram Payments.
/// All listed currencies use 2 decimal places (minor units = cents/kopecks).
enum CardCurrency: String, Codable, Sendable, CaseIterable {
    case rub = "RUB"
    case usd = "USD"
    case eur = "EUR"

    var symbol: String {
        switch self {
        case .rub: return "₽"
        case .usd: return "$"
        case .eur: return "€"
        }
    }

    /// Telegram enforces provider-specific minimums; these are sane lower bounds
    /// used for input validation only (in minor units).
    var minMinorUnits: Int {
        switch self {
        case .rub: return 10_000   // 100 ₽
        case .usd: return 100      // $1
        case .eur: return 100      // €1
        }
    }

    func format(minorUnits: Int) -> String {
        let whole = minorUnits / 100
        let frac = minorUnits % 100
        if frac == 0 { return "\(whole) \(symbol)" }
        return String(format: "%d.%02d %@", whole, frac, symbol)
    }
}

/// Card acquiring configuration (Telegram Payments via a BotFather-connected
/// provider: YooKassa, Stripe, Smart Glocal, …). Managed entirely from the
/// super-admin menu; the provider token is stored in bot state, not in env.
struct CardPaymentConfig: Codable, Sendable {
    /// Token issued by BotFather after connecting a payment provider.
    var providerToken: String?
    var currency: CardCurrency
    /// Subscription price in minor units (cents/kopecks); nil = sales off.
    var priceMinorUnits: Int?

    static let empty = CardPaymentConfig(providerToken: nil, currency: .rub, priceMinorUnits: nil)

    var isEnabled: Bool {
        guard let token = providerToken, !token.isEmpty else { return false }
        return (priceMinorUnits ?? 0) > 0
    }

    var priceLabel: String? {
        priceMinorUnits.map { currency.format(minorUnits: $0) }
    }

    /// Token masked for display: enough to recognize, useless to steal.
    var maskedToken: String? {
        guard let token = providerToken, !token.isEmpty else { return nil }
        guard token.count > 14 else { return String(repeating: "•", count: token.count) }
        return "\(token.prefix(10))…\(token.suffix(4))"
    }

    /// True for tokens BotFather marks as test-mode (`:TEST:` segment).
    var isTestToken: Bool {
        providerToken?.contains(":TEST:") ?? false
    }
}
