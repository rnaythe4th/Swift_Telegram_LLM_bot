import Foundation

// Hosted checkout ("внешняя касса", §7): merchant configuration and the orders
// waiting for a callback.
//
// The merchant configuration is a document (`bot_config`); each order is a row
// of its own (`bot_external_order`), because an order is a payment in flight,
// there is one per purchase, and the vendor's payment id on it carries a
// `unique` constraint — the second dedup ring behind `bot_payment`.
//
// Orders are stored rather than kept in memory because the vendor answers
// minutes later, into whichever process instance is alive by then: an order
// lost to a redeploy is money received with nothing delivered, and unlike
// Telegram the vendor will not replay it forever.

extension ChatContextStore {
    // MARK: - Configuration

    func externalPaymentConfig() -> ExternalPaymentConfig { _externalPaymentConfig }

    /// Single write path, so normalisation (trimming, dedup, caps) cannot be
    /// skipped by one caller and the dirty flag cannot be forgotten by another.
    func setExternalPaymentConfig(_ config: ExternalPaymentConfig) {
        _externalPaymentConfig = config.normalized
        dirtyConfigs.insert(.externalPayments)
    }

    /// Mutate in place — the menu changes one field at a time.
    func updateExternalPaymentConfig(_ mutate: (inout ExternalPaymentConfig) -> Void) {
        var copy = _externalPaymentConfig
        mutate(&copy)
        setExternalPaymentConfig(copy)
    }

    @discardableResult
    func addExternalPaymentMethod(_ method: ExternalPaymentMethod) -> Bool {
        var config = _externalPaymentConfig
        guard config.methods.count < ExternalPaymentConfig.maxMethods else { return false }
        guard !config.methods.contains(where: { $0.code.lowercased() == method.code.lowercased() }) else { return false }
        config.methods.append(method)
        setExternalPaymentConfig(config)
        return true
    }

    @discardableResult
    func removeExternalPaymentMethod(at index: Int) -> Bool {
        var config = _externalPaymentConfig
        guard index >= 0, index < config.methods.count else { return false }
        config.methods.remove(at: index)
        setExternalPaymentConfig(config)
        return true
    }

    @discardableResult
    func toggleExternalPaymentMethod(at index: Int) -> Bool {
        var config = _externalPaymentConfig
        guard index >= 0, index < config.methods.count else { return false }
        config.methods[index].enabled.toggle()
        setExternalPaymentConfig(config)
        return true
    }

    // MARK: - Orders

    func externalOrder(id: String) -> ExternalPaymentOrder? { _externalOrders[id] }

    func upsertExternalOrder(_ order: ExternalPaymentOrder) {
        _externalOrders[order.id] = order
        markExternalOrderDirty(order.id)
        pruneExternalOrders()
    }

    func markExternalOrderDirty(_ id: String) {
        dirtyExternalOrders.insert(id)
        deletedExternalOrders.remove(id)
    }

