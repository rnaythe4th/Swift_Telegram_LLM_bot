import Foundation

/// The only way to move a wallet outside a payment or a charge.
///
/// A balance has one owner — the `bot_wallet` row — and one writer: a ledger
/// transaction. A super-admin grant used to skip it. It changed the cache and
/// marked the wallet dirty, so the money reached storage up to two seconds
/// later, through `syncWallets`. Any charge landing in that window opened its
/// own transaction, read a row that did not have the grant in it yet, and then
/// mirrored that pre-grant balance back over the cache (`applyCommittedCharge`
/// writes what the database committed, as it must): the grant was gone and the
/// answer was free. The opposite order lost the charge instead. Two writers,
/// one number — and a window nobody can see.
///
/// So a grant goes through the same transaction a charge does, and the cache
/// mirrors what committed. `SubscriptionWriter` gives subscription dates the
/// same shape, for the same reason.
struct WalletWriter: Sendable {
    let state: ChatContextStore
    let ledger: LedgerPort
    let logger: LoggerPort

    /// Adds to a wallet — or, with a negative amount, takes from it. Never
    /// `purchased`: free credit must not turn anyone into a proven payer (§17).
    func grant(key: UserKey, amount: Money, ref: String) async -> UserBalance? {
        await write(key: key, ref: ref) { transaction, target in
            try await transaction.credit(target, amount, kind: .grant, purchased: false, ref: ref)
        }
    }

    /// Sets a wallet to an exact amount.
    func set(key: UserKey, amount: Money, ref: String) async -> UserBalance? {
        await write(key: key, ref: ref) { transaction, target in
            try await transaction.setBalance(target, to: amount, ref: ref)
        }
    }

    /// Commits the change, then mirrors it. `nil` means the database refused
    /// the write and nothing happened — the caller must say so rather than
    /// quote a balance that only exists in this process.
    private func write(
        key: UserKey,
        ref: String,
        _ body: @Sendable @escaping (any LedgerTransaction, UserKey) async throws -> UserBalance
    ) async -> UserBalance? {
        let target = await state.resolved(key)
        do {
            let wallet = try await ledger.inTransaction { try await body($0, target) }
            await state.applyCommittedWallet(key: target, wallet: wallet)
            return wallet
        } catch {
            logger.error("wallet change for \(target) (\(ref)) was not written: \(error)")
            return nil
        }
    }
}
