import Foundation

// Payment configuration: Stars price and rate, card acquiring, crypto
// addresses, invoices and explorer cursors.

extension ChatContextStore {
    // MARK: - Stars price

    func starsPrice() -> Int? { _starsPrice }

    func setStarsPrice(_ price: Int?) {
        _starsPrice = price.flatMap { $0 > 0 ? $0 : nil }
        dirtyConfigs.insert(.starsPrice)
    }

    // MARK: - Stars-per-USD rate (credit packs)

    func starsPerUsd() -> Int { _starsPerUsd }

    func setStarsPerUsd(_ rate: Int) {
        _starsPerUsd = max(0, rate)
        dirtyConfigs.insert(.starsPerUsd)
    }

    /// Whether credit packs may be sold for Stars. Deliberately independent of
    /// `starsPrice` (the *subscription* price): turning subscriptions off must
    /// not silently kill the cheapest entry point (roadmap step 2). 0 = off.
    func starsCreditsEnabled() -> Bool { _starsPerUsd > 0 }

    /// Stars to charge for a credit pack worth `cents` USD.
    func starsForCents(_ cents: Int) -> Int {
        max(1, Int((Double(cents) / 100.0 * Double(_starsPerUsd)).rounded()))
    }

    // MARK: - Card payment config

    func cardConfig() -> CardPaymentConfig { _cardConfig }

    func setCardProviderToken(_ token: String?) {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        _cardConfig.providerToken = trimmed.isEmpty ? nil : SealedSecret(trimmed)
        dirtyConfigs.insert(.card)
    }

    func setCardCurrency(_ currency: FiatCurrency) {
        _cardConfig.currency = currency
        dirtyConfigs.insert(.card)
    }

    func setCardPriceMinorUnits(_ value: Int?) {
        _cardConfig.priceMinorUnits = value.flatMap { $0 > 0 ? $0 : nil }
        dirtyConfigs.insert(.card)
    }

    /// FX rate used to price credit packs on the card (roadmap step 2).
    func setCardUsdRateMinorUnits(_ value: Int?) {
        _cardConfig.usdRateMinorUnits = value.flatMap { $0 > 0 ? $0 : nil }
        dirtyConfigs.insert(.card)
    }

    // MARK: - Crypto config

    func cryptoPriceUsdCents() -> Int? { _cryptoPriceUsdCents }

    func setCryptoPriceUsdCents(_ value: Int?) {
        _cryptoPriceUsdCents = value.flatMap { $0 > 0 ? $0 : nil }
        dirtyConfigs.insert(.crypto)
    }

    func cryptoAddress(_ chain: CryptoChain) -> String? {
        _cryptoAddresses[chain]
    }

    func cryptoAddresses() -> [CryptoChain: String] { _cryptoAddresses }

