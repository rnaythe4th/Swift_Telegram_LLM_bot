import Foundation

/// What the owner is willing to spend at the providers, per day (§4.1).
///
/// The bot caps concurrency (`MAX_CONCURRENT_GENERATIONS`) and the free tier's
/// daily taste of premium — but nothing caps **money**. Anyone with full access
/// (a subscriber, a member of a sponsored group, a positive wallet) generates
/// without limit, and every token is on the owner's bill. A $5 subscription
/// buys a 500-person group on an expensive model, and the first sign of it is
/// the OpenRouter invoice, weeks later.
///
/// Both ceilings default to "no limit", so switching them on is a decision the
/// owner makes rather than a surprise they discover.
struct SpendPolicy: Codable, Sendable, Equatable {
    /// Everything the bot spends at providers in one UTC day. Reached → paid
    /// models are switched off until midnight, the owner is alerted, and users
    /// are told the truth instead of quietly getting worse answers.
    var dailyGlobalCap: Money
    /// Per tenant. A subscription is a fixed price, and a fixed price cannot buy
    /// unbounded consumption.
    var dailyPerTenantCap: Money
    /// What happens when a tenant hits their own ceiling.
    var onTenantCap: CapResponse

    enum CapResponse: String, Codable, Sendable, CaseIterable {
        /// Keep answering, on a free model — the same machinery the daily
        /// premium cap already uses, so the paid model comes back by itself.
        case downgradeToFree
        /// Refuse the turn outright.
        case refuse

        var displayName: String {
            switch self {
            case .downgradeToFree: return "перейти на бесплатную модель"
            case .refuse: return "не отвечать"
            }
        }
    }

    static let unlimited = SpendPolicy(
        dailyGlobalCap: .zero,
        dailyPerTenantCap: .zero,
        onTenantCap: .downgradeToFree
    )

    static let `default` = unlimited

    var hasGlobalCap: Bool { dailyGlobalCap.isPositive }
    var hasTenantCap: Bool { dailyPerTenantCap.isPositive }
    var isEnabled: Bool { hasGlobalCap || hasTenantCap }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case dailyGlobalCap, dailyPerTenantCap, onTenantCap
    }

    init(dailyGlobalCap: Money, dailyPerTenantCap: Money, onTenantCap: CapResponse) {
        self.dailyGlobalCap = dailyGlobalCap
        self.dailyPerTenantCap = dailyPerTenantCap
        self.onTenantCap = onTenantCap
    }

    /// Missing fields read as "no ceiling", and an unknown `onTenantCap` reads
    /// as the gentler of the two: a document written by another build must not
    /// be able to start refusing answers.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            dailyGlobalCap: try c.decodeIfPresent(Money.self, forKey: .dailyGlobalCap) ?? .zero,
            dailyPerTenantCap: try c.decodeIfPresent(Money.self, forKey: .dailyPerTenantCap) ?? .zero,
            onTenantCap: CapResponse(
                rawValue: try c.decodeIfPresent(String.self, forKey: .onTenantCap) ?? ""
            ) ?? .downgradeToFree
        )
    }
}

/// Provider spend inside the current UTC day, per tenant and in total.
///
/// In memory only, and deliberately: it is reconstructed from the first answer
/// after a restart, and a restart that hands back a day's allowance costs the
/// owner at most one day of ceiling — far less than the complexity of making a
/// counter that ticks on every single answer durable. The *money* it guards is
/// recorded in `bot_ledger` either way.
struct DailySpendLedger: Sendable {
    private(set) var day: Int
    private(set) var total: Money
    private(set) var byTenant: [String: Money]

    init(day: Int = FunnelDailyLog.dayNumber(), total: Money = .zero, byTenant: [String: Money] = [:]) {
        self.day = day
        self.total = total
        self.byTenant = byTenant
    }

    /// Adds real provider cost. Rolls over to a fresh day on the first record
    /// after UTC midnight, so no separate timer is needed.
    mutating func record(_ amount: Money, tenant: String, now: Date = Date()) {
        rollOverIfNeeded(now: now)
        guard amount.isPositive else { return }
        total += amount
        byTenant[tenant, default: .zero] += amount
    }

    mutating func rollOverIfNeeded(now: Date = Date()) {
        let today = FunnelDailyLog.dayNumber(now)
        guard today != day else { return }
        day = today
        total = .zero
        byTenant = [:]
    }

    func spent(tenant: String) -> Money { byTenant[tenant] ?? .zero }
}

/// Why a turn was stopped by a spending ceiling — nil means "carry on".
enum SpendCapVerdict: Sendable, Equatable {
    /// The whole bot has spent its daily budget.
    case global(spent: Money, cap: Money)
    /// This tenant has spent theirs.
    case tenant(spent: Money, cap: Money, response: SpendPolicy.CapResponse)
}
