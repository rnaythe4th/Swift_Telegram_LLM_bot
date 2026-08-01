import Foundation

// Third-party hosted checkout ("внешняя касса"): the payment methods Telegram
// and a bare wallet address cannot reach — Сбербанк Онлайн, СБП, российские и
// зарубежные карты, крипта, Binance Pay — sold through one aggregator that
// hosts the payment page and calls the bot back when the money lands.
//
// The shape is deliberately narrow: we sign a link, the person pays on the
// vendor's page with whatever rail they like, the vendor POSTs a signed
// notification to `/payments/<vendor>`. Everything vendor-specific (which rails
// exist, how the signature is built) lives behind `ExternalCheckoutPort`, so a
// second vendor is a new adapter plus a new enum case — never a new payment
// flow.

/// Hosted-checkout vendors the bot knows how to talk to.
///
/// `ExternalCheckoutRegistry` maps every case to an adapter and the build fails
/// while one is missing, so adding a vendor cannot half-land: a case with no
/// adapter is a compile error, not a button that does nothing.
enum ExternalPaymentVendor: String, Codable, Sendable, CaseIterable {
    case freekassa

    var displayName: String {
        switch self {
        case .freekassa: return "FreeKassa"
        }
    }

    /// Where the merchant signs up. Printed on the settings page: a payment
    /// method nobody can find the cabinet for is not configurable.
    var signupURL: String {
        switch self {
        case .freekassa: return "https://freekassa.com/"
        }
    }

    /// The vendor's own words for its credentials. The settings page repeats
    /// them verbatim, so "введите секретное слово 2" points at a field that
    /// exists in the cabinet under that exact name.
    var merchantIDLabel: String {
        switch self {
        case .freekassa: return "ID магазина"
        }
    }

    var secretLabel: String {
        switch self {
        case .freekassa: return "Секретное слово"
        }
    }

    var callbackSecretLabel: String {
        switch self {
        case .freekassa: return "Секретное слово 2"
        }
    }

    /// Path segment of the notification endpoint: `/payments/<slug>`.
    var callbackSlug: String { rawValue }

    /// A starting set of rails, offered behind "↺ Стандартные" on the settings
    /// page. The codes are the vendor's own (FreeKassa: `i`) and they do change
    /// over time — this is a convenience, not a source of truth, which is why
    /// every entry stays editable and deletable afterwards.
    var defaultMethods: [ExternalPaymentMethod] {
        switch self {
        case .freekassa:
            return [
                ExternalPaymentMethod(code: "44", title: "СБП"),
                ExternalPaymentMethod(code: "13", title: "Онлайн-банк (Сбер и др.)"),
                ExternalPaymentMethod(code: "36", title: "Карта РФ"),
                ExternalPaymentMethod(code: "12", title: "Карта МИР"),
                ExternalPaymentMethod(code: "15", title: "USDT · TRC20"),
                ExternalPaymentMethod(code: "17", title: "BNB"),
            ]
        }
    }

    /// Notification URL to paste into the merchant cabinet.
    func callbackURL(publicBaseURL: String) -> String {
        let base = publicBaseURL.hasSuffix("/") ? String(publicBaseURL.dropLast()) : publicBaseURL
        let withScheme = base.contains("://") ? base : "https://\(base)"
        return "\(withScheme)\(ExternalPaymentEndpoint.pathPrefix)\(callbackSlug)"
    }
}

enum ExternalPaymentEndpoint {
    /// `/payments/<vendor>` — the only unauthenticated POST surface besides the
    /// Telegram webhook, and the only one that hands out subscriptions. Its
    /// authentication *is* the vendor signature, so an adapter that skips the
    /// check gives the endpoint away.
    static let pathPrefix = "/payments/"

    /// Vendor named by a request path, or nil when the path is not ours.
    static func vendor(forPath path: String) -> ExternalPaymentVendor? {
        guard path.hasPrefix(pathPrefix) else { return nil }
        let slug = String(path.dropFirst(pathPrefix.count))
        return ExternalPaymentVendor.allCases.first { $0.callbackSlug == slug }
    }
}

/// One payment rail on the vendor's checkout page (Сбербанк, СБП, карта, USDT,
/// Binance Pay…). `code` is the vendor's own identifier, so the rails the bot
/// offers are data the super-admin types in, not a list baked into a release —
/// aggregators add and retire rails constantly.
///
/// An empty method list is the normal case: the checkout page then shows the
/// vendor's full menu and the person picks there.
struct ExternalPaymentMethod: Codable, Sendable, Equatable, Identifiable {
    var id: String { code }
    var code: String
    var title: String
    var enabled: Bool

