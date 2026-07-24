import Foundation

struct IncomingCryptoTransfer: Sendable {
    let asset: CryptoAsset
    let amountAtomic: Int64
    let fromAddress: String?
    let txHash: String
    let timestamp: Date
}

struct ExplorerCursor: Sendable {
    var lastSeenUnix: Int
}

enum ExplorerError: LocalizedError {
    case http(String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .http(let m): return "explorer http: \(m)"
        case .decode(let m): return "explorer decode: \(m)"
        }
    }
}

// MARK: - TON

final class TonExplorer: @unchecked Sendable {
    private let network: NetworkClient
    private let apiKey: String?
    private let baseURL = "https://tonapi.io"

    init(network: NetworkClient, apiKey: String?) {
        self.network = network
        self.apiKey = apiKey
    }

    private var headers: [String: String] {
        guard let key = apiKey, !key.isEmpty else { return [:] }
        return ["Authorization": "Bearer \(key)"]
    }

    private struct EventsResponse: Decodable {
        let events: [Event]
    }
    private struct Event: Decodable {
        let event_id: String
        let timestamp: Int
        let in_progress: Bool?
        let actions: [Action]
    }
    private struct Action: Decodable {
        let type: String
        let status: String?
        let TonTransfer: TonTransferPayload?
        let JettonTransfer: JettonTransferPayload?
    }
    private struct TonTransferPayload: Decodable {
        let sender: AccountRef
        let recipient: AccountRef
        let amount: Int64
    }
    private struct JettonTransferPayload: Decodable {
        let sender: AccountRef?
        let recipient: AccountRef?
        let amount: String
        let jetton: JettonRef
    }
    private struct AccountRef: Decodable {
        let address: String
    }
    private struct JettonRef: Decodable {
        let address: String
    }

    func fetchIncoming(asset: CryptoAsset, address: String, since cursor: ExplorerCursor) async throws -> ([IncomingCryptoTransfer], ExplorerCursor) {
        precondition(asset.chain == .ton)
        let limit = 100
        let urlString = "\(baseURL)/v2/accounts/\(address)/events?limit=\(limit)"
        let spec = HTTPRequestSpec(
            url: urlString,
            method: .get,
            headers: headers,
            timeoutSeconds: 20
        )
        let resp: EventsResponse
        do {
            resp = try await network.send(spec, as: EventsResponse.self)
        } catch {
            throw ExplorerError.http(String(describing: error))
        }

        let normalizedAddress = address.lowercased()
        var transfers: [IncomingCryptoTransfer] = []
        var maxTs = cursor.lastSeenUnix

        for event in resp.events {
            if event.in_progress == true { continue }
            if event.timestamp <= cursor.lastSeenUnix { continue }
            if event.timestamp > maxTs { maxTs = event.timestamp }
            for action in event.actions {
                if action.status != nil && action.status != "ok" { continue }
                switch asset {
                case .tonNative:
                    guard action.type == "TonTransfer", let p = action.TonTransfer else { continue }
                    if p.recipient.address.lowercased() != normalizedAddress { continue }
                    if p.amount <= 0 { continue }
                    transfers.append(IncomingCryptoTransfer(
                        asset: .tonNative,
                        amountAtomic: p.amount,
                        fromAddress: p.sender.address,
                        txHash: event.event_id,
                        timestamp: Date(timeIntervalSince1970: TimeInterval(event.timestamp))
                    ))
                case .usdtTon:
                    guard action.type == "JettonTransfer", let p = action.JettonTransfer else { continue }
                    guard let contract = asset.contractAddress else { continue }
                    if !addressesEqual(p.jetton.address, contract) { continue }
                    if let recipient = p.recipient?.address, recipient.lowercased() != normalizedAddress { continue }
                    guard let amount = Int64(p.amount), amount > 0 else { continue }
                    transfers.append(IncomingCryptoTransfer(
                        asset: .usdtTon,
                        amountAtomic: amount,
                        fromAddress: p.sender?.address,
                        txHash: event.event_id,
                        timestamp: Date(timeIntervalSince1970: TimeInterval(event.timestamp))
                    ))
                default:
                    continue
                }
            }
        }

        return (transfers, ExplorerCursor(lastSeenUnix: maxTs))
    }

    private func addressesEqual(_ a: String, _ b: String) -> Bool {
        // Compare by lowercased; tonapi may use raw `0:...` while constants use friendly EQ form.
        // For jetton master contracts a substring match on hex tail is acceptable for our purpose.
        let la = a.lowercased()
        let lb = b.lowercased()
        if la == lb { return true }
        if la.contains(":"), lb.hasPrefix("eq") || lb.hasPrefix("uq") { return true }
        if lb.contains(":"), la.hasPrefix("eq") || la.hasPrefix("uq") { return true }
        return false
    }
}

// MARK: - EVM (BSC / Ethereum) — Etherscan API V2 (multichain, one key)

final class EvmExplorer: @unchecked Sendable {
    private let network: NetworkClient
    private let baseURL: String
    /// Etherscan V2 chain id: 1 = Ethereum, 56 = BSC.
    private let chainID: Int
    private let apiKey: String

    init(network: NetworkClient, baseURL: String = "https://api.etherscan.io/v2/api", chainID: Int, apiKey: String) {
        self.network = network
        self.baseURL = baseURL
        self.chainID = chainID
        self.apiKey = apiKey
    }

