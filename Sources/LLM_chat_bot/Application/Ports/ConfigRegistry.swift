import Foundation

/// Identity of one `bot_config` row, without the type of what it holds.
///
/// Dirty-tracking and the write batch key on this: they care *which* row
/// changed, not what is in it. It stays an enum so the store's export switch
/// is exhaustive — a new row cannot be added without the compiler asking what
/// its current value is.
enum ConfigName: String, CaseIterable, Sendable {
    case starsPrice = "stars_price"
    case starsPerUsd = "stars_per_usd"
    case freeModels = "free_models"
    case crypto = "crypto"
    case card = "card"
    case superAdmins = "super_admins"
    case pollingOffset = "polling_offset"
    case ads = "ads"
    case markup = "markup"
    case funnel = "funnel"
    case dailyPremiumLimit = "daily_premium_limit"
    case selfPromo = "self_promo"
    case modes = "modes"
    case reminders = "reminders"
    case onboarding = "onboarding"
    case referrals = "referrals"
    /// Program-wide referral counters (payout total, refusal reasons). The
    /// records and per-inviter tallies behind them are tables.
    case referralTotals = "referral_totals"
    /// Campaign-level `src_` aggregates; the per-person attributions are a table.
    case trafficTotals = "traffic_totals"
    /// Hosted checkout: merchant credentials and prices. The open orders are a
    /// table — an order is a payment in flight, not a setting.
    case externalPayments = "external_payments"
    /// Spending ceilings (§4.1): the only thing standing between a subscriber
    /// with a heavy group and an unbounded provider bill.
    case spendPolicy = "spend_policy"
}

/// One `bot_config` row, declared once: which row it is, what type its document
/// decodes to, and what it means when the row is absent.
///
/// This replaces eight edits per setting (two enum cases, three switches, a
/// field on a struct of optionals, a line in `hasAnyValue`, a line in the
/// loader) — of which two were silent. The expensive one was the loader: a
/// config that is written but never read back silently resets to its default on
/// every restart, and no test could see it.
struct ConfigKey<Value: Codable & Sendable>: Sendable {
    let name: ConfigName
    let defaultValue: Value

    init(_ name: ConfigName, default defaultValue: Value) {
        self.name = name
        self.defaultValue = defaultValue
    }
}

/// What the loader needs from a key without knowing its `Value`: the row it
/// reads and how to turn that row's JSON into something the typed subscript can
/// hand back. Only `ConfigKey` conforms.
protocol AnyConfigKey: Sendable {
    var name: ConfigName { get }
    func decodeDocument(_ json: Data, using decoder: JSONDecoder) throws -> any Sendable
}

extension ConfigKey: AnyConfigKey {
    func decodeDocument(_ json: Data, using decoder: JSONDecoder) throws -> any Sendable {
        try decoder.decode(ConfigDocument<Value>.self, from: json).value
    }
}

/// `bot_config.data` is always a JSON object, whatever the payload type — a
/// bare `7` is legal `jsonb` but makes the column impossible to read uniformly.
struct ConfigDocument<Value: Codable & Sendable>: Codable, Sendable {
    let value: Value
}

