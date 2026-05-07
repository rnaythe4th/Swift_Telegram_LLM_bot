import Foundation

actor CryptoPaymentMonitor {
    private let state: ChatContextStore
    private let service: CryptoPaymentService
    private let logger: LoggerPort

    private let tonExplorer: TonExplorer?
    private let bscExplorer: EvmExplorer?
    private let ethExplorer: EvmExplorer?
    private let tronExplorer: TronExplorer?

    private struct CursorKey: Hashable {
        let asset: CryptoAsset
        let address: String
    }
    private var cursors: [CursorKey: ExplorerCursor] = [:]

    private static let pollIntervalNanos: UInt64 = 30 * 1_000_000_000

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
        let nowSeed = Int(Date().timeIntervalSince1970)
        for asset in CryptoAsset.allCases {
            let addresses = await state.pollableCryptoAddresses(asset.chain)
            for address in addresses {
                let key = CursorKey(asset: asset, address: address.lowercased())
                let cursor = cursors[key] ?? ExplorerCursor(lastSeenUnix: nowSeed)
                do {
                    let (transfers, newCursor) = try await fetchTransfers(asset: asset, address: address, cursor: cursor)
                    cursors[key] = newCursor
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
                } catch {
                    logger.error("crypto monitor: \(asset.rawValue) addr=\(address) fetch failed: \(error)")
                }
            }
        }
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