    init(code: String, title: String, enabled: Bool = true) {
        self.code = code
        self.title = title
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(String.self, forKey: .code)
        title = try container.decode(String.self, forKey: .title)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    static let maxTitleLength = 40
    static let maxCodeLength = 24

    /// `<код> | <название>` — the one-line form the settings page asks for.
    static func parse(_ raw: String) -> ExternalPaymentMethod? {
        let parts = raw.split(separator: "|", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let code = parts.first, !code.isEmpty, code.count <= maxCodeLength else { return nil }
        let title = parts.count > 1 && !parts[1].isEmpty ? String(parts[1].prefix(maxTitleLength)) : code
        return ExternalPaymentMethod(code: code, title: title)
    }
}

/// The three secrets a hosted checkout needs, together. Kept as one
/// non-optional value on purpose: an adapter cannot be handed a half-configured
/// merchant, so "is it set up?" is answered once (`ExternalPaymentConfig
/// .credentials`) instead of at every call site with three `guard let`s.
struct ExternalPaymentCredentials: Sendable, Equatable {
    let merchantID: String
    /// Signs the outgoing checkout link.
    let secretWord: String
    /// Signs the incoming notification. A different secret by design: the one
    /// that travels in a URL the payer can read must not be the one that
    /// authorises a subscription.
    let callbackSecret: String
}

/// Everything the super-admin sets for the external checkout. Lives in
/// `bot_config` (`GlobalConfigKey.externalPayments`) — like every other price in
/// this bot, it is configuration, not a redeploy.
struct ExternalPaymentConfig: Codable, Sendable, Equatable {
    var vendor: ExternalPaymentVendor
    /// Master switch. Off keeps the credentials — a method turned off for a day
    /// should not cost a trip to the merchant cabinet.
    var enabled: Bool
    var merchantID: String?
    var secretWord: String?
    var callbackSecret: String?
    var currency: FiatCurrency
    /// Subscription price in minor units; nil = subscriptions not sold here.
    var priceMinorUnits: Int?
    /// Minor units per $1 of a credit pack. Independent of the subscription
    /// price for the same reason as on the card (§7): switching the monthly
    /// plan off must not kill the cheapest entry point.
    var usdRateMinorUnits: Int?
    var methods: [ExternalPaymentMethod]

    enum CodingKeys: String, CodingKey {
        case vendor, enabled, merchantID, secretWord, callbackSecret
        case currency, priceMinorUnits, usdRateMinorUnits, methods
    }

    static let maxMethods = 8
    /// How long a checkout link is worth keeping. Long enough for a bank app
    /// round-trip and a re-read of the page, short enough that stale orders do
    /// not pile up in one config row.
    static let orderLifetime: TimeInterval = 60 * 60

    static let `default` = ExternalPaymentConfig(
        vendor: .freekassa,
        enabled: false,
        merchantID: nil,
        secretWord: nil,
        callbackSecret: nil,
        currency: .rub,
        priceMinorUnits: nil,
        usdRateMinorUnits: nil,
        methods: []
    )

    init(
        vendor: ExternalPaymentVendor,
        enabled: Bool,
        merchantID: String?,
        secretWord: String?,
        callbackSecret: String?,
        currency: FiatCurrency,
        priceMinorUnits: Int?,
        usdRateMinorUnits: Int?,
        methods: [ExternalPaymentMethod]
    ) {
        self.vendor = vendor
        self.enabled = enabled
        self.merchantID = merchantID
        self.secretWord = secretWord
        self.callbackSecret = callbackSecret
        self.currency = currency
        self.priceMinorUnits = priceMinorUnits
        self.usdRateMinorUnits = usdRateMinorUnits
        self.methods = methods
    }

    /// Hand-written so a row written by an older or newer build still decodes:
    /// one unreadable field here would take the merchant credentials down with
    /// it, and the bot would silently stop accepting money.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // An unknown vendor decodes as "not configured" rather than throwing:
        // a row from a build that knows more vendors than this one must not
        // cost us the rest of the settings.
        vendor = (try? c.decode(ExternalPaymentVendor.self, forKey: .vendor)) ?? .freekassa
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        merchantID = try c.decodeIfPresent(String.self, forKey: .merchantID)
        // The two signing words are the only thing here worth stealing on its
        // own, so they are encrypted at rest (§5.6). A value written before a
        // key was configured comes back unchanged; one written under a key that
        // is now gone comes back empty, which reads as "not configured" rather
        // than as a wrong secret at the vendor.
        secretWord = try c.decodeIfPresent(String.self, forKey: .secretWord).map(SecretBox.open)
        callbackSecret = try c.decodeIfPresent(String.self, forKey: .callbackSecret).map(SecretBox.open)
        currency = (try? c.decode(FiatCurrency.self, forKey: .currency)) ?? .rub
        priceMinorUnits = try c.decodeIfPresent(Int.self, forKey: .priceMinorUnits)
        usdRateMinorUnits = try c.decodeIfPresent(Int.self, forKey: .usdRateMinorUnits)
        methods = (try? c.decode([ExternalPaymentMethod].self, forKey: .methods)) ?? []
    }

    /// Sealed on the way out, so the row never holds a usable signing word.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(vendor, forKey: .vendor)
        try c.encode(enabled, forKey: .enabled)
        try c.encodeIfPresent(merchantID, forKey: .merchantID)
        try c.encodeIfPresent(secretWord.map(SecretBox.seal), forKey: .secretWord)
        try c.encodeIfPresent(callbackSecret.map(SecretBox.seal), forKey: .callbackSecret)
        try c.encode(currency, forKey: .currency)
        try c.encodeIfPresent(priceMinorUnits, forKey: .priceMinorUnits)
        try c.encodeIfPresent(usdRateMinorUnits, forKey: .usdRateMinorUnits)
        try c.encode(methods, forKey: .methods)
    }