    private struct TokenTxResponse: Decodable {
        let status: String
        let message: String?
        let result: TxList
    }
    private enum TxList: Decodable {
        case items([TokenTx])
        case message(String)
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let arr = try? container.decode([TokenTx].self) {
                self = .items(arr)
            } else if let msg = try? container.decode(String.self) {
                self = .message(msg)
            } else {
                throw DecodingError.typeMismatch(TxList.self, .init(codingPath: decoder.codingPath, debugDescription: "Expected array or string"))
            }
        }
    }
    private struct TokenTx: Decodable {
        let hash: String
        let from: String
        let to: String
        let value: String
        let timeStamp: String
        let contractAddress: String
    }

    func fetchIncoming(asset: CryptoAsset, address: String, since cursor: ExplorerCursor) async throws -> ([IncomingCryptoTransfer], ExplorerCursor) {
        guard let contract = asset.contractAddress else {
            return ([], cursor)
        }
        let urlString = "\(baseURL)?chainid=\(chainID)&module=account&action=tokentx&contractaddress=\(contract)&address=\(address)&page=1&offset=100&sort=desc&apikey=\(apiKey)"
        let spec = HTTPRequestSpec(
            url: urlString,
            method: .get,
            timeoutSeconds: 20
        )
        let resp: TokenTxResponse
        do {
            resp = try await network.send(spec, as: TokenTxResponse.self)
        } catch {
            throw ExplorerError.http(String(describing: error))
        }
        guard case .items(let txs) = resp.result else {
            return ([], cursor)
        }

        let normalizedAddress = address.lowercased()
        let normalizedContract = contract.lowercased()
        var transfers: [IncomingCryptoTransfer] = []
        var maxTs = cursor.lastSeenUnix

        for tx in txs {
            guard let ts = Int(tx.timeStamp) else { continue }
            if ts <= cursor.lastSeenUnix { continue }
            if ts > maxTs { maxTs = ts }
            if tx.contractAddress.lowercased() != normalizedContract { continue }
            if tx.to.lowercased() != normalizedAddress { continue }
            guard let amount = Int64(tx.value), amount > 0 else { continue }
            transfers.append(IncomingCryptoTransfer(
                asset: asset,
                amountAtomic: amount,
                fromAddress: tx.from,
                txHash: tx.hash,
                timestamp: Date(timeIntervalSince1970: TimeInterval(ts))
            ))
        }

        return (transfers, ExplorerCursor(lastSeenUnix: maxTs))
    }
}

// MARK: - Tron

final class TronExplorer: @unchecked Sendable {
    private let network: NetworkClient
    private let apiKey: String?
    private let baseURL = "https://api.trongrid.io"

    init(network: NetworkClient, apiKey: String?) {
        self.network = network
        self.apiKey = apiKey
    }

    private var headers: [String: String] {
        guard let key = apiKey, !key.isEmpty else { return [:] }
        return ["TRON-PRO-API-KEY": key]
    }

    private struct Trc20Response: Decodable {
        let data: [Trc20Tx]
        let success: Bool?
    }
    private struct Trc20Tx: Decodable {
        let transaction_id: String
        let token_info: TokenInfo
        let block_timestamp: Int64
        let from: String
        let to: String
        let type: String
        let value: String
    }
    private struct TokenInfo: Decodable {
        let address: String?
        let symbol: String?
        let decimals: Int?
    }

    func fetchIncoming(asset: CryptoAsset, address: String, since cursor: ExplorerCursor) async throws -> ([IncomingCryptoTransfer], ExplorerCursor) {
        precondition(asset == .usdtTrx)
        guard let contract = asset.contractAddress else { return ([], cursor) }
        let minMs = (cursor.lastSeenUnix == 0 ? 0 : (cursor.lastSeenUnix + 1) * 1000)
        let urlString = "\(baseURL)/v1/accounts/\(address)/transactions/trc20?only_confirmed=true&only_to=true&limit=200&min_timestamp=\(minMs)&contract_address=\(contract)"
        let spec = HTTPRequestSpec(
            url: urlString,
            method: .get,
            headers: headers,
            timeoutSeconds: 20
        )
        let resp: Trc20Response
        do {
            resp = try await network.send(spec, as: Trc20Response.self)
        } catch {
            throw ExplorerError.http(String(describing: error))
        }

        let normalizedAddress = address.lowercased()
        let normalizedContract = contract.lowercased()
        var transfers: [IncomingCryptoTransfer] = []
        var maxTs = cursor.lastSeenUnix

        for tx in resp.data {
            if tx.type != "Transfer" { continue }
            if (tx.token_info.address?.lowercased() ?? "") != normalizedContract { continue }
            if tx.to.lowercased() != normalizedAddress { continue }
            guard let amount = Int64(tx.value), amount > 0 else { continue }
            let tsSec = Int(tx.block_timestamp / 1000)
            if tsSec <= cursor.lastSeenUnix { continue }
            if tsSec > maxTs { maxTs = tsSec }
            transfers.append(IncomingCryptoTransfer(
                asset: asset,
                amountAtomic: amount,
                fromAddress: tx.from,
                txHash: tx.transaction_id,
                timestamp: Date(timeIntervalSince1970: TimeInterval(tsSec))
            ))
        }

        return (transfers, ExplorerCursor(lastSeenUnix: maxTs))
    }
}
