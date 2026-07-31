import Foundation

// Port for a hosted-checkout vendor. Two operations, both pure: sign a link,
// verify a notification. No network call belongs here — the vendor's whole
// protocol is "the payer walks to your URL, the vendor walks back to ours",
// which is also why the adapters are trivially testable.

/// A notification whose signature has already been checked. Constructing one
/// means the vendor really sent it: the service layer never sees an unverified
/// callback, so it cannot forget to check.
struct ExternalCheckoutCallback: Sendable, Equatable {
    /// Our order id, as handed to the vendor when the link was signed.
    let orderID: String
    /// The vendor's payment id — what the payment is deduplicated by, because
    /// aggregators retry a notification until they get their acknowledgement.
    let vendorPaymentID: String
    let amountMinorUnits: Int
    /// Which rail the person actually used, when the vendor says so. Reported
    /// back to the payer and logged; never used to decide anything.
    let methodCode: String?
}

protocol ExternalCheckoutPort: Sendable {
    var vendor: ExternalPaymentVendor { get }

    /// Signed URL the payer opens. Throws only for a malformed order (an amount
    /// the vendor cannot express), never for network reasons — there is no call.
    func checkoutURL(
        order: ExternalPaymentOrder,
        credentials: ExternalPaymentCredentials
    ) throws -> String

    /// Verifies and parses a notification. Throws `ExternalPaymentError
    /// .badSignature` for anything that does not authenticate — including a
    /// missing signature, so an empty POST cannot pass as a valid one.
    func verifyCallback(
        parameters: [String: String],
        credentials: ExternalPaymentCredentials
    ) throws -> ExternalCheckoutCallback

    /// Exact body the vendor expects back, or it keeps retrying (FreeKassa
    /// wants `YES`). Part of the port because "did we acknowledge?" is protocol,
    /// not transport.
    var acknowledgement: String { get }
}

/// Resolves a vendor to its adapter. Implemented in Infrastructure with an
/// exhaustive `switch`, so a new `ExternalPaymentVendor` case fails to build
/// until it has an adapter — the registry cannot be silently incomplete, and
/// callers get a non-optional adapter instead of an `if let` that would have to
/// invent an error message.
protocol ExternalCheckoutResolver: Sendable {
    func adapter(for vendor: ExternalPaymentVendor) -> any ExternalCheckoutPort
}