    /// Credentials, or nil while any of them is missing. The only way to reach
    /// an adapter, so an unconfigured merchant cannot produce a link that fails
    /// on the vendor's side with a signature error nobody can read.
    var credentials: ExternalPaymentCredentials? {
        guard let merchantID = merchantID?.nonEmpty,
              let secretWord = secretWord?.nonEmpty,
              let callbackSecret = callbackSecret?.nonEmpty else { return nil }
        return ExternalPaymentCredentials(
            merchantID: merchantID,
            secretWord: secretWord,
            callbackSecret: callbackSecret
        )
    }

    /// Ready to accept a notification at all — credentials present and the
    /// switch on. Selling is a separate question (a price has to exist too),
    /// but a callback for an order created earlier must still be honoured.
    var acceptsCallbacks: Bool { enabled && credentials != nil }

    var isEnabled: Bool { acceptsCallbacks && (priceMinorUnits ?? 0) > 0 }

    var creditsEnabled: Bool { acceptsCallbacks && (usdRateMinorUnits ?? 0) > 0 }

    var activeMethods: [ExternalPaymentMethod] { methods.filter { $0.enabled } }

    /// Price of a credit pack in this currency, never below the currency's
    /// floor — aggregators reject a 30 ₽ order outright.
    func creditMinorUnits(cents: Int) -> Int? {
        guard let rate = usdRateMinorUnits, rate > 0 else { return nil }
        let raw = Int((Double(cents) / 100.0 * Double(rate)).rounded())
        return max(raw, currency.minMinorUnits)
    }

    var priceLabel: String? { priceMinorUnits.map { currency.format(minorUnits: $0) } }

    var usdRateLabel: String? { usdRateMinorUnits.map { "$1 ≈ \(currency.format(minorUnits: $0))" } }

    /// Secrets are shown masked and never in full: the settings page is a
    /// Telegram message that lives in a chat history forever.
    static func mask(_ value: String?) -> String? {
        guard let value = value?.nonEmpty else { return nil }
        guard value.count > 6 else { return String(repeating: "•", count: value.count) }
        return "\(value.prefix(2))\(String(repeating: "•", count: max(3, value.count - 4)))\(value.suffix(2))"
    }