/// Every `bot_config` row the bot knows about.
///
/// `all` is derived by reflection rather than hand-listed on purpose: a
/// hand-maintained list is exactly where "declared but never loaded" used to
/// hide, and that omission is invisible until a setting quietly reverts in
/// production. Declaring a key here is enough to make it load.
struct ConfigRegistry: Sendable {
    let starsPrice = ConfigKey(.starsPrice, default: 0)
    let starsPerUsd = ConfigKey(.starsPerUsd, default: 77)
    let freeModels = ConfigKey(.freeModels, default: [String]())
    let crypto = ConfigKey(.crypto, default: CryptoConfigSnapshot.empty)
    let card = ConfigKey(.card, default: CardPaymentConfig.empty)
    let superAdmins = ConfigKey(.superAdmins, default: [UserKey]())
    let pollingOffset = ConfigKey(.pollingOffset, default: 0)
    let ads = ConfigKey(.ads, default: [AdCampaign]())
    let markup = ConfigKey(.markup, default: 30)
    let funnel = ConfigKey(.funnel, default: [String: Int]())
    let dailyPremiumLimit = ConfigKey(.dailyPremiumLimit, default: 5)
    let selfPromo = ConfigKey(.selfPromo, default: SelfPromoConfig.default)
    let modes = ConfigKey(.modes, default: ModePresetConfig.default)
    let reminders = ConfigKey(.reminders, default: SubscriptionReminderConfig.default)
    let onboarding = ConfigKey(.onboarding, default: OnboardingConfig.default)
    let referrals = ConfigKey(.referrals, default: ReferralConfig.default)
    let referralTotals = ConfigKey(.referralTotals, default: ReferralTotals.empty)
    let trafficTotals = ConfigKey(.trafficTotals, default: TrafficSourceTotals.empty)
    let externalPayments = ConfigKey(.externalPayments, default: ExternalPaymentConfig.default)
    let spendPolicy = ConfigKey(.spendPolicy, default: SpendPolicy.default)

    /// Declared ⇒ loaded. Reflection over the stored properties, so a key
    /// cannot exist and be missing from the load path at the same time.
    var all: [any AnyConfigKey] {
        Mirror(reflecting: self).children.compactMap { $0.value as? any AnyConfigKey }
    }
}

/// The one registry instance. A namespace in practice: `Config.markup`.
let Config = ConfigRegistry()

/// One config document ready to be written, tied to the row it belongs to.
///
/// The value is already erased to "something that encodes itself", so the
/// storage adapter never switches over config kinds — the twenty-case encode
/// switch that used to list every key does not exist any more. It can only be
/// built from a `ConfigKey`, so a value can never be filed under a row that
/// reads back as a different type.
struct StoredConfig: Sendable, Encodable {
    let name: ConfigName
    private let write: @Sendable (Encoder) throws -> Void

    init<Value: Codable & Sendable>(_ key: ConfigKey<Value>, _ value: Value) {
        self.name = key.name
        self.write = { encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ConfigDocument(value: value))
        }
    }

    func encode(to encoder: Encoder) throws { try write(encoder) }
}

/// Config rows as they came back from storage, addressed by key.
///
/// Replaces a struct of twenty optional fields and the twenty-line function
/// that filled it. A key that exists can always be read, so "written but never
/// loaded" stops being expressible.
struct ConfigDocuments: Sendable {
    private var values: [ConfigName: any Sendable] = [:]

    init() {}

    /// Decodes whatever rows came back. An unreadable document falls back to
    /// its default and says which one it was: one bad row must not stop the bot
    /// from starting.
    init(rows: [ConfigName: Data], keys: [any AnyConfigKey], decoder: JSONDecoder = JSONDecoder(), onError: (ConfigName, Error) -> Void) {
        for key in keys {
            guard let json = rows[key.name] else { continue }
            do {
                values[key.name] = try key.decodeDocument(json, using: decoder)
            } catch {
                onError(key.name, error)
            }
        }
    }

    /// The stored value, or the key's default when the row is absent or was
    /// unreadable.
    subscript<Value: Codable & Sendable>(key: ConfigKey<Value>) -> Value {
        (values[key.name] as? Value) ?? key.defaultValue
    }

    /// nil when the row was never written — for the handful of settings where
    /// "never configured" and "configured to the default" mean different things
    /// (stars price 0 = not for sale, polling offset = no cursor yet).
    func stored<Value: Codable & Sendable>(_ key: ConfigKey<Value>) -> Value? {
        values[key.name] as? Value
    }

    mutating func set<Value: Codable & Sendable>(_ key: ConfigKey<Value>, _ value: Value) {
        values[key.name] = value
    }
}
