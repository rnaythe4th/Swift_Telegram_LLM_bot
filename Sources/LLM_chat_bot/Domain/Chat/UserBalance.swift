import Foundation

/// Pay-as-you-go wallet of one user (keyed by lowercased @username).
///
/// The balance lives in the *billed* (marked-up) price world: deposits and
/// deductions are what the user sees. `spentRealUsd` keeps the provider's
/// actual cost alongside, so the super-admin can read the margin directly:
/// margin = spentBilledUsd − spentRealUsd.
struct UserBalance: Codable, Sendable, Equatable {
    var balanceUsd: Double
    var spentBilledUsd: Double
    var spentRealUsd: Double
    var updatedAt: Date?

    static let empty = UserBalance(balanceUsd: 0, spentBilledUsd: 0, spentRealUsd: 0, updatedAt: nil)
}