    /// Trims, drops empties, dedups method codes and caps the list. Applied on
    /// every set *and* on decode, so a hand-edited row cannot grow unbounded.
    var normalized: ExternalPaymentConfig {
        var copy = self
        copy.merchantID = merchantID?.trimmed.nonEmpty
        copy.secretWord = secretWord?.trimmed.nonEmpty
        copy.callbackSecret = callbackSecret?.trimmed.nonEmpty
        copy.priceMinorUnits = priceMinorUnits.flatMap { $0 > 0 ? $0 : nil }
        copy.usdRateMinorUnits = usdRateMinorUnits.flatMap { $0 > 0 ? $0 : nil }
        var seen = Set<String>()
        copy.methods = methods.compactMap { method -> ExternalPaymentMethod? in
            let code = method.code.trimmed
            guard !code.isEmpty, code.count <= ExternalPaymentMethod.maxCodeLength else { return nil }
            guard seen.insert(code.lowercased()).inserted else { return nil }
            let title = method.title.trimmed.nonEmpty ?? code
            return ExternalPaymentMethod(
                code: code,
                title: String(title.prefix(ExternalPaymentMethod.maxTitleLength)),
                enabled: method.enabled
            )
        }
        if copy.methods.count > Self.maxMethods {
            copy.methods = Array(copy.methods.prefix(Self.maxMethods))
        }
        return copy
    }
}

enum ExternalPaymentOrderStatus: String, Codable, Sendable {
    case pending
    case paid
    case expired
    case cancelled
}

/// One checkout the bot opened for one person. Persisted because the vendor
/// calls back into a *different process instance* than the one that created the
/// link (redeploys happen mid-payment), and because the callback carries only
/// our order id — everything else about the purchase has to be waiting here.
struct ExternalPaymentOrder: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let vendor: ExternalPaymentVendor
    /// Payer's `UserKey` — a rename between opening and paying still credits
    /// the right account (§6).
    let payerKey: UserKey
    /// Referral bonuses and traffic attribution are keyed by userID; a pending
    /// record (someone the bot has only been told about) simply has none.
    let payerUserID: UserID?
    /// Where to answer, and which chat a subscription may claim.
    let chatID: ChatID
    /// Forum topic, when the purchase started in one (`ChatKey.threadID`).
    let threadID: Int64?
    let purpose: PurchasePurpose
    let currency: FiatCurrency
    let amountMinorUnits: Int
    let methodCode: String?
    let createdAt: Date
    var expiresAt: Date
    var status: ExternalPaymentOrderStatus
    var paidAt: Date?
    /// The vendor's own payment id — what the payment is deduplicated by.
    var vendorPaymentID: String?

    var amountLabel: String { currency.format(minorUnits: amountMinorUnits) }

    var isOpen: Bool { status == .pending }

    /// Order ids travel in a URL and come back in a form body, so they stay in
    /// `[a-z0-9]`: nothing to escape, nothing to smuggle.
    static func makeID() -> String {
        let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return String(raw.prefix(24))
    }
}

/// Config + open orders in one row (`bot_config` → `external_payments`).
struct ExternalPaymentSnapshot: Codable, Sendable {
    var config: ExternalPaymentConfig
    var orders: [ExternalPaymentOrder]

    static let empty = ExternalPaymentSnapshot(config: .default, orders: [])

    init(config: ExternalPaymentConfig, orders: [ExternalPaymentOrder]) {
        self.config = config
        self.orders = orders
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        config = (try? c.decode(ExternalPaymentConfig.self, forKey: .config)) ?? .default
        // One unreadable order must not cost the merchant credentials that sit
        // in the same row — decode what parses, drop what does not.
        orders = (try? c.decode([ExternalPaymentOrder].self, forKey: .orders)) ?? []
    }
}

enum ExternalPaymentError: LocalizedError, Equatable {
    /// Nothing to sign with: the merchant is not set up.
    case notConfigured
    /// Configured, but this particular thing is not for sale.
    case priceNotSet
    case badSignature
    case unknownOrder(String)
    case orderClosed(ExternalPaymentOrderStatus)
    case amountMismatch(expectedMinorUnits: Int, receivedMinorUnits: Int)
    case malformedCallback(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Этот способ оплаты пока не настроен — выберите другой."
        case .priceNotSet:
            return "Цена для этого способа оплаты не задана — выберите другой."
        case .badSignature:
            return "Подпись уведомления не совпала."
        case .unknownOrder(let id):
            return "Счёт \(id) не найден."
        case .orderClosed(let status):
            return "Счёт уже закрыт (\(status.rawValue))."
        case .amountMismatch(let expected, let received):
            return "Сумма не совпала: ожидалось \(expected), получено \(received) (в копейках)."
        case .malformedCallback(let field):
            return "В уведомлении не хватает поля \(field)."
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nonEmpty: String? { isEmpty ? nil : self }
}
