import Foundation

/// Why money moved. Written on every ledger line, so a balance can always be
/// explained — "почему у меня было $2, а стало $1.30" has an answer.
enum LedgerEntryKind: String, Sendable, CaseIterable {
    /// A credit pack the person paid real money for.
    case topup
    /// Cost of one answer.
    case charge
    /// Referral reward or conversion bonus.
    case referral
    /// Super-admin grant, promo credit — free money.
    case grant
    /// Manual correction (`/balance set`).
    case correction

    var displayName: String {
        switch self {
        case .topup: return "пополнение"
        case .charge: return "ответ"
        case .referral: return "бонус за приглашение"
        case .grant: return "начисление"
        case .correction: return "корректировка"
        }
    }
}

/// One line of the money journal.
struct LedgerEntry: Sendable {
    let userKey: UserKey
    let kind: LedgerEntryKind
    /// Signed: positive credits, negative debits.
    let amount: Money
    let balanceAfter: Money
    /// Charge id, tx hash, order id, generation id — whatever the movement can
    /// be traced back to.
    let ref: String?
    let createdAt: Date
}

/// What a debit actually did.
struct WalletDebit: Sendable, Equatable {
    /// Never more than the wallet held.
    let charged: Money
    let remaining: Money
    let depleted: Bool
}

/// Result of extending a subscription, as the database computed it.
struct SubscriptionExtension: Sendable, Equatable {
    let paidUntil: Date?
    /// True when this payment created the tenant rather than renewing one.
    let isNew: Bool
    /// Unlimited tenants stay unlimited — paying never shortens access.
    let wasUnlimited: Bool
}

/// Everything that moves money, and the only place it can be moved from.
///
/// The point is that there is no method here that writes a balance *outside* a
/// transaction. A payment path therefore cannot "forget" durability the way it
/// could when the rule was a sentence in the documentation ("платежи — всегда
/// `flushNow()`"): by the time `inTransaction` returns, either every line of
/// this payment is committed or none of it is.
protocol LedgerPort: Sendable {
    func inTransaction<T: Sendable>(
        _ body: @Sendable (any LedgerTransaction) async throws -> T
    ) async throws -> T

    /// Wallet rows that changed in the cache outside a transaction — a rename
    /// folding a pending wallet into an identified one, a super-admin deleting
    /// one. Write-behind, because no money entered or left the system.
    func syncWallets(changed: [UserKey: UserBalance], removed: [UserKey]) async throws

    /// The journal behind one wallet, newest first.
    func recentEntries(userKey: UserKey, limit: Int) async throws -> [LedgerEntry]

    /// `sum(bot_ledger.amount) == bot_wallet.balance` for every wallet, or the
    /// keys where it does not hold. Cheap enough to run daily; a mismatch means
    /// something wrote a balance without writing its reason, and the owner
    /// should hear about it from an alert rather than from a customer (§6.1).
    func reconcile() async throws -> [UserKey]
}

/// The operations available inside one transaction. Everything here either all
/// happens or none of it does.
protocol LedgerTransaction: Sendable {
    /// Takes the idempotency key for this payment. `false` means it was already
    /// taken — the payment has been processed and nothing more should happen.
    ///
    /// Implemented as `insert … on conflict do nothing returning`, so the check
    /// and the claim are one statement: there is no window between "not seen
    /// before" and "recorded" for a second delivery to slip into, whether it
    /// arrives on another task or in another process.
    func claimPayment(_ receipt: PaymentReceipt) async throws -> Bool

    /// Takes a one-off key for money that is not a payment — a referral payout,
    /// say. `false` means it was already taken and nothing more should happen.
    ///
    /// Exists because "check a flag, then credit" is two steps: the flag lives
    /// in write-behind state, so a crash in between pays the same bonus twice.
    /// A primary key cannot be half-taken.
    func claim(_ key: String) async throws -> Bool

    /// Credits a wallet and writes the journal line. `purchased` marks real
    /// money (a credit pack), which is what makes a lapsed wallet worth a
    /// comeback offer later — bonuses and grants must pass `false` or free
    /// credit turns anyone into a proven payer (§17).
    @discardableResult
    func credit(
        _ userKey: UserKey,
        _ amount: Money,
        kind: LedgerEntryKind,
        purchased: Bool,
        ref: String?
    ) async throws -> UserBalance

    /// Charges a wallet for one answer, never below zero, in a single statement
    /// — no read-modify-write, so two turns of the same person cannot both
    /// spend the same remaining balance.
    func debit(
        _ userKey: UserKey,
        upTo amount: Money,
        real: Money,
        ref: String?
    ) async throws -> WalletDebit

    /// Sets a wallet to an exact amount — the super-admin correction behind
    /// `/balance set`. Here rather than in the store because a balance has one
    /// owner and one writer: a change that only reached the cache would be
    /// overwritten by the next charge, which reads the row and mirrors it back.
    /// The journal records the delta, so a balance that was *set* is still
    /// explainable.
    @discardableResult
    func setBalance(_ userKey: UserKey, to amount: Money, ref: String?) async throws -> UserBalance

    /// Extends a subscription by `days` from `max(now, paid_until)`, creating
    /// the tenant if this is their first payment. Computed by the database, so
    /// two concurrent renewals cannot both read the same end date.
    func extendSubscription(
        _ userKey: UserKey,
        days: Int,
        defaults: TenantDefaults
    ) async throws -> SubscriptionExtension

    /// Super-admin subscription edits (`/tenant`, the menu): an explicit end
    /// date, `nil` for unlimited.
    func setSubscription(_ userKey: UserKey, paidUntil: Date?) async throws

    /// The one-shot winback discount lives next to the subscription it prices,
    /// so consuming it is part of the same commit as the payment.
    func setWinbackDiscount(_ userKey: UserKey, _ discount: SubscriptionDiscount?) async throws
}

/// What a tenant row needs when a payment creates it. Passed in rather than
/// hard-coded in SQL: the defaults are the owner's settings, not the schema's.
struct TenantDefaults: Sendable {
    let ownerKey: UserKey
    let model: String
    let role: String
    let historyLength: Int
}
