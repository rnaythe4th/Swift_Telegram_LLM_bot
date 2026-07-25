import Foundation

/// Row-based persistence on Supabase Postgres via PostgREST.
///
/// Schema (see DEPLOY.md for the SQL):
///   bot_chat_contexts(chat_id int8, thread_id int8, data jsonb, updated_at) PK (chat_id, thread_id)
///   bot_tenants(username text PK, data jsonb, updated_at)
///   bot_chat_ownership(chat_id int8 PK, owner_username text, updated_at)
///   bot_config(key text PK, data jsonb, updated_at)
///   bot_state(id int8 PK, data jsonb)                  -- legacy blob, read-only for migration
///
/// Writes are incremental upserts of only the entities that changed, so cost
/// stays proportional to activity — not to the number of chats the bot holds.
final class SupabaseStatePersistence: StatePersistencePort, @unchecked Sendable {
    private let network: NetworkClient
    private let baseURL: String
    private let apiKey: String

    private static let pageSize = 1000
    private static let upsertChunkSize = 200

    init(network: NetworkClient, baseURL: String, apiKey: String) {
        self.network = network
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    // MARK: - Row DTOs

    private struct ChatContextDBRow: Codable {
        let chat_id: Int
        let thread_id: Int64
        let data: ChatContextSnapshot
    }

    private struct TenantDBRow: Codable {
        let username: String
        let data: TenantStateSnapshot
    }

    private struct OwnershipDBRow: Codable {
        let chat_id: Int
        let owner_username: String
    }

    /// Config values are wrapped in `{"value": …}` so every `bot_config.data`
    /// cell is a JSON object regardless of the payload type.
    private struct Envelope<T: Codable>: Codable {
        let value: T?
    }

    private struct ConfigDBRow<T: Codable>: Codable {
        let key: String
        let data: Envelope<T>
    }

    private struct ConfigDataRow<T: Codable>: Codable {
        let data: Envelope<T>
    }

    // MARK: - Load

    func loadEverything() async throws -> PersistedBotState {
        let contextRows: [ChatContextDBRow] = try await fetchAll(table: "bot_chat_contexts", select: "chat_id,thread_id,data")
        let tenantRows: [TenantDBRow] = try await fetchAll(table: "bot_tenants", select: "username,data")
        let ownershipRows: [OwnershipDBRow] = try await fetchAll(table: "bot_chat_ownership", select: "chat_id,owner_username")

        var configs = PersistedGlobalConfigs()
        configs.starsPrice = try await fetchConfig(.starsPrice, as: Int.self)
        configs.starsPerUsd = try await fetchConfig(.starsPerUsd, as: Int.self)
        configs.freeModelIDs = try await fetchConfig(.freeModels, as: [String].self)
        configs.crypto = try await fetchConfig(.crypto, as: CryptoConfigSnapshot.self)
        configs.card = try await fetchConfig(.card, as: CardPaymentConfig.self)
        configs.superAdmins = try await fetchConfig(.superAdmins, as: [String].self)
        configs.processedPayments = try await fetchConfig(.processedPayments, as: [String].self)
        configs.pollingOffset = try await fetchConfig(.pollingOffset, as: Int.self)
        configs.chatMeta = try await fetchConfig(.chatMeta, as: [String: ChatMetaInfo].self)
        configs.invites = try await fetchConfig(.invites, as: [String: InviteRecord].self)
        configs.ads = try await fetchConfig(.ads, as: [AdCampaign].self)
        configs.markup = try await fetchConfig(.markup, as: Int.self)
        configs.balances = try await fetchConfig(.balances, as: [String: UserBalance].self)
        configs.funnel = try await fetchConfig(.funnel, as: [String: Int].self)
        configs.funnelDaily = try await fetchConfig(.funnelDaily, as: FunnelDailyLog.self)
        configs.dailyPremiumLimit = try await fetchConfig(.dailyPremiumLimit, as: Int.self)
        configs.dailyPremiumUsage = try await fetchConfig(.dailyPremiumUsage, as: [String: DailyPremiumUsage].self)
        configs.selfPromo = try await fetchConfig(.selfPromo, as: SelfPromoConfig.self)
        configs.reminders = try await fetchConfig(.reminders, as: SubscriptionReminderConfig.self)
        configs.onboarding = try await fetchConfig(.onboarding, as: OnboardingConfig.self)
        configs.referrals = try await fetchConfig(.referrals, as: ReferralConfig.self)
        configs.referralLedger = try await fetchConfig(.referralLedger, as: ReferralLedger.self)
        configs.userDirectory = try await fetchConfig(.userDirectory, as: UserDirectory.self)

        return PersistedBotState(
            contexts: contextRows.map {
                ChatContextRow(key: ChatKey(chatID: $0.chat_id, threadID: $0.thread_id), snapshot: $0.data)
            },
            tenants: tenantRows.map { TenantRow(username: $0.username, snapshot: $0.data) },
            ownership: ownershipRows.map { OwnershipRow(chatID: $0.chat_id, owner: $0.owner_username) },
            configs: configs
        )
    }

    func loadLegacySnapshot() async throws -> BotStateSnapshot? {
        struct LegacyRow: Codable {
            let data: BotStateSnapshot
        }
        let spec = HTTPRequestSpec(
            url: "\(baseURL)/rest/v1/bot_state?select=data&id=eq.1",
            method: .get,
            headers: authHeaders,
            timeoutSeconds: 30,
            maxBodyBytes: 1 << 26,
            validStatusCodes: 200..<300
        )
        do {
            let rows: [LegacyRow] = try await network.send(spec)
            return rows.first?.data
        } catch let error as NetworkTransportError {
            // Legacy table absent — nothing to migrate.
            if case .invalidStatus(let response) = error, response.statusCode == 404 {
                return nil
            }
            throw error
        }
    }

    private func fetchAll<Row: Decodable>(table: String, select: String) async throws -> [Row] {
        var all: [Row] = []
        var offset = 0
        while true {
            let spec = HTTPRequestSpec(
                url: "\(baseURL)/rest/v1/\(table)?select=\(select)&limit=\(Self.pageSize)&offset=\(offset)",
                method: .get,
                headers: authHeaders,
                timeoutSeconds: 30,
                maxBodyBytes: 1 << 26,
                validStatusCodes: 200..<300
            )
            let rows: [Row] = try await network.send(spec)
            all.append(contentsOf: rows)
            if rows.count < Self.pageSize { break }
            offset += Self.pageSize
        }
        return all
    }

    private func fetchConfig<T: Codable>(_ key: GlobalConfigKey, as type: T.Type) async throws -> T? {
        let spec = HTTPRequestSpec(
            url: "\(baseURL)/rest/v1/bot_config?select=data&key=eq.\(key.rawValue)",
            method: .get,
            headers: authHeaders,
            timeoutSeconds: 15,
            validStatusCodes: 200..<300
        )
        let rows: [ConfigDataRow<T>] = try await network.send(spec)
        return rows.first?.data.value
    }

    // MARK: - Apply batch

    func apply(_ batch: PersistenceBatch) async throws {
        // Deletes first so a delete + re-create within one batch ends created.
        if !batch.deletedTenants.isEmpty {
            try await delete(table: "bot_tenants", column: "username", values: batch.deletedTenants.map(quoted))
        }
        if !batch.deletedOwnership.isEmpty {
            try await delete(table: "bot_chat_ownership", column: "chat_id", values: batch.deletedOwnership.map(String.init))
        }

        try await upsertChunked(
            table: "bot_chat_contexts",
            rows: batch.contexts.map {
                ChatContextDBRow(chat_id: $0.key.chatID, thread_id: $0.key.threadID, data: $0.snapshot)
            }
        )
        try await upsertChunked(
            table: "bot_tenants",
            rows: batch.tenants.map { TenantDBRow(username: $0.username, data: $0.snapshot) }
        )
        try await upsertChunked(
            table: "bot_chat_ownership",
            rows: batch.ownership.map { OwnershipDBRow(chat_id: $0.chatID, owner_username: $0.owner) }
        )

        for config in batch.configs {
            try await upsertConfig(config)
        }
    }

    private func upsertChunked<Row: Encodable>(table: String, rows: [Row]) async throws {
        guard !rows.isEmpty else { return }
        var index = 0
        while index < rows.count {
            let chunk = Array(rows[index..<min(index + Self.upsertChunkSize, rows.count)])
            try await upsert(table: table, body: AnyEncodable(chunk))
            index += Self.upsertChunkSize
        }
    }

    private func upsertConfig(_ config: GlobalConfigValue) async throws {
        let body: AnyEncodable
        switch config {
        case .starsPrice(let value):
            body = AnyEncodable([ConfigDBRow(key: config.key.rawValue, data: Envelope(value: value))])
        case .starsPerUsd(let value):
            body = AnyEncodable([ConfigDBRow(key: config.key.rawValue, data: Envelope(value: value))])
        case .freeModels(let value):
            body = AnyEncodable([ConfigDBRow(key: config.key.rawValue, data: Envelope(value: value))])
        case .crypto(let value):
            body = AnyEncodable([ConfigDBRow(key: config.key.rawValue, data: Envelope(value: value))])
        case .card(let value):
            body = AnyEncodable([ConfigDBRow(key: config.key.rawValue, data: Envelope(value: value))])
        case .superAdmins(let value):
            body = AnyEncodable([ConfigDBRow(key: config.key.rawValue, data: Envelope(value: value))])
        case .processedPayments(let value):
            body = AnyEncodable([ConfigDBRow(key: config.key.rawValue, data: Envelope(value: value))])
        case .pollingOffset(let value):
            body = AnyEncodable([ConfigDBRow(key: config.key.rawValue, data: Envelope(value: value))])
        case .chatMeta(let value):
            body = AnyEncodable([ConfigDBRow(key: config.key.rawValue, data: Envelope(value: value))])
        case .invites(let value):
            body = AnyEncodable([ConfigDBRow(key: config.key.rawValue, data: Envelope(value: value))])
        case .ads(let value):
            body = AnyEncodable([ConfigDBRow(key: config.key.rawValue, data: Envelope(value: value))])
        case .markup(let value):
            body = AnyEncodable([ConfigDBRow(key: config.key.rawValue, data: Envelope(value: value))])
        case .balances(let value):
            body = AnyEncodable([ConfigDBRow(key: config.key.rawValue, data: Envelope(value: value))])
        case .funnel(let value):
            body = AnyEncodable([ConfigDBRow(key: config.key.rawValue, data: Envelope(value: value))])
        case .funnelDaily(let value):
            body = AnyEncodable([ConfigDBRow(key: config.key.rawValue, data: Envelope(value: value))])
        case .dailyPremiumLimit(let value):
            body = AnyEncodable([ConfigDBRow(key: config.key.rawValue, data: Envelope(value: value))])
        case .dailyPremiumUsage(let value):
            body = AnyEncodable([ConfigDBRow(key: config.key.rawValue, data: Envelope(value: value))])
        case .selfPromo(let value):
            body = AnyEncodable([ConfigDBRow(key: config.key.rawValue, data: Envelope(value: value))])
        case .reminders(let value):
            body = AnyEncodable([ConfigDBRow(key: config.key.rawValue, data: Envelope(value: value))])
        case .onboarding(let value):
            body = AnyEncodable([ConfigDBRow(key: config.key.rawValue, data: Envelope(value: value))])
        case .referrals(let value):
            body = AnyEncodable([ConfigDBRow(key: config.key.rawValue, data: Envelope(value: value))])
        case .referralLedger(let value):
            body = AnyEncodable([ConfigDBRow(key: config.key.rawValue, data: Envelope(value: value))])
        case .userDirectory(let value):
            body = AnyEncodable([ConfigDBRow(key: config.key.rawValue, data: Envelope(value: value))])
        }
        try await upsert(table: "bot_config", body: body)
    }

    private func upsert(table: String, body: AnyEncodable) async throws {
        var headers = authHeaders
        headers["Prefer"] = "resolution=merge-duplicates,return=minimal"
        let spec = HTTPRequestSpec(
            url: "\(baseURL)/rest/v1/\(table)",
            method: .post,
            headers: headers,
            body: .json(body),
            timeoutSeconds: 20,
            validStatusCodes: 200..<300
        )
        _ = try await network.perform(spec)
    }

    private func delete(table: String, column: String, values: [String]) async throws {
        let list = values.joined(separator: ",")
        let filter = "\(column)=in.(\(list))"
        let encoded = filter.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filter
        let spec = HTTPRequestSpec(
            url: "\(baseURL)/rest/v1/\(table)?\(encoded)",
            method: .delete,
            headers: authHeaders,
            timeoutSeconds: 20,
            validStatusCodes: 200..<300
        )
        _ = try await network.perform(spec)
    }

    private func quoted(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: ""))\""
    }

    private var authHeaders: [String: String] {
        [
            "apikey": apiKey,
            "Authorization": "Bearer \(apiKey)",
        ]
    }
}
