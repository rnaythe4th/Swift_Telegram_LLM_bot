import Foundation

/// Vendor → adapter, resolved by an exhaustive `switch`.
///
/// The switch is the point: a new `ExternalPaymentVendor` case stops the build
/// here until it has an adapter, so a vendor can never exist as a settings
/// option with nothing behind it. It also means callers get a real adapter
/// rather than an optional they would have to explain away at runtime.
struct ExternalCheckoutRegistry: ExternalCheckoutResolver {
    private let freeKassa: FreeKassaCheckoutAdapter

    init(freeKassa: FreeKassaCheckoutAdapter = FreeKassaCheckoutAdapter()) {
        self.freeKassa = freeKassa
    }

    func adapter(for vendor: ExternalPaymentVendor) -> any ExternalCheckoutPort {
        switch vendor {
        case .freekassa: return freeKassa
        }
    }
}