    func setCryptoAddress(_ chain: CryptoChain, address: String?) {
        let trimmed = address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            _cryptoAddresses.removeValue(forKey: chain)
        } else {
            _cryptoAddresses[chain] = trimmed
        }
        dirtyConfigs.insert(.crypto)
    }

    func nextCryptoSlot(asset: CryptoAsset) -> Int {
        let max = asset.maxConcurrentSlots
        let current = (_cryptoSlotCounters[asset] ?? Int.random(in: 0..<max))
        let next = (current + 1) % max
        _cryptoSlotCounters[asset] = next
        dirtyConfigs.insert(.crypto)
        return next
    }

    func upsertCryptoInvoice(_ invoice: CryptoInvoice) {
        _cryptoInvoices[invoice.id] = invoice
        markCryptoInvoiceDirty(invoice.id)
        pruneCryptoInvoices(keeping: invoice.id)
    }

    /// A settled invoice is history. Keeping every one of them ever opened is
    /// not free: each is a `bot_crypto_invoice` row read back in full at every
    /// restore, and every poll of the blockchain monitor scans the whole
    /// collection (`openInvoiceMatching`, `usedSlots`, `allocatedPoolAddresses`)
    /// — so the cost of an abandoned purchase is paid every 30 seconds, for
    /// ever. Same bound and same reasoning as `pruneExternalOrders`.
    ///
    /// Open and partial invoices are never dropped: those are payments in
    /// flight, and the chain has no delivery retry to fall back on. `keeping`
    /// is the invoice this write is about — settling an old one must not delete
    /// it out from under the caller that is still holding it.
    private func pruneCryptoInvoices(keeping id: String) {
        guard _cryptoInvoices.count > Self.maxStoredCryptoInvoices else { return }
        let settled = _cryptoInvoices.values
            .filter { $0.isSettled && $0.id != id }
            .sorted { $0.createdAt > $1.createdAt }
        let keep = Set(settled.prefix(Self.maxStoredCryptoInvoices / 2).map(\.id))
        for (invoiceID, invoice) in _cryptoInvoices
        where invoice.isSettled && invoiceID != id && !keep.contains(invoiceID) {
            _cryptoInvoices.removeValue(forKey: invoiceID)
            dirtyCryptoInvoices.remove(invoiceID)
            deletedCryptoInvoices.insert(invoiceID)
        }
    }

    static let maxStoredCryptoInvoices = 200

    /// An invoice is a row of its own, not part of the crypto settings
    /// document: it is a payment in flight, and there is one per purchase.
    func markCryptoInvoiceDirty(_ id: String) {
        dirtyCryptoInvoices.insert(id)
        deletedCryptoInvoices.remove(id)
    }

    func cryptoInvoice(id: String) -> CryptoInvoice? {
        _cryptoInvoices[id]
    }

    func openCryptoInvoices() -> [CryptoInvoice] {
        _cryptoInvoices.values.filter(\.isAwaitingFunds)
    }

    func openCryptoInvoices(asset: CryptoAsset) -> [CryptoInvoice] {
        _cryptoInvoices.values.filter { $0.isAwaitingFunds && $0.asset == asset }
    }

    func openCryptoInvoiceForUser(key: UserKey, asset: CryptoAsset, purpose: CryptoInvoicePurpose) -> CryptoInvoice? {
        let u = resolved(key)
        return _cryptoInvoices.values.first { invoice in
            guard invoice.ownerKey == u, invoice.asset == asset else { return false }
            guard invoice.resolvedPurpose == purpose else { return false }
            return invoice.isAwaitingFunds
        }
    }

    func cancelCryptoInvoice(id: String) {
        guard var inv = _cryptoInvoices[id] else { return }
        if inv.isAwaitingFunds {
            inv.status = .cancelled
            _cryptoInvoices[id] = inv
            markCryptoInvoiceDirty(id)
        }
    }

    func expireDueCryptoInvoices(now: Date = Date()) -> [CryptoInvoice] {
        var expired: [CryptoInvoice] = []
        for (id, inv) in _cryptoInvoices {
            guard inv.isAwaitingFunds else { continue }
            if now >= inv.expiresAt {
                var copy = inv
                copy.status = .expired
                _cryptoInvoices[id] = copy
                expired.append(copy)
                markCryptoInvoiceDirty(id)
            }
        }
        return expired
    }

    func usedSlots(asset: CryptoAsset) -> Set<Int> {
        Set(
            _cryptoInvoices.values
                .filter { $0.isAwaitingFunds && $0.asset == asset }
                .map(\.slotOffset)
        )
    }

    // MARK: - Explorer cursors

    static func explorerCursorKey(asset: CryptoAsset, address: String) -> String {
        "\(asset.rawValue):\(address.lowercased())"
    }

    /// Where the blockchain scan stopped last time, per asset+address. Survives
    /// restarts on purpose: seeded at "now", every transfer that arrived during
    /// a redeploy would fall outside every future scan — the money lands, the
    /// invoice expires, and nothing in the logs says why.
    func explorerCursors() -> [String: Int] { _explorerCursors }

    /// Only ever moves forward — an out-of-order or stale write must not reopen
    /// an already scanned range (harmless but wasteful) or, worse, rewind past
    /// transfers that were already credited.
    func advanceExplorerCursor(asset: CryptoAsset, address: String, unix: Int) {
        let key = Self.explorerCursorKey(asset: asset, address: address)
        guard unix > (_explorerCursors[key] ?? 0) else { return }
        _explorerCursors[key] = unix
        dirtyConfigs.insert(.crypto)
    }

    /// Drops cursors for addresses that are no longer polled (address changed,
    /// pool entry removed), so the row does not accumulate dead keys forever.
    func pruneExplorerCursors(keeping keys: Set<String>) {
        guard _explorerCursors.contains(where: { !keys.contains($0.key) }) else { return }
        _explorerCursors = _explorerCursors.filter { keys.contains($0.key) }
        dirtyConfigs.insert(.crypto)
    }

    func cryptoMatchMode() -> CryptoMatchMode { _cryptoMatchMode }

    func setCryptoMatchMode(_ mode: CryptoMatchMode) {
        _cryptoMatchMode = mode
        dirtyConfigs.insert(.crypto)
    }

    func cryptoAddressPool(_ chain: CryptoChain) -> [String] {
        _cryptoAddressPools[chain] ?? []
    }

    func cryptoAddressPools() -> [CryptoChain: [String]] { _cryptoAddressPools }

    @discardableResult
    func addCryptoPoolAddress(_ chain: CryptoChain, address: String) -> Bool {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var pool = _cryptoAddressPools[chain] ?? []
        guard !pool.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return false }
        pool.append(trimmed)
        _cryptoAddressPools[chain] = pool
        dirtyConfigs.insert(.crypto)
        return true
    }

    @discardableResult
    func removeCryptoPoolAddress(_ chain: CryptoChain, at index: Int) -> Bool {
        guard var pool = _cryptoAddressPools[chain], index >= 0, index < pool.count else { return false }
        pool.remove(at: index)
        if pool.isEmpty {
            _cryptoAddressPools.removeValue(forKey: chain)
        } else {
            _cryptoAddressPools[chain] = pool
        }
        dirtyConfigs.insert(.crypto)
        return true
    }

    /// All addresses worth polling for a chain — primary delta address plus pool.
    func pollableCryptoAddresses(_ chain: CryptoChain) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        if let primary = _cryptoAddresses[chain] {
            let key = primary.lowercased()
            if !seen.contains(key) { seen.insert(key); result.append(primary) }
        }
        for addr in _cryptoAddressPools[chain] ?? [] {
            let key = addr.lowercased()
            if !seen.contains(key) { seen.insert(key); result.append(addr) }
        }
        return result
    }

    /// Addresses already allocated to open/partial invoices for given asset.
    func allocatedPoolAddresses(asset: CryptoAsset) -> Set<String> {
        Set(
            _cryptoInvoices.values
                .filter { $0.isAwaitingFunds && $0.asset == asset }
                .map { $0.receivingAddress.lowercased() }
        )
    }

    /// Find first pool address for the chain that's not currently held by an open invoice
    /// of any asset on that chain.
    func nextFreePoolAddress(chain: CryptoChain) -> String? {
        let pool = _cryptoAddressPools[chain] ?? []
        guard !pool.isEmpty else { return nil }
        let allocated = Set(
            _cryptoInvoices.values
                .filter { $0.isAwaitingFunds && $0.asset.chain == chain }
                .map { $0.receivingAddress.lowercased() }
        )
        return pool.first { !allocated.contains($0.lowercased()) }
    }

    func openInvoiceMatching(asset: CryptoAsset, address: String) -> CryptoInvoice? {
        let target = address.lowercased()
        return _cryptoInvoices.values.first {
            $0.isAwaitingFunds
                && $0.asset == asset
                && $0.receivingAddress.lowercased() == target
        }
    }

    func cryptoConfigSnapshot() -> CryptoConfigSnapshot {
        var addrs: [String: String] = [:]
        for (chain, value) in _cryptoAddresses { addrs[chain.rawValue] = value }
        var counters: [String: Int] = [:]
        for (asset, value) in _cryptoSlotCounters { counters[asset.rawValue] = value }
        var pools: [String: [String]] = [:]
        for (chain, list) in _cryptoAddressPools { pools[chain.rawValue] = list }
        return CryptoConfigSnapshot(
            priceUsdCents: _cryptoPriceUsdCents,
            addresses: addrs,
            slotCounters: counters,
            // Invoices are rows now (`bot_crypto_invoice`); the settings
            // document keeps only what configures the rails.
            invoices: [],
            matchMode: _cryptoMatchMode.rawValue,
            addressPools: pools.isEmpty ? nil : pools,
            explorerCursors: _explorerCursors.isEmpty ? nil : _explorerCursors
        )
    }

    func restoreCryptoInvoices(_ invoices: [CryptoInvoice]) {
        _cryptoInvoices = [:]
        for invoice in invoices {
            _cryptoInvoices[invoice.id] = invoice
        }
    }

    func restoreCryptoConfig(_ snapshot: CryptoConfigSnapshot?) {
        _cryptoPriceUsdCents = snapshot?.priceUsdCents
        _cryptoAddresses = [:]
        for (key, value) in snapshot?.addresses ?? [:] {
            if let chain = CryptoChain(rawValue: key) {
                _cryptoAddresses[chain] = value
            }
        }
        _cryptoSlotCounters = [:]
        for (key, value) in snapshot?.slotCounters ?? [:] {
            if let asset = CryptoAsset(rawValue: key) {
                _cryptoSlotCounters[asset] = value
            }
        }
        _cryptoMatchMode = (snapshot?.matchMode).flatMap { CryptoMatchMode(rawValue: $0) } ?? .amountDelta
        _cryptoAddressPools = [:]
        for (key, list) in snapshot?.addressPools ?? [:] {
            if let chain = CryptoChain(rawValue: key) {
                _cryptoAddressPools[chain] = list
            }
        }
        _explorerCursors = snapshot?.explorerCursors ?? [:]
    }
}
