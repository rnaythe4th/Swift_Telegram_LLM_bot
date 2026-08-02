import Foundation

/// Fiat currencies the bot can charge in — Telegram card payments and any
/// hosted checkout (§7 «Внешняя касса»). All listed currencies use 2 decimal
/// places, so a price is always an `Int` of minor units (cents/kopecks) and
/// never a `Double` that rounds differently on two screens.
enum FiatCurrency: String, Codable, Sendable, CaseIterable {
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

    /// `499`, `499.00`, `499,5`, `1 499.90` → minor units. nil for anything that
    /// is not a plain non-negative decimal amount in this currency.
    ///
    /// Integer math on purpose: a payment gateway quotes the amount as a
    /// decimal string and signs that exact string, and `Double("0.29") * 100`
    /// is 28.999999999999996 — one rounding away from rejecting a real payment
    /// as an amount mismatch.
    ///
    /// The arithmetic reports overflow instead of trapping. This parses a field
    /// that arrives from outside the process, and an amount too large to express
    /// has to come back as "malformed" — a crash here would take the whole bot
    /// down and hand the vendor a retry loop against a process that dies on
    /// every delivery.
    static func minorUnits(from raw: String) -> Int? {
        let cleaned = raw
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00a0}", with: "")
            .replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty else { return nil }
        let parts = cleaned.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        // Digits only: `Int` would happily read "-0" and "+5", and a sign that
        // survives into an amount is a sum nobody quoted.
        let wholeText = parts[0]
        guard !wholeText.isEmpty, wholeText.allSatisfy(\.isASCIIDigit), let whole = Int(wholeText) else { return nil }
        let (scaled, overflow) = whole.multipliedReportingOverflow(by: 100)
        guard !overflow else { return nil }
        guard parts.count > 1 else { return scaled }
        let fraction = parts[1]
        guard fraction.allSatisfy(\.isASCIIDigit) else { return nil }
        // More than two decimals is not an amount in this currency; rounding it
        // silently would credit a different sum than the one that was paid.
        guard fraction.count <= 2 else { return nil }
        let padded = fraction + String(repeating: "0", count: 2 - fraction.count)
        guard let cents = Int(padded) else { return nil }
        let (total, sumOverflow) = scaled.addingReportingOverflow(cents)
        guard !sumOverflow else { return nil }
        return total
    }

    /// The decimal string a gateway is given and signs: always two decimals, so
    /// what we sign and what we later compare are produced by one function.
    static func decimalString(minorUnits: Int) -> String {
        String(format: "%d.%02d", minorUnits / 100, abs(minorUnits % 100))
    }
}

private extension Character {
    /// `isNumber` also matches Arabic-Indic and full-width digits, which `Int`
    /// then refuses anyway — an amount is ASCII digits or it is not an amount.
    var isASCIIDigit: Bool { isASCII && isNumber }
}

/// Card acquiring configuration (Telegram Payments via a BotFather-connected
/// provider: YooKassa, Stripe, Smart Glocal, …). Managed entirely from the
/// super-admin menu; the provider token is stored in bot state, not in env.
struct CardPaymentConfig: Codable, Sendable {
    /// Token issued by BotFather after connecting a payment provider. Sealed
    /// (§5.6): it is a live payment credential, and it stays in the form the
    /// row holds it so a missing key cannot cost the merchant the token.
    var providerToken: SealedSecret?
    var currency: FiatCurrency
    /// Subscription price in minor units (cents/kopecks); nil = sales off.
    var priceMinorUnits: Int?
    /// Minor units charged per $1 of a credit pack (roadmap step 2). Credit
    /// packs carry a USD face value, so selling them for a non-USD currency
    /// needs an FX rate — and the super-admin owns it, live, rather than the
    /// bot guessing at a market rate. nil = card top-ups off (subscription
    /// sales are unaffected). Absent in pre-FX rows → decodes to nil.
    var usdRateMinorUnits: Int?

    static let empty = CardPaymentConfig(providerToken: nil, currency: .rub, priceMinorUnits: nil, usdRateMinorUnits: nil)

    enum CodingKeys: String, CodingKey {
        case providerToken, currency, priceMinorUnits, usdRateMinorUnits
    }

    init(providerToken: SealedSecret?, currency: FiatCurrency, priceMinorUnits: Int?, usdRateMinorUnits: Int?) {
        self.providerToken = providerToken
        self.currency = currency
        self.priceMinorUnits = priceMinorUnits
        self.usdRateMinorUnits = usdRateMinorUnits
    }

    /// The provider token is a live payment credential, so it is encrypted at
    /// rest (§5.6); everything else here is a setting. Missing fields decode to
    /// their defaults — one unreadable value must not cost the merchant the
    /// rest of their configuration.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        providerToken = try c.decodeIfPresent(SealedSecret.self, forKey: .providerToken)
        currency = (try? c.decode(FiatCurrency.self, forKey: .currency)) ?? .rub
        priceMinorUnits = try c.decodeIfPresent(Int.self, forKey: .priceMinorUnits)
        usdRateMinorUnits = try c.decodeIfPresent(Int.self, forKey: .usdRateMinorUnits)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(providerToken, forKey: .providerToken)
        try c.encode(currency, forKey: .currency)
        try c.encodeIfPresent(priceMinorUnits, forKey: .priceMinorUnits)
        try c.encodeIfPresent(usdRateMinorUnits, forKey: .usdRateMinorUnits)
    }

    /// The token, or nil when there is none — or when it was sealed under a key
    /// this process does not have, which must read as "not configured" rather
    /// than send an empty token to Telegram.
    var token: String? { providerToken?.value }

    var isEnabled: Bool {
        guard token != nil else { return false }
        return (priceMinorUnits ?? 0) > 0
    }

    /// Card top-ups need a token and an FX rate; the subscription price is
    /// irrelevant to them.
    var creditsEnabled: Bool {
        guard token != nil else { return false }
        return (usdRateMinorUnits ?? 0) > 0
    }

    /// Price of a credit pack in this currency's minor units, never below the
    /// provider's minimum for the currency (Telegram rejects smaller invoices).
    func creditMinorUnits(cents: Int) -> Int? {
        guard let rate = usdRateMinorUnits, rate > 0 else { return nil }
        let raw = Int((Double(cents) / 100.0 * Double(rate)).rounded())
        return max(raw, currency.minMinorUnits)
    }

    var usdRateLabel: String? {
        usdRateMinorUnits.map { "$1 ≈ \(currency.format(minorUnits: $0))" }
    }

    var priceLabel: String? {
        priceMinorUnits.map { currency.format(minorUnits: $0) }
    }

    /// Token masked for display: enough to recognize, useless to steal.
    var maskedToken: String? {
        guard let token else { return nil }
        guard token.count > 14 else { return String(repeating: "•", count: token.count) }
        return "\(token.prefix(10))…\(token.suffix(4))"
    }

    /// True for tokens BotFather marks as test-mode (`:TEST:` segment).
    var isTestToken: Bool {
        token?.contains(":TEST:") ?? false
    }

    /// Stored, but sealed under a key this process does not have. Worth its own
    /// line on the settings page: "не задано" would send the owner back to the
    /// provider for a token that is still in the row — the key is what is gone.
    var tokenIsUnreadable: Bool { providerToken?.isUnreadable ?? false }
}
