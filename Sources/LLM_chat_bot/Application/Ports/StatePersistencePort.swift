import Foundation

// MARK: - Rows

struct ChatContextRow: Sendable {
    let key: ChatKey
    let snapshot: ChatContextSnapshot
}

struct TenantRow: Sendable {
    let key: UserKey
    let snapshot: TenantStateSnapshot
}

/// One person: the directory entry plus the DM the bot can reach them at.
/// `bot_user` is the table every other per-person table points at.
struct UserRow: Sendable {
    let identity: UserIdentity
}

/// One chat: its human-readable identity and which tenant's licence covers it.
/// Metadata and ownership used to be two config documents; they are one row
/// because they describe one thing and are read together everywhere.
struct ChatRow: Sendable {
    let chatID: Int
    let meta: ChatMetaInfo?
    let ownerKey: UserKey?
}

struct InviteRow: Sendable {
    let token: String
    let record: InviteRecord
}

/// One free-tier chat's (or user's) daily premium allowance.
struct PremiumUsageRow: Sendable {
    let subject: String
    let usage: DailyPremiumUsage
}

/// One referral attribution.
struct ReferralRow: Sendable {
    let invitedUserID: Int
    let record: ReferralRecord
}

/// Per-inviter aggregates. Deliberately a row of their own: they outlive the
/// records they were computed from, so pruning attributions can never reset an
/// inviter's reward cap or their "friends who paid" count.
struct ReferralTallyRow: Sendable {
    let inviterUserID: Int
    let tally: ReferralTally
}

/// One `src_` attribution: who arrived from which campaign and how far they got.
struct TrafficAttributionRow: Sendable {
    let userID: Int
    let attribution: TrafficSourceAttribution
}

/// One conversion-funnel counter for one day.
struct FunnelDayRow: Sendable {
    let day: Int
    let event: String
    let count: Int
}

struct CryptoInvoiceRow: Sendable {
    let invoice: CryptoInvoice
}

struct ExternalOrderRow: Sendable {
    let order: ExternalPaymentOrder
}

/// One incremental write: only entities that changed since the previous drain.
/// A flush stays O(changed), not O(all chats), no matter how many chats the bot
/// serves.
///
/// Money is **not** here. Wallets, the ledger and payment idempotency keys are
/// written through `LedgerPort` inside a transaction and are durable before the
/// caller is told the payment worked (§3.2). What travels in this batch is
/// everything whose loss for two seconds is survivable.
struct PersistenceBatch: Sendable {
    var users: [UserRow] = []
    var contexts: [ChatContextRow] = []
    var deletedContexts: [ChatKey] = []
    var tenants: [TenantRow] = []
    var deletedTenants: [UserKey] = []
    var chats: [ChatRow] = []
    var deletedChats: [Int] = []
    var invites: [InviteRow] = []
    var deletedInvites: [String] = []
    var premiumUsage: [PremiumUsageRow] = []
    var deletedPremiumUsage: [String] = []
    var referrals: [ReferralRow] = []
    var deletedReferrals: [Int] = []
    var referralTallies: [ReferralTallyRow] = []
    var deletedReferralTallies: [Int] = []
    var trafficAttributions: [TrafficAttributionRow] = []
    var deletedTrafficAttributions: [Int] = []
    var funnelDays: [FunnelDayRow] = []
    var cryptoInvoices: [CryptoInvoiceRow] = []
    var deletedCryptoInvoices: [String] = []
    var externalOrders: [ExternalOrderRow] = []
    var deletedExternalOrders: [String] = []
    var configs: [StoredConfig] = []

    var isEmpty: Bool { entityCount == 0 }

    var entityCount: Int {
        users.count + contexts.count + deletedContexts.count
            + tenants.count + deletedTenants.count
            + chats.count + deletedChats.count
            + invites.count + deletedInvites.count
            + premiumUsage.count + deletedPremiumUsage.count
            + referrals.count + deletedReferrals.count
            + referralTallies.count + deletedReferralTallies.count
            + trafficAttributions.count + deletedTrafficAttributions.count
            + funnelDays.count
            + cryptoInvoices.count + deletedCryptoInvoices.count
            + externalOrders.count + deletedExternalOrders.count
            + configs.count
    }

