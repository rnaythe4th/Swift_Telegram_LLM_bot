import Foundation

/// What a payment buys. Every payment path — Telegram Stars, card acquiring,
/// on-chain crypto, a third-party hosted checkout — ends in one of these two
/// cases, which is why fulfilment (`PaymentFulfillmentService`) can be one
/// shared routine instead of a copy per method that quietly forgets a step.
///
/// The case names and the `cents` label are part of the persisted JSON of every
/// open crypto invoice and external order: renaming them stops old rows from
/// decoding, so treat them as wire format.
enum PurchasePurpose: Codable, Sendable, Equatable {
    /// The 30-day premium subscription.
    case subscription
    /// Top up the pay-as-you-go balance by `cents` USD (face value credited).
    case credit(cents: Int)
}
