import Foundation

/// An amount of USD, held as a whole number of nanodollars (1e-9).
///
/// Money is integral here for one reason: decisions about access are taken on
/// the boundary (`> .zero`, `<= dust`), and binary floating point does not have
/// a boundary. A thousand deductions of `0.0000173` leave a `Double` balance at
/// `-2.7e-17` — negative for one comparison, zero for the next — and the same
/// deductions summed in a different order give a different total, which makes
/// "spent" and "charged" impossible to reconcile against the ledger.
///
/// Nanodollars rather than cents or microdollars because a cheap model answers
/// for ~1e-8 USD: anything coarser rounds a real charge to nothing. `Int64`
/// holds ±9.2e9 USD, and maps onto a Postgres `bigint` one for one.
struct Money: Hashable, Sendable, Comparable, AdditiveArithmetic, Codable, CustomStringConvertible {
    /// Nanodollars. Private so the only ways in are the named factories — an
    /// `Int` that happens to be lying around cannot become an amount of money.
    private let nanos: Int64

    private init(nanos: Int64) { self.nanos = nanos }

    // MARK: - Construction

    static let zero = Money(nanos: 0)

    static let nanosPerUsd: Int64 = 1_000_000_000
    static let nanosPerCent: Int64 = 10_000_000

    /// Straight from storage: a `bigint` column, an existing ledger entry.
    static func nanos(_ value: Int64) -> Money { Money(nanos: value) }

    static func cents(_ value: Int) -> Money {
        Money(nanos: Int64(value).multipliedClamping(by: nanosPerCent))
    }

    /// The one bridge from `Double`, and it exists because provider usage
    /// arrives that way. Everything downstream of this call is integral.
    /// Non-finite input (a provider sending `NaN`) is worth zero, not a crash.
    static func usd(_ value: Double) -> Money {
        guard value.isFinite else { return .zero }
        let scaled = (value * Double(nanosPerUsd)).rounded()
        // The upper bound is strict on purpose: `Double(Int64.max)` rounds *up*
        // to 2^63, which no `Int64` holds, so `<=` would admit exactly the one
        // value `Int64.init` traps on — and trapping is what this guard exists
        // to prevent. The strict form loses nothing: the largest `Double` below
        // 2^63 is 2^63 − 1024, comfortably inside the range. `Int64.min` is
        // exactly representable, so its bound stays inclusive.
        guard scaled >= Double(Int64.min), scaled < Double(Int64.max) else {
            return Money(nanos: scaled < 0 ? .min : .max)
        }
        return Money(nanos: Int64(scaled))
    }

    // MARK: - Reading

    var nanoValue: Int64 { nanos }

    /// For rendering and for the few APIs that still speak `Double` (Telegram
    /// invoice amounts, provider request bodies). Never for arithmetic.
    var usdValue: Double { Double(nanos) / Double(Self.nanosPerUsd) }

    /// Whole cents, rounded **down**: used where a fractional cent cannot be
    /// charged, and the fraction is the customer's.
    var wholeCents: Int { Int(nanos / Self.nanosPerCent) }

    var isPositive: Bool { nanos > 0 }
    var isZero: Bool { nanos == 0 }

    // MARK: - Arithmetic

    static func + (lhs: Money, rhs: Money) -> Money {
        Money(nanos: lhs.nanos.addingClamping(rhs.nanos))
    }

    static func - (lhs: Money, rhs: Money) -> Money {
        Money(nanos: lhs.nanos.subtractingClamping(rhs.nanos))
    }

    static prefix func - (value: Money) -> Money {
        Money(nanos: value.nanos == .min ? .max : -value.nanos)
    }

    static func < (lhs: Money, rhs: Money) -> Bool { lhs.nanos < rhs.nanos }

    /// Markup, and the only multiplication money admits: by a plain percentage.
    /// `AdditiveArithmetic` deliberately gives no `*`, so dollars times dollars
    /// does not compile.
    ///
    /// Rounds towards zero, i.e. in the customer's favour — a systematic round
    /// up over a million turns is itself a sum of money.
    func multiplied(byPercent percent: Int) -> Money {
        let factor = Int64(100 + percent)
        let (scaled, overflow) = nanos.multipliedReportingOverflow(by: factor)
        guard overflow else { return Money(nanos: scaled / 100) }
        // Saturating on the *product* would divide the ceiling by a hundred and
        // hand back a hundredth of what was asked for. Splitting the amount
        // first keeps the answer exact for anything short of the ceiling, and
        // saturates at the ceiling itself.
        let whole = (nanos / 100).multipliedClamping(by: factor)
        let remainder = (nanos % 100).multipliedClamping(by: factor) / 100
        return Money(nanos: whole.addingClamping(remainder))
    }

    /// Never below zero. The wallet's floor is a database constraint too
    /// (`check (balance_nanos >= 0)`); this is the same rule in Swift, for the
    /// projections shown before the charge happens.
    var clampedToZero: Money { nanos < 0 ? .zero : self }

    static func min(_ a: Money, _ b: Money) -> Money { a < b ? a : b }
    static func max(_ a: Money, _ b: Money) -> Money { a < b ? b : a }

    // MARK: - Rendering

    /// `$0.0123`. Four digits by default: a single cheap answer costs less than
    /// a cent, and "$0.00" reads as free.
    func formatted(fractionDigits: Int = 4) -> String {
        String(format: "$%.\(fractionDigits)f", usdValue)
    }

    /// Without the sign, for places that print their own ("+$1.00").
    func formattedAmount(fractionDigits: Int = 2) -> String {
        String(format: "%.\(fractionDigits)f", Swift.abs(usdValue))
    }

    var description: String { formatted() }

    // MARK: - Codable

    /// A bare integer of nanodollars, so a document that carries an amount
    /// (a spend policy, a referral reward) is exact in JSON as well.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.nanos = try container.decode(Int64.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(nanos)
    }
}

private extension Int64 {
    /// Saturating arithmetic: money that overflows an `Int64` is a bug
    /// upstream, and a trap in the payment path would take the process down
    /// with the payment half-applied. Saturation keeps the invariant
    /// "balance never goes negative by accident" while staying loud in the
    /// numbers themselves.
    func addingClamping(_ other: Int64) -> Int64 {
        let (result, overflow) = addingReportingOverflow(other)
        guard overflow else { return result }
        return other > 0 ? .max : .min
    }

    func subtractingClamping(_ other: Int64) -> Int64 {
        let (result, overflow) = subtractingReportingOverflow(other)
        guard overflow else { return result }
        return other < 0 ? .max : .min
    }

    func multipliedClamping(by other: Int64) -> Int64 {
        let (result, overflow) = multipliedReportingOverflow(by: other)
        guard overflow else { return result }
        return (self < 0) == (other < 0) ? .max : .min
    }
}
