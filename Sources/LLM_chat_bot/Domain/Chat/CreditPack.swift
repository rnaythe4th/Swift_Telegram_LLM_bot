import Foundation

/// Pay-as-you-go credit packs a user can top up their balance with.
///
/// A pack is defined by its **USD face value** (in cents): that exact amount
/// lands on the wallet (`creditBalance`). The provider markup (`priceMultiplier`)
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
}
