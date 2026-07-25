import Foundation

enum CryptoMatchMode: String, Codable, Sendable, CaseIterable {
    /// Single shared address per chain, invoices differentiated by unique amount delta.
    case amountDelta = "amount_delta"
    /// Pool of pre-funded addresses per chain, one address allocated per invoice.
    case uniqueAddress = "unique_address"

    var displayName: String {
        switch self {
        case .amountDelta:   return "Дельта суммы"
        case .uniqueAddress: return "Уникальный адрес"
        }
    }
}

enum CryptoChain: String, Codable, Sendable, CaseIterable {
    case ton
    case bsc
    case eth
    case tron

    var displayName: String {
        switch self {
        case .ton: return "TON"
        case .bsc: return "BNB Smart Chain"
        case .eth: return "Ethereum"
        case .tron: return "Tron"
        }
    }
}

enum CryptoAsset: String, Codable, Sendable, CaseIterable {
    case tonNative   = "ton"
    case usdtTon     = "usdt_ton"
    case usdtBsc     = "usdt_bsc"
    case usdtEth     = "usdt_eth"
    case usdtTrx     = "usdt_trx"

    var chain: CryptoChain {
        switch self {
        case .tonNative, .usdtTon: return .ton
        case .usdtBsc:             return .bsc
        case .usdtEth:             return .eth
        case .usdtTrx:             return .tron
        }
    }

    var symbol: String {
        switch self {
        case .tonNative: return "TON"
        case .usdtTon, .usdtBsc, .usdtEth, .usdtTrx: return "USDT"
        }
    }

    var decimals: Int {
        switch self {
        case .tonNative: return 9
        case .usdtTon, .usdtBsc, .usdtEth, .usdtTrx: return 6
        }
    }

    /// Smallest atomic delta that doesn't visibly change the displayed amount yet remains unique.
    /// We use the smallest atomic unit (1 wei equivalent) — providers preserve precision exactly.
    var atomicSlotStep: Int64 { 1 }

    /// Maximum number of unique slots before wraparound. Keeps the visible amount within
    /// ~0.0001 of the base for USDT (6 decimals, 100 slots = 0.0001) and tiny for TON (9 dec).
    var maxConcurrentSlots: Int { 100_000 }

    /// Token contract address (nil for native).
    var contractAddress: String? {
        switch self {
        case .tonNative: return nil
        case .usdtTon:   return "EQCxE6mUtQJKFnGfaROTKOt1lZbDiiX1kCixRv7Nw2Id_sDs"
        case .usdtBsc:   return "0x55d398326f99059ff775485246999027b3197955"
        case .usdtEth:   return "0xdac17f958d2ee523a2206206994597c13d831ec7"
        case .usdtTrx:   return "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
        }
    }

    var displayLabel: String {
        switch self {
        case .tonNative: return "TON (native)"
        case .usdtTon:   return "USDT · TON"
        case .usdtBsc:   return "USDT · BSC"
        case .usdtEth:   return "USDT · ERC20"
        case .usdtTrx:   return "USDT · TRC20"
        }
    }
}

enum CryptoInvoiceStatus: String, Codable, Sendable {
    case open
    case partial
    case paid
    case expired
    case cancelled
}

/// What a crypto invoice buys. Absent (nil) on invoices persisted before credit
/// packs existed → decoded as `.subscription` via `resolvedPurpose`.
enum CryptoInvoicePurpose: Codable, Sendable, Equatable {
    case subscription
    /// Top up the pay-as-you-go balance by `cents` USD (face value credited).
    case credit(cents: Int)
}

struct CryptoInvoice: Codable, Sendable, Identifiable {
    var id: String
    var username: String
    var userChatID: Int
    var asset: CryptoAsset
    var receivingAddress: String
    /// Atomic units (e.g. micro-USDT or nano-TON) the user must send in total.
    var exactAmountAtomic: Int64
    /// Atomic units already received, summed across one or more transactions.
    var accumulatedAtomic: Int64
    /// Underlying USD-cents quote at invoice creation (informational).
    var quotedPriceUsdCents: Int
    /// Rate atomic-units-per-USD-cent recorded at invoice creation (e.g. for TON via CoinGecko).
    var rateAtomicPerUsdCentMicro: Int64
    var createdAt: Date
    var expiresAt: Date
    var status: CryptoInvoiceStatus
    /// Sender addresses observed in matched transactions — used to attribute partial payments.
    var linkedSenders: [String]
    /// Tx hashes already credited (dedup against re-poll).
    var creditedTxHashes: [String]
    /// Slot offset (0..maxConcurrentSlots) used to keep amount unique.
    var slotOffset: Int
    /// What this invoice buys. Optional for backward compatibility with rows
    /// written before credit packs existed; read via `resolvedPurpose`.
    var purpose: CryptoInvoicePurpose? = nil

    var remainingAtomic: Int64 { max(0, exactAmountAtomic - accumulatedAtomic) }

    /// Purpose with the legacy default applied (nil → subscription).
    var resolvedPurpose: CryptoInvoicePurpose { purpose ?? .subscription }
}

struct CryptoConfigSnapshot: Codable, Sendable {
    var priceUsdCents: Int?
    var addresses: [String: String]
    var slotCounters: [String: Int]
    var invoices: [CryptoInvoice]
    var matchMode: String?
    var addressPools: [String: [String]]?
    /// Explorer scan position per `"<asset>:<address>"`, in unix seconds.
    /// Persisted on purpose: a cursor seeded at process start skips every
    /// transfer that landed while the bot was down (redeploys are frequent) —
    /// and crypto, unlike Telegram, has no delivery retry to fall back on.
    var explorerCursors: [String: Int]?
}

enum CryptoAmountFormatter {
    static func format(atomic: Int64, decimals: Int) -> String {
        let negative = atomic < 0
        let value = abs(atomic)
        let divisor = pow10(decimals)
        let whole = value / divisor
        let frac = value % divisor
        if frac == 0 {
            return (negative ? "-" : "") + "\(whole)"
        }
        let fracStr = String(format: "%0\(decimals)lld", frac)
        let trimmed = fracStr.reversed().drop(while: { $0 == "0" }).reversed()
        return (negative ? "-" : "") + "\(whole).\(String(trimmed))"
    }

    static func parseAtomic(_ raw: String, decimals: Int) -> Int64? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let wholePart = String(parts[0])
        let fracPart = parts.count > 1 ? String(parts[1]) : ""
        guard let whole = Int64(wholePart) else { return nil }
        let paddedFrac = (fracPart + String(repeating: "0", count: decimals)).prefix(decimals)
        guard let frac = Int64(paddedFrac) else { return nil }
        let divisor = pow10(decimals)
        return whole * divisor + (whole >= 0 ? frac : -frac)
    }

    private static func pow10(_ n: Int) -> Int64 {
        var v: Int64 = 1
        for _ in 0..<n { v *= 10 }
        return v
    }
}
