import Foundation

/// The only way to change a subscription date or a winback offer outside a
/// payment.
///
/// Both live in `bot_tenant` columns that the write-behind flush deliberately
/// never updates — they belong to the money transaction, so that a stale
/// in-memory copy can never undo a renewal somebody paid for (§10.2). The
/// flip side is that a super-admin extending a subscription, or the sweep
/// granting a winback discount, would change memory and nothing else: correct
/// until the next restart, and then silently gone.
///
/// So every one of those paths goes through here: the store decides and updates
/// its cache, and the same value is written to the column that owns it.
struct SubscriptionWriter: Sendable {
    let state: ChatContextStore
    let ledger: LedgerPort
    let logger: LoggerPort
    let alerter: OwnerAlerter?

    /// Super-admin: extend by N days from max(now, current end).
    @discardableResult
    func extend(username: String, days: Int) async -> Date? {
        guard let until = await state.extendTenantSubscription(username: username, days: days) else {
            return nil
        }
        await persist(username: username, paidUntil: until)
        return until
    }

    /// Super-admin: open-ended access.
    @discardableResult
    func setUnlimited(username: String) async -> Bool {
        guard await state.setTenantUnlimited(username: username) else { return false }
        await persist(username: username, paidUntil: nil)
        return true
    }

    /// Super-admin: end it now.
    @discardableResult
    func expire(username: String) async -> Bool {
        guard await state.expireTenantSubscription(username: username) else { return false }
        let subscription = await state.tenantSubscription(ownerUsername: username)
        await persist(username: username, paidUntil: subscription.paidUntil)
        return true
    }

    /// Attaches a winback offer. The store refuses to re-issue a live one, so a
    /// retried sweep cannot push the deadline forward — this only writes down
    /// whatever it decided.
    func grantWinback(username: String, percent: Int, hours: Int) async -> SubscriptionDiscount? {
        guard let discount = await state.grantWinbackDiscount(
            username: username, percent: percent, hours: hours
        ) else { return nil }
        await persistDiscount(username: username, discount: discount)
        return discount
    }

    /// One-shot: clears the offer and reports it when it was still valid.
    @discardableResult
    func consumeWinback(username: String) async -> SubscriptionDiscount? {
        let consumed = await state.consumeWinbackDiscount(username: username)
        await persistDiscount(username: username, discount: nil)
        return consumed
    }

    /// Super-admin escape hatch after a misconfigured offer went out.
    func clearAllWinback() async -> Int {
        let owners = await state.tenantsWithWinbackDiscount()
        let cleared = await state.clearAllWinbackDiscounts()
        for owner in owners {
            await persistDiscount(username: owner, discount: nil)
        }
        return cleared
    }

    // MARK: - Persisting

    private func persist(username: String, paidUntil: Date?) async {
        let key = await state.storageKey(forUsername: username)
        do {
            try await ledger.inTransaction { try await $0.setSubscription(key, paidUntil: paidUntil) }
        } catch {
            // Memory is now ahead of storage. Loud rather than silent: this is a
            // deliberate change somebody made, and it will be gone after the
            // next restart if nobody notices.
            logger.error("subscription change for \(key) not persisted: \(error)")
            await alerter?.report(.databaseDown, active: true, detail: "подписка \(key) не сохранена")
        }
    }

    private func persistDiscount(username: String, discount: SubscriptionDiscount?) async {
        let key = await state.storageKey(forUsername: username)
        do {
            try await ledger.inTransaction { try await $0.setWinbackDiscount(key, discount) }
        } catch {
            logger.error("winback discount for \(key) not persisted: \(error)")
        }
    }
}
