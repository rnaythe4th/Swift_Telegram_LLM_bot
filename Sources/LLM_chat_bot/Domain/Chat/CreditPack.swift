import Foundation

/// Pay-as-you-go credit packs a user can top up their balance with.
///
/// A pack is defined by its **USD face value** (in cents): that exact amount
/// lands on the wallet (`LedgerTransaction.credit(purchased: true)`, which is
/// also what marks the payer as one who paid real money). The provider markup
/// (`priceMultiplier`)
/// is charged later, per answer, at spend time — so margin comes from spending,
/// not from the deposit. The price charged to buy a pack is derived per method:
/// Stars via `starsForCents`, crypto via the pack cents fed to the invoice.
enum CreditPack {
    /// Face values offered on the buy page, in USD cents.
    static let centsOptions: [Int] = [200, 500, 1000]

    /// Human label like `$2` / `$5` / `$10` (whole dollars) or `$2.50`.
    static func label(cents: Int) -> String {
        if cents % 100 == 0 { return "$\(cents / 100)" }
        return String(format: "$%.2f", Double(cents) / 100.0)
    }

    /// True when `cents` is one of the offered packs — guards untrusted payloads.
    static func isValid(cents: Int) -> Bool {
        centsOptions.contains(cents)
    }

    /// What a `cents`-worth pack costs when $1 is priced at `rate`. The unit of
    /// `rate` belongs to the caller — Stars per dollar, kopecks per dollar — and
    /// comes back out unchanged; this only does the arithmetic, once, for every
    /// rail that sells a pack.
    ///
    /// Integer throughout, and `nil` rather than a trap. `rate` is a number a
    /// super-admin types into a text field, and `Int(Double)` **traps** outside
    /// `Int`'s range instead of returning something wrong: one absurd rate took
    /// the process down on every render of the buy page — and the rate is
    /// persisted, so the next process died the same way. A rate that cannot
    /// price a pack means "this rail cannot sell one", which is a sentence the
    /// caller can say out loud.
    static func price(cents: Int, perUsd rate: Int) -> Int? {
        guard cents > 0, rate > 0 else { return nil }
        let (product, overflow) = cents.multipliedReportingOverflow(by: rate)
        guard !overflow else { return nil }
        // Round half up without `(product + 50) / 100`, which would overflow for
        // a product within 50 of `Int.max`.
        let (whole, remainder) = product.quotientAndRemainder(dividingBy: 100)
        return remainder >= 50 ? whole + 1 : whole
    }
}
