import Foundation

actor CryptoPaymentMonitor {
    private let state: ChatContextStore
    private let service: CryptoPaymentService
    private let logger: LoggerPort

    private let tonExplorer: TonExplorer?
    private let bscExplorer: EvmExplorer?
    private let ethExplorer: EvmExplorer?
    private let tronExplorer: TronExplorer?

    private static let pollIntervalNanos: UInt64 = 30 * 1_000_000_000

    /// How far back to scan an address the store has no cursor for. One invoice
    /// lifetime (30 min) plus slack: a first-ever poll may still be catching up
    /// on a transfer sent moments before the address was configured, and a
    /// re-scan costs nothing — every credit is deduplicated by tx hash.
    private static let coldStartLookbackSeconds = 45 * 60

    init(
        state: ChatContextStore,
        service: CryptoPaymentService,
        logger: LoggerPort,
        tonExplorer: TonExplorer?,
        bscExplorer: EvmExplorer?,
        ethExplorer: EvmExplorer?,
        tronExplorer: TronExplorer?
    ) {
        self.state = state
        self.service = service
        self.logger = logger
        self.tonExplorer = tonExplorer
        self.bscExplorer = bscExplorer
        self.ethExplorer = ethExplorer
        self.tronExplorer = tronExplorer
    }

    func run() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: Self.pollIntervalNanos)
            guard !Task.isCancelled else { return }
            await pollOnce()
            await service.sweepExpired()
        }
    }

    private func pollOnce() async {
        // Cursors live in the store, not in this actor: a redeploy must not
        // reset the scan position to "now" and swallow whatever arrived while
        // the process was down.
        let stored = await state.explorerCursors()
        let coldSeed = Int(Date().timeIntervalSince1970) - Self.coldStartLookbackSeconds
        var liveKeys: Set<String> = []
        for asset in CryptoAsset.allCases {
            let addresses = await state.pollableCryptoAddresses(asset.chain)
            for address in addresses {
                let key = ChatContextStore.explorerCursorKey(asset: asset, address: address)
                liveKeys.insert(key)
                let cursor = ExplorerCursor(lastSeenUnix: stored[key] ?? coldSeed)
                do {
                    let (transfers, newCursor) = try await fetchTransfers(asset: asset, address: address, cursor: cursor)
                    for transfer in transfers {
                        let result = await service.applyIncomingTransfer(
                            asset: transfer.asset,
                            amountAtomic: transfer.amountAtomic,
                            fromAddress: transfer.fromAddress,
                            recipientAddress: address,
                            txHash: transfer.txHash,
                            timestamp: transfer.timestamp
                        )
                        switch result {
                        case .fullyPaid:
                            logger.info("crypto monitor: invoice paid via \(asset.rawValue) addr=\(address) tx=\(transfer.txHash)")
                        case .partial(_, _, let remaining):
                            logger.info("crypto monitor: partial \(asset.rawValue) addr=\(address) tx=\(transfer.txHash) remaining=\(remaining)")
                        case .alreadyCredited:
                            break
                        case .unmatched:
                            logger.info("crypto monitor: unmatched \(asset.rawValue) addr=\(address) tx=\(transfer.txHash) amount=\(transfer.amountAtomic)")
                        }
                    }
                    // Only after every transfer of this batch was applied (and
                    // flushed by the payment path): a cursor moved first would
                    // mark the range scanned while a crash in between leaves the
                    // money uncredited and outside all future scans.
                    await state.advanceExplorerCursor(asset: asset, address: address, unix: newCursor.lastSeenUnix)
                } catch {
                    logger.error("crypto monitor: \(asset.rawValue) addr=\(address) fetch failed: \(error)")
                }
            }
        }
        await state.pruneExplorerCursors(keeping: liveKeys)
    }

    private func fetchTransfers(asset: CryptoAsset, address: String, cursor: ExplorerCursor) async throws -> ([IncomingCryptoTransfer], ExplorerCursor) {
        switch asset {
        case .tonNative, .usdtTon:
            guard let explorer = tonExplorer else { return ([], cursor) }
            return try await explorer.fetchIncoming(asset: asset, address: address, since: cursor)
        case .usdtBsc:
            guard let explorer = bscExplorer else { return ([], cursor) }
            return try await explorer.fetchIncoming(asset: asset, address: address, since: cursor)
        case .usdtEth:
            guard let explorer = ethExplorer else { return ([], cursor) }
            return try await explorer.fetchIncoming(asset: asset, address: address, since: cursor)
        case .usdtTrx:
            guard let explorer = tronExplorer else { return ([], cursor) }
            return try await explorer.fetchIncoming(asset: asset, address: address, since: cursor)
        }
    }
}