    /// Combines a batch that failed to flush with a freshly drained one.
    /// Rows from `newer` win — they were exported from the store later — and a
    /// delete in `newer` cancels an older write of the same key (and the other
    /// way round), so a retry can never resurrect something that was removed.
    static func merged(older: PersistenceBatch, newer: PersistenceBatch) -> PersistenceBatch {
        var result = PersistenceBatch()
        result.users = Self.mergeUpserts(older.users, newer.users, by: \.identity.userID)
        (result.contexts, result.deletedContexts) = Self.merge(
            older.contexts, older.deletedContexts, newer.contexts, newer.deletedContexts, by: \.key
        )
        (result.tenants, result.deletedTenants) = Self.merge(
            older.tenants, older.deletedTenants, newer.tenants, newer.deletedTenants, by: \.key
        )
        (result.chats, result.deletedChats) = Self.merge(
            older.chats, older.deletedChats, newer.chats, newer.deletedChats, by: \.chatID
        )
        (result.invites, result.deletedInvites) = Self.merge(
            older.invites, older.deletedInvites, newer.invites, newer.deletedInvites, by: \.token
        )
        (result.premiumUsage, result.deletedPremiumUsage) = Self.merge(
            older.premiumUsage, older.deletedPremiumUsage,
            newer.premiumUsage, newer.deletedPremiumUsage, by: \.subject
        )
        (result.referrals, result.deletedReferrals) = Self.merge(
            older.referrals, older.deletedReferrals, newer.referrals, newer.deletedReferrals, by: \.invitedUserID
        )
        (result.referralTallies, result.deletedReferralTallies) = Self.merge(
            older.referralTallies, older.deletedReferralTallies,
            newer.referralTallies, newer.deletedReferralTallies, by: \.inviterUserID
        )
        (result.trafficAttributions, result.deletedTrafficAttributions) = Self.merge(
            older.trafficAttributions, older.deletedTrafficAttributions,
            newer.trafficAttributions, newer.deletedTrafficAttributions, by: \.userID
        )
        result.funnelDays = Self.mergeUpserts(older.funnelDays, newer.funnelDays) { FunnelDayKey(day: $0.day, event: $0.event) }
        (result.cryptoInvoices, result.deletedCryptoInvoices) = Self.merge(
            older.cryptoInvoices, older.deletedCryptoInvoices,
            newer.cryptoInvoices, newer.deletedCryptoInvoices, by: \.invoice.id
        )
        (result.externalOrders, result.deletedExternalOrders) = Self.merge(
            older.externalOrders, older.deletedExternalOrders,
            newer.externalOrders, newer.deletedExternalOrders, by: \.order.id
        )

        var configsByName: [ConfigName: StoredConfig] = [:]
        for value in older.configs { configsByName[value.name] = value }
        for value in newer.configs { configsByName[value.name] = value }
        result.configs = Array(configsByName.values)
        return result
    }

    private struct FunnelDayKey: Hashable { let day: Int; let event: String }

    private static func mergeUpserts<Row, Key: Hashable>(
        _ older: [Row], _ newer: [Row], by key: (Row) -> Key
    ) -> [Row] {
        var byKey: [Key: Row] = [:]
        for row in older { byKey[key(row)] = row }
        for row in newer { byKey[key(row)] = row }
        return Array(byKey.values)
    }

    private static func mergeUpserts<Row, Key: Hashable>(
        _ older: [Row], _ newer: [Row], by keyPath: KeyPath<Row, Key>
    ) -> [Row] {
        mergeUpserts(older, newer) { $0[keyPath: keyPath] }
    }

    private static func merge<Row, Key: Hashable>(
        _ olderRows: [Row], _ olderDeletes: [Key],
        _ newerRows: [Row], _ newerDeletes: [Key],
        by keyPath: KeyPath<Row, Key>
    ) -> ([Row], [Key]) {
        var rows: [Key: Row] = [:]
        for row in olderRows { rows[row[keyPath: keyPath]] = row }
        var deletes = Set(olderDeletes)
        for key in newerDeletes {
            deletes.insert(key)
            rows.removeValue(forKey: key)
        }
        for row in newerRows {
            let key = row[keyPath: keyPath]
            rows[key] = row
            deletes.remove(key)
        }
        return (Array(rows.values), Array(deletes))
    }
}

// MARK: - Load

struct PersistedBotState: Sendable {
    var users: [UserRow] = []
    var contexts: [ChatContextRow] = []
    var tenants: [TenantRow] = []
    var chats: [ChatRow] = []
    var invites: [InviteRow] = []
    var premiumUsage: [PremiumUsageRow] = []
    var referrals: [ReferralRow] = []
    var referralTallies: [ReferralTallyRow] = []
    var trafficAttributions: [TrafficAttributionRow] = []
    var funnelDays: [FunnelDayRow] = []
    var cryptoInvoices: [CryptoInvoiceRow] = []
    var externalOrders: [ExternalOrderRow] = []
    /// Wallets come from the money tables (`LedgerPort`), but they are restored
    /// into the same store, so the boot path carries them together.
    var wallets: [UserKey: UserBalance] = [:]
    var configs = ConfigDocuments()
}

protocol StatePersistencePort: Sendable {
    func loadEverything() async throws -> PersistedBotState
    func apply(_ batch: PersistenceBatch) async throws

    /// Deletes chat conversations untouched for longer than `idleDays`, except
    /// the chats named. Returns what went, so the in-memory cache can drop the
    /// same rows.
    ///
    /// A product that takes money and stores people's conversations needs an
    /// answer to "how long do you keep this", and "forever, with no way to
    /// erase it" is not one. The query is cheap because `bot_chat_context` is
    /// indexed on `updated_at` (§10.3).
    func pruneChatContexts(idleDays: Int, protecting: Set<Int>) async throws -> [ChatKey]
}
