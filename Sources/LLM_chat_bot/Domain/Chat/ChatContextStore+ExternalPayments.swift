import Foundation

// Hosted checkout ("внешняя касса", §7): merchant configuration and the orders
// waiting for a callback.
//
// Everything here is one `bot_config` row. Orders live in it rather than in
// memory because the vendor answers minutes later, into whichever process
// instance is alive by then — an order lost to a redeploy is money received
// with nothing delivered, and unlike Telegram the vendor will not replay it
// forever.

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
        pruneExternalOrders()
        dirtyConfigs.insert(.externalPayments)
    }

    func openExternalOrders(now: Date = Date()) -> [ExternalPaymentOrder] {
        _externalOrders.values
            .filter { $0.isOpen && $0.expiresAt > now }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// An open order for the same person and the same thing, still valid.
    /// Tapping "оплатить" twice must reuse the link rather than open a second
    /// order: the vendor's page is already sitting on the payer's screen, and
    /// two live orders mean two possible payments for one purchase.
    func openExternalOrder(
        payerKey: String,
        purpose: PurchasePurpose,
        methodCode: String?,
        now: Date = Date()
    ) -> ExternalPaymentOrder? {
        let key = userKeyOrRaw(payerKey)
        return _externalOrders.values.first {
            $0.isOpen
                && $0.expiresAt > now
                && $0.payerKey == key
                && $0.purpose == purpose
                && $0.methodCode == methodCode
                && $0.currency == _externalPaymentConfig.currency
                && $0.vendor == _externalPaymentConfig.vendor
        }
    }

    /// Marks an order paid. Returns nil when the order is gone or no longer
    /// open, so the caller can treat "already settled" as a duplicate
    /// notification instead of paying twice.
    func markExternalOrderPaid(id: String, vendorPaymentID: String, now: Date = Date()) -> ExternalPaymentOrder? {
        guard var order = _externalOrders[id], order.isOpen else { return nil }
        order.status = .paid
        order.paidAt = now
        order.vendorPaymentID = vendorPaymentID
        _externalOrders[id] = order
        dirtyConfigs.insert(.externalPayments)
        return order
    }

    @discardableResult
    func cancelExternalOrder(id: String) -> Bool {
        guard var order = _externalOrders[id], order.isOpen else { return false }
        order.status = .cancelled
        _externalOrders[id] = order
        dirtyConfigs.insert(.externalPayments)
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
        }
        if !expired.isEmpty { dirtyConfigs.insert(.externalPayments) }
        return expired
    }

    /// Keeps the row small: settled orders are history, and the only reason to
    /// hold any of them is a late duplicate notification (already covered by
    /// `processedPaymentChargeIDs`). Open orders are never pruned.
    private func pruneExternalOrders() {
        guard _externalOrders.count > Self.maxStoredExternalOrders else { return }
        let settled = _externalOrders.values
            .filter { !$0.isOpen }
            .sorted { $0.createdAt > $1.createdAt }
        let keep = Set(settled.prefix(Self.maxStoredExternalOrders / 2).map(\.id))
        _externalOrders = _externalOrders.filter { $0.value.isOpen || keep.contains($0.key) }
    }

    static let maxStoredExternalOrders = 200

    // MARK: - Persistence

    func externalPaymentSnapshot() -> ExternalPaymentSnapshot {
        ExternalPaymentSnapshot(
            config: _externalPaymentConfig,
            orders: Array(_externalOrders.values)
        )
    }

    func restoreExternalPayments(_ snapshot: ExternalPaymentSnapshot?) {
        _externalPaymentConfig = (snapshot?.config ?? .default).normalized
        _externalOrders = [:]
        for order in snapshot?.orders ?? [] {
            _externalOrders[order.id] = order
        }
    }
}
