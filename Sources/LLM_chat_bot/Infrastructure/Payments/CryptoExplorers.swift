import Foundation

struct IncomingCryptoTransfer: Sendable {
    let asset: CryptoAsset
    let amountAtomic: Int64
    let fromAddress: String?
    let txHash: String
    let timestamp: Date
}

/// Where a scan stopped, in whole unix seconds.
///
/// The bound is **inclusive**: everything at `lastSeenUnix` is offered again on
/// the next pass. A chain puts several transfers in the same second all the
/// time, and an indexer does not publish them in the same instant — so an
/// exclusive bound silently dropped every transfer that shared its second with
/// one already seen, which on a blockchain means the money is gone. Re-offering
/// costs nothing: a credit is made once-only by tx hash, not by the clock.
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

/// TON addresses come in two spellings for the same account: the raw
/// `<workchain>:<32-byte hex>` an indexer returns, and the base64url
/// "user-friendly" `EQ…`/`UQ…` a wallet shows. Deciding whether two of them
/// name the same account therefore means decoding, not string matching — and
/// this comparison decides whether an incoming token is the USDT we invoiced or
/// something an attacker minted for free.
enum TonAddress {
    /// Canonical `<workchain>:<64 lowercase hex>`, or nil if the input is
    /// neither spelling.
    static func normalized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let colon = trimmed.firstIndex(of: ":") {
            guard let workchain = Int(trimmed[trimmed.startIndex..<colon]) else { return nil }
            let hex = trimmed[trimmed.index(after: colon)...].lowercased()
            guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
            return "\(workchain):\(hex)"
        }

        // Friendly form: base64url of [flags][workchain][32-byte hash][crc16].
        var base64 = trimmed
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64), data.count == 36 else { return nil }
        let workchain = Int(Int8(bitPattern: data[data.startIndex + 1]))
        let hash = data
            .subdata(in: (data.startIndex + 2)..<(data.startIndex + 34))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(workchain):\(hash)"
    }

    /// True only when both addresses decode to the same account. An input that
    /// decodes to nothing matches nothing but an identical string — guessing
    /// here is what let any jetton pass as USDT.
    static func equal(_ lhs: String, _ rhs: String) -> Bool {
        guard let a = normalized(lhs), let b = normalized(rhs) else {
            return lhs.caseInsensitiveCompare(rhs) == .orderedSame
        }
        return a == b
    }
}

// MARK: - TON

final class TonExplorer: Sendable {
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

        // Our own address is configured by hand, so it arrives in whichever
        // spelling the admin's wallet showed them; tonapi answers in the raw
        // one. Comparing the two as strings never matches.
        var transfers: [IncomingCryptoTransfer] = []
        var maxTs = cursor.lastSeenUnix

        for event in resp.events {
            if event.in_progress == true { continue }
            if event.timestamp < cursor.lastSeenUnix { continue }
            if event.timestamp > maxTs { maxTs = event.timestamp }
            for action in event.actions {
                if action.status != nil && action.status != "ok" { continue }
                switch asset {
                case .tonNative:
                    guard action.type == "TonTransfer", let p = action.TonTransfer else { continue }
                    if !TonAddress.equal(p.recipient.address, address) { continue }
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
                    // Which token this is decides whether real money arrived.
                    // Anyone can mint a jetton with USDT's decimals and send it
                    // for the price of gas, so this comparison must be exact.
                    if !TonAddress.equal(p.jetton.address, contract) { continue }
                    // A transfer with no recipient we can read is not one we can
                    // attribute — dropping it is the safe direction.
                    guard let recipient = p.recipient?.address,
                          TonAddress.equal(recipient, address) else { continue }
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

}

// MARK: - EVM (BSC / Ethereum) — Etherscan API V2 (multichain, one key)

final class EvmExplorer: Sendable {
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
            if ts < cursor.lastSeenUnix { continue }
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

final class TronExplorer: Sendable {
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
        let minMs = max(0, cursor.lastSeenUnix) * 1000
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
        var transfers: [IncomingCryptoTransfer] = []
        var maxTs = cursor.lastSeenUnix

        for tx in resp.data {
            if tx.type != "Transfer" { continue }
            // Exact, not case-folded: Tron addresses are base58, where case is
            // significant. This is the check that separates real USDT from a
            // token anyone can mint, so it does not get to be approximate.
            guard tx.token_info.address == contract else { continue }
            if tx.to.lowercased() != normalizedAddress { continue }
            guard let amount = Int64(tx.value), amount > 0 else { continue }
            let tsSec = Int(tx.block_timestamp / 1000)
            if tsSec < cursor.lastSeenUnix { continue }
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