    func openExternalOrders(now: Date = Date()) -> [ExternalPaymentOrder] {
        _externalOrders.values
            .filter { $0.isOpen && $0.expiresAt > now }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Every still-valid open order for the same person and the same purchase,
    /// newest first. More than one can exist only when the price moved between
    /// taps (a winback discount that expired), and the caller closes the
    /// leftovers — but the order here is fixed rather than left to the
    /// dictionary, because "which link does the payer hold" must not depend on
    /// hash order.
    func openExternalOrders(
        payerKey: UserKey,
        purpose: PurchasePurpose,
        methodCode: String?,
        now: Date = Date()
    ) -> [ExternalPaymentOrder] {
        let key = resolved(payerKey)
        return _externalOrders.values
            .filter {
                $0.isOpen
                    && $0.expiresAt > now
                    && $0.payerKey == key
                    && $0.purpose == purpose
                    && $0.methodCode == methodCode
                    && $0.currency == _externalPaymentConfig.currency
                    && $0.vendor == _externalPaymentConfig.vendor
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// The open order for this purchase the payer most likely has on screen.
    /// Tapping "оплатить" twice must reuse the link rather than open a second
    /// order: the vendor's page is already sitting there, and two live orders
    /// mean two possible payments for one purchase.
    func openExternalOrder(
        payerKey: UserKey,
        purpose: PurchasePurpose,
        methodCode: String?,
        now: Date = Date()
    ) -> ExternalPaymentOrder? {
        openExternalOrders(payerKey: payerKey, purpose: purpose, methodCode: methodCode, now: now).first
    }

    /// Applies a vendor notification to an order.
    ///
    /// Only the *same* vendor payment landing twice is a duplicate. An order we
    /// had already closed — expired because the bank app took an hour,
    /// cancelled because the payer tapped «отменить счёт» and then paid the page
    /// anyway — is settled all the same: the money is real, the signature and
    /// the amount were checked before we got here, and refusing it would leave
    /// the payer charged with nothing to show. Paying twice is prevented one
    /// layer down, by the idempotency key in `bot_payment`.
    ///
    /// nil means the order is gone entirely, which no retry can fix.
    func settleExternalOrder(
        id: String,
        vendorPaymentID: String,
        now: Date = Date()
    ) -> ExternalOrderSettlement? {
        guard var order = _externalOrders[id] else { return nil }
        if order.status == .paid, order.vendorPaymentID == vendorPaymentID {
            return .duplicate(order)
        }
        let closedAs: ExternalPaymentOrderStatus? = order.isOpen ? nil : order.status
        order.status = .paid
        order.paidAt = now
        order.vendorPaymentID = vendorPaymentID
        _externalOrders[id] = order
        markExternalOrderDirty(id)
        return .settled(order, closedAs: closedAs)
    }

    /// Puts an order back in play after a settlement that could not be
    /// committed. Without it the vendor's retry finds an order that is already
    /// `.paid`, treats the notification as a duplicate and credits nothing —
    /// money received, nothing delivered, and no third chance.
    @discardableResult
    func reopenExternalOrder(id: String) -> Bool {
        guard var order = _externalOrders[id], order.status == .paid else { return false }
        order.status = .pending
        order.paidAt = nil
        order.vendorPaymentID = nil
        _externalOrders[id] = order
        markExternalOrderDirty(id)
        return true
    }

    @discardableResult
    func cancelExternalOrder(id: String) -> Bool {
        guard var order = _externalOrders[id], order.isOpen else { return false }
        order.status = .cancelled
        _externalOrders[id] = order
        markExternalOrderDirty(id)
        return true
    }

    /// Closes orders nobody paid. Lazy on purpose: an expired order costs
    /// nothing until someone looks, and a background sweep for it would be a
    /// timer that exists to tidy one JSON row.
    @discardableResult
    func expireDueExternalOrders(now: Date = Date()) -> [ExternalPaymentOrder] {
        var expired: [ExternalPaymentOrder] = []
        for (id, order) in _externalOrders where order.isOpen && now >= order.expiresAt {
            var copy = order
            copy.status = .expired
            _externalOrders[id] = copy
            expired.append(copy)
            markExternalOrderDirty(id)
        }
        return expired
    }

    /// Keeps the table small: settled orders are history, and the only reason
    /// to hold any of them is a late duplicate notification (already covered by
    /// `bot_payment`). Open orders are never pruned.
    private func pruneExternalOrders() {
        guard _externalOrders.count > Self.maxStoredExternalOrders else { return }
        let settled = _externalOrders.values
            .filter { !$0.isOpen }
            .sorted { $0.createdAt > $1.createdAt }
        let keep = Set(settled.prefix(Self.maxStoredExternalOrders / 2).map(\.id))
        for (id, order) in _externalOrders where !order.isOpen && !keep.contains(id) {
            _externalOrders.removeValue(forKey: id)
            dirtyExternalOrders.remove(id)
            deletedExternalOrders.insert(id)
        }
    }

    static let maxStoredExternalOrders = 200

    // MARK: - Persistence

    func restoreExternalPayments(config: ExternalPaymentConfig?, orders: [ExternalPaymentOrder]) {
        _externalPaymentConfig = (config ?? .default).normalized
        _externalOrders = [:]
        for order in orders {
            _externalOrders[order.id] = order
        }
    }
}
