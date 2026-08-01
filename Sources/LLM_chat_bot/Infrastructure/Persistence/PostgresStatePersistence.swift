import Foundation
import Logging
import PostgresNIO

/// Row-based persistence straight over the Postgres wire protocol.
///
/// Replaces the PostgREST client. What that swap buys, in order of how much it
/// matters: transactions (money moves as one unit — see `PostgresLedger`),
/// constraints the database enforces itself, `pg_try_advisory_lock` for an
/// honest single writer, and queries that are parameterised *by construction* —
/// `PostgresQuery` is `ExpressibleByStringInterpolation`, so an interpolated
/// value becomes a bind parameter and cannot become SQL. The manual
/// percent-encoding that guarded the old `DELETE` (and the comment explaining
/// that a filter-less DELETE empties the table) has nothing left to guard.
///
/// Writes are incremental upserts of only what changed, so cost stays
/// proportional to activity rather than to the number of chats held.
final class PostgresStatePersistence: StatePersistencePort, Sendable {
    private let client: PostgresClient
    private let logger: LoggerPort
    private let queryLogger: Logger

    init(client: PostgresClient, logger: LoggerPort) {
        self.client = client
        self.logger = logger
        self.queryLogger = Logger(label: "postgres.query") { _ in PostgresLogHandler(sink: logger) }
    }

    // MARK: - Schema

    /// Brings the database up to `PostgresSchema.version`, or refuses to run.
    func migrate() async throws {
        try await client.query(PostgresQuery(unsafeSQL: PostgresSchema.metaTable), logger: queryLogger)

        let current = try await currentSchemaVersion()
        guard current <= PostgresSchema.version else {
            throw PostgresSchemaError.databaseNewerThanBinary(
                database: current,
                binary: PostgresSchema.version
            )
        }
        guard current < PostgresSchema.version else { return }

        for step in PostgresSchema.steps where step.index > current {
            for statement in step.statements {
                try await client.query(PostgresQuery(unsafeSQL: statement), logger: queryLogger)
            }
            try await client.query(
                """
                insert into bot_schema_meta (id, version, applied_at)
                values (1, \(step.index), now())
                on conflict (id) do update set version = excluded.version, applied_at = excluded.applied_at
                """,
                logger: queryLogger
            )
            logger.info("schema migrated to version \(step.index)")
        }
    }

    private func currentSchemaVersion() async throws -> Int {
        let rows = try await client.query("select version from bot_schema_meta where id = 1", logger: queryLogger)
        for try await row in rows {
            return try PostgresRandomAccessRow(row)["version"].decode(Int.self)
        }
        return 0
    }

    // MARK: - Load

    func loadEverything() async throws -> PersistedBotState {
        var state = PersistedBotState()

        state.users = try await map("select user_id, username, first_name, first_seen_at, seen_at from bot_user where user_id is not null") {
            UserRow(identity: UserIdentity(
                userID: Int(try $0["user_id"].decode(Int64.self)),
                username: try $0["username"].decode(String?.self),
                firstName: try $0["first_name"].decode(String?.self),
                seenAt: try $0["seen_at"].decode(Date.self),
                firstSeenAt: try $0["first_seen_at"].decode(Date.self)
            ))
        }

        state.contexts = try await map("select chat_id, thread_id, data from bot_chat_context") {
            ChatContextRow(
                key: ChatKey(
                    chatID: Int(try $0["chat_id"].decode(Int64.self)),
                    threadID: try $0["thread_id"].decode(Int64.self)
                ),
                snapshot: try $0["data"].decode(ChatContextSnapshot.self)
            )
        }

        state.tenants = try await map(
            """
            select user_key, owner_username, paid_until, default_model, default_role, default_history,
                   presets, licences, usage, notice_cycle_until, sent_notices,
                   winback_percent, winback_expires_at, reminders_opt_out, created_at
              from bot_tenant
            """
        ) { row in
            let presets = try row["presets"].decode(TenantPresetsDocument.self)
            let licences = try row["licences"].decode(TenantLicencesDocument.self)
            var discount: SubscriptionDiscount?
            if let percent = try row["winback_percent"].decode(Int?.self),
               let expires = try row["winback_expires_at"].decode(Date?.self) {
                discount = SubscriptionDiscount(percent: percent, expiresAt: expires)
            }
            return TenantRow(key: try row["user_key"].decode(UserKey.self), snapshot: TenantStateSnapshot(
                ownerKey: try row["owner_username"].decode(UserKey.self),
                defaultModel: try row["default_model"].decode(String.self),
                defaultRole: try row["default_role"].decode(String.self),
                defaultHistoryLength: try row["default_history"].decode(Int.self),
                modelPresets: presets.model,
                tempPresets: presets.temp,
                historyLengthPresets: presets.history,
                rolePresets: presets.role,
                whitelistedUserIDs: licences.whitelistedUserIDs,
                adminKeys: licences.admins,
                licensedKeys: licences.licensed,
                cumulativeUsage: try row["usage"].decode(CumulativeUsage.self),
                createdAt: try row["created_at"].decode(Date.self),
                paidUntil: try row["paid_until"].decode(Date?.self),
                noticeCycleUntil: try row["notice_cycle_until"].decode(Date?.self),
                sentNotices: try row["sent_notices"].decode([String].self),
                winbackDiscount: discount,
                remindersOptOut: try row["reminders_opt_out"].decode(Bool.self)
            ))
        }

        state.chats = try await map("select chat_id, type, title, username, first_name, owner_key, bot_removed from bot_chat") { row in
            let type = try row["type"].decode(String?.self)
            let removed = try row["bot_removed"].decode(Bool.self)
            return ChatRow(
                chatID: Int(try row["chat_id"].decode(Int64.self)),
                meta: type.map {
                    ChatMetaInfo(
                        type: $0,
                        title: try? row["title"].decode(String?.self),
                        username: try? row["username"].decode(String?.self),
                        firstName: try? row["first_name"].decode(String?.self),
                        botRemoved: removed ? true : nil
                    )
                },
                ownerKey: try row["owner_key"].decode(UserKey?.self)
            )
        }

        state.invites = try await map("select token, owner_key, created_at from bot_invite") {
            InviteRow(
                token: try $0["token"].decode(String.self),
                record: InviteRecord(
                    ownerKey: try $0["owner_key"].decode(UserKey.self),
                    createdAt: try $0["created_at"].decode(Date.self)
                )
            )
        }

        state.premiumUsage = try await map("select subject, day, used from bot_premium_usage") {
            PremiumUsageRow(
                subject: try $0["subject"].decode(String.self),
                usage: DailyPremiumUsage(day: try $0["day"].decode(Int.self), used: try $0["used"].decode(Int.self))
            )
        }

        state.referrals = try await map("select invited_user_id, data from bot_referral") {
            ReferralRow(
                invitedUserID: Int(try $0["invited_user_id"].decode(Int64.self)),
                record: try $0["data"].decode(ReferralRecord.self)
            )
        }

        state.referralTallies = try await map("select inviter_user_id, data from bot_referral_tally") {
            ReferralTallyRow(
                inviterUserID: Int(try $0["inviter_user_id"].decode(Int64.self)),
                tally: try $0["data"].decode(ReferralTally.self)
            )
        }

        state.trafficAttributions = try await map(
            "select user_id, tag, joined_at, activated_at, paid_at, payments from bot_traffic_attribution"
        ) {
            TrafficAttributionRow(
                userID: Int(try $0["user_id"].decode(Int64.self)),
                attribution: TrafficSourceAttribution(
                    tag: try $0["tag"].decode(String.self),
                    joinedAt: try $0["joined_at"].decode(Date.self),
                    activatedAt: try $0["activated_at"].decode(Date?.self),
                    paidAt: try $0["paid_at"].decode(Date?.self),
                    payments: try $0["payments"].decode(Int.self)
                )
            )
        }

        let horizon = FunnelDailyLog.dayNumber() - FunnelDailyLog.windowDays
        state.funnelDays = try await map("select day, event, count from bot_funnel_daily where day >= \(horizon)") {
            FunnelDayRow(
                day: try $0["day"].decode(Int.self),
                event: try $0["event"].decode(String.self),
                count: Int(try $0["count"].decode(Int64.self))
            )
        }

        state.cryptoInvoices = try await map("select data from bot_crypto_invoice") {
            CryptoInvoiceRow(invoice: try $0["data"].decode(CryptoInvoice.self))
        }

        state.externalOrders = try await map("select data from bot_external_order") {
            ExternalOrderRow(order: try $0["data"].decode(ExternalPaymentOrder.self))
        }

        let wallets = try await map(
            """
            select user_key, balance_nanos, topped_up_nanos, spent_billed_nanos, spent_real_nanos,
                   lapsed_notice_at, updated_at
              from bot_wallet
            """
        ) { row in
            (
                key: try row["user_key"].decode(UserKey.self),
                wallet: UserBalance(
                    balance: .nanos(try row["balance_nanos"].decode(Int64.self)),
                    spentBilled: .nanos(try row["spent_billed_nanos"].decode(Int64.self)),
                    spentReal: .nanos(try row["spent_real_nanos"].decode(Int64.self)),
                    updatedAt: try row["updated_at"].decode(Date.self),
                    toppedUp: .nanos(try row["topped_up_nanos"].decode(Int64.self)),
                    lapsedNoticeAt: try row["lapsed_notice_at"].decode(Date?.self)
                )
            )
        }
        var walletsByKey: [UserKey: UserBalance] = [:]
        for row in wallets { walletsByKey[row.key] = row.wallet }
        state.wallets = walletsByKey

        state.configs = try await loadConfigs()
        return state
    }

    /// Deletes conversations nobody has touched in `idleDays`, except the chats
    /// named. Returns what went, so the cache drops the same rows.
    ///
    /// `not (chat_id = any($2))` rather than a list built in Swift: the
    /// protected set is a bind parameter like everything else, so it cannot
    /// become SQL however long it grows.
    func pruneChatContexts(idleDays: Int, protecting: Set<Int>) async throws -> [ChatKey] {
        guard idleDays > 0 else { return [] }
        let cutoff = Date().addingTimeInterval(-Double(idleDays) * 86_400)
        let keep = protecting.map(Int64.init)
        return try await map(
            """
            delete from bot_chat_context
             where updated_at < \(cutoff)
               and not (chat_id = any(\(keep)))
            returning chat_id, thread_id
            """
        ) {
            ChatKey(
                chatID: Int(try $0["chat_id"].decode(Int64.self)),
                threadID: try $0["thread_id"].decode(Int64.self)
            )
        }
    }

    /// Runs a query and maps each row by column name. Names, not tuple
    /// positions: a `select` list is edited far more often than it is read, and
    /// a positional decode turns a reordered column into a runtime type error
    /// somewhere else entirely.
    private func map<T>(_ query: PostgresQuery, _ transform: (PostgresRandomAccessRow) throws -> T) async throws -> [T] {
        let rows = try await client.query(query, logger: queryLogger)
        var result: [T] = []
        for try await row in rows {
            result.append(try transform(PostgresRandomAccessRow(row)))
        }
        return result
    }

    private func loadConfigs() async throws -> PersistedGlobalConfigs {
        var documents: [String: Data] = [:]
        for entry in try await map("select key, data::text as json from bot_config", {
            (key: try $0["key"].decode(String.self), json: try $0["json"].decode(String.self))
        }) {
            documents[entry.key] = Data(entry.json.utf8)
        }

        let decoder = JSONDecoder()
        func value<T: Decodable>(_ key: GlobalConfigKey, as type: T.Type) -> T? {
            guard let data = documents[key.rawValue] else { return nil }
            do {
                return try decoder.decode(ConfigDocument<T>.self, from: data).value
            } catch {
                // One unreadable document must not stop the bot from starting;
                // it falls back to its default and says which one it was.
                logger.error("config \(key.rawValue) could not be decoded, using the default: \(error)")
                return nil
            }
        }

        var configs = PersistedGlobalConfigs()
        configs.starsPrice = value(.starsPrice, as: Int.self)
        configs.starsPerUsd = value(.starsPerUsd, as: Int.self)
        configs.freeModelIDs = value(.freeModels, as: [String].self)
        configs.crypto = value(.crypto, as: CryptoConfigSnapshot.self)
        configs.card = value(.card, as: CardPaymentConfig.self)
        configs.superAdmins = value(.superAdmins, as: [UserKey].self)
        configs.pollingOffset = value(.pollingOffset, as: Int.self)
        configs.ads = value(.ads, as: [AdCampaign].self)
        configs.markup = value(.markup, as: Int.self)
        configs.funnel = value(.funnel, as: [String: Int].self)
        configs.dailyPremiumLimit = value(.dailyPremiumLimit, as: Int.self)
        configs.selfPromo = value(.selfPromo, as: SelfPromoConfig.self)
        configs.modes = value(.modes, as: ModePresetConfig.self)
        configs.reminders = value(.reminders, as: SubscriptionReminderConfig.self)
        configs.onboarding = value(.onboarding, as: OnboardingConfig.self)
        configs.referrals = value(.referrals, as: ReferralConfig.self)
        configs.referralTotals = value(.referralTotals, as: ReferralTotals.self)
        configs.trafficTotals = value(.trafficTotals, as: TrafficSourceTotals.self)
        configs.externalPayments = value(.externalPayments, as: ExternalPaymentConfig.self)
        configs.spendPolicy = value(.spendPolicy, as: SpendPolicy.self)
        return configs
    }

    // MARK: - Apply

    /// One write-behind batch inside one transaction. It is not the money
    /// transaction (that is `PostgresLedger`), but it costs nothing here and it
    /// makes a flush all-or-nothing: a retry never has to reason about which
    /// half of the previous attempt landed.
    func apply(_ batch: PersistenceBatch) async throws {
        guard !batch.isEmpty else { return }
        let log = queryLogger
        try await client.withTransaction(logger: log) { db in
            // Deletes first, so "delete then re-create" inside one batch ends
            // created rather than deleted.
            for key in batch.deletedContexts {
                try await db.query(
                    "delete from bot_chat_context where chat_id = \(Int64(key.chatID)) and thread_id = \(key.threadID)",
                    logger: log
                )
            }
            for key in batch.deletedTenants {
                try await db.query("delete from bot_tenant where user_key = \(key)", logger: log)
            }
            for chatID in batch.deletedChats {
                try await db.query("delete from bot_chat where chat_id = \(Int64(chatID))", logger: log)
            }
            for token in batch.deletedInvites {
                try await db.query("delete from bot_invite where token = \(token)", logger: log)
            }
            for subject in batch.deletedPremiumUsage {
                try await db.query("delete from bot_premium_usage where subject = \(subject)", logger: log)
            }
            for userID in batch.deletedReferrals {
                try await db.query("delete from bot_referral where invited_user_id = \(Int64(userID))", logger: log)
            }
            for userID in batch.deletedReferralTallies {
                try await db.query("delete from bot_referral_tally where inviter_user_id = \(Int64(userID))", logger: log)
            }
            for userID in batch.deletedTrafficAttributions {
                try await db.query("delete from bot_traffic_attribution where user_id = \(Int64(userID))", logger: log)
            }
            for id in batch.deletedCryptoInvoices {
                try await db.query("delete from bot_crypto_invoice where id = \(id)", logger: log)
            }
            for id in batch.deletedExternalOrders {
                try await db.query("delete from bot_external_order where id = \(id)", logger: log)
            }

            for row in batch.users {
                let identity = row.identity
                try await db.query(
                    """
                    insert into bot_user (user_key, user_id, username, first_name, first_seen_at, seen_at)
                    values (\(UserKey.identified(identity.userID)), \(Int64(identity.userID)), \(identity.username),
                            \(identity.firstName), \(identity.firstSeenAt ?? identity.seenAt), \(identity.seenAt))
                    on conflict (user_key) do update set
                        user_id = excluded.user_id,
                        username = excluded.username,
                        first_name = excluded.first_name,
                        first_seen_at = least(bot_user.first_seen_at, excluded.first_seen_at),
                        seen_at = greatest(bot_user.seen_at, excluded.seen_at)
                    """,
                    logger: log
                )
            }

            for row in batch.contexts {
                try await db.query(
                    """
                    insert into bot_chat_context (chat_id, thread_id, data, updated_at)
                    values (\(Int64(row.key.chatID)), \(row.key.threadID), \(row.snapshot), now())
                    on conflict (chat_id, thread_id) do update set
                        data = excluded.data, updated_at = excluded.updated_at
                    """,
                    logger: log
                )
            }

            for row in batch.tenants {
                let snapshot = row.snapshot
                let presets = TenantPresetsDocument(
                    model: snapshot.modelPresets,
                    temp: snapshot.tempPresets,
                    history: snapshot.historyLengthPresets,
                    role: snapshot.rolePresets
                )
                let licences = TenantLicencesDocument(
                    whitelistedUserIDs: snapshot.whitelistedUserIDs,
                    admins: snapshot.adminKeys,
                    licensed: snapshot.licensedKeys ?? []
                )
                // `paid_until` and the winback discount are absent from the
                // update list on purpose: they belong to the money transaction
                // (`PostgresLedger`), and a write-behind flush carrying a stale
                // copy would undo a renewal that has already been paid for.
                // They are still in the INSERT so a tenant created here starts
                // with the right dates.
                try await db.query(
                    """
                    insert into bot_tenant (
                        user_key, owner_username, paid_until, default_model, default_role, default_history,
                        presets, licences, usage, notice_cycle_until, sent_notices,
                        winback_percent, winback_expires_at, reminders_opt_out, created_at, updated_at
                    ) values (
                        \(row.key), \(snapshot.ownerKey), \(snapshot.paidUntil), \(snapshot.defaultModel),
                        \(snapshot.defaultRole), \(snapshot.defaultHistoryLength),
                        \(presets), \(licences), \(snapshot.cumulativeUsage ?? .zero),
                        \(snapshot.noticeCycleUntil), \(snapshot.sentNotices ?? []),
                        \(snapshot.winbackDiscount?.percent), \(snapshot.winbackDiscount?.expiresAt),
                        \(snapshot.remindersOptOut ?? false), \(snapshot.createdAt ?? Date()), now()
                    )
                    on conflict (user_key) do update set
                        owner_username = excluded.owner_username,
                        default_model = excluded.default_model,
                        default_role = excluded.default_role,
                        default_history = excluded.default_history,
                        presets = excluded.presets,
                        licences = excluded.licences,
                        usage = excluded.usage,
                        notice_cycle_until = excluded.notice_cycle_until,
                        sent_notices = excluded.sent_notices,
                        reminders_opt_out = excluded.reminders_opt_out,
                        updated_at = excluded.updated_at
                    """,
                    logger: log
                )
            }

            for row in batch.chats {
                try await db.query(
                    """
                    insert into bot_chat (chat_id, type, title, username, first_name, owner_key, bot_removed, updated_at)
                    values (\(Int64(row.chatID)), \(row.meta?.type), \(row.meta?.title), \(row.meta?.username),
                            \(row.meta?.firstName), \(row.ownerKey), \(row.meta?.botRemoved ?? false), now())
                    on conflict (chat_id) do update set
                        type = coalesce(excluded.type, bot_chat.type),
                        title = excluded.title,
                        username = excluded.username,
                        first_name = excluded.first_name,
                        owner_key = excluded.owner_key,
                        bot_removed = excluded.bot_removed,
                        updated_at = excluded.updated_at
                    """,
                    logger: log
                )
            }

            for row in batch.invites {
                try await db.query(
                    """
                    insert into bot_invite (token, owner_key, created_at)
                    values (\(row.token), \(row.record.ownerKey), \(row.record.createdAt))
                    on conflict (token) do update set owner_key = excluded.owner_key
                    """,
                    logger: log
                )
            }

            for row in batch.premiumUsage {
                try await db.query(
                    """
                    insert into bot_premium_usage (subject, day, used)
                    values (\(row.subject), \(row.usage.day), \(row.usage.used))
                    on conflict (subject) do update set day = excluded.day, used = excluded.used
                    """,
                    logger: log
                )
            }

            for row in batch.referrals {
                try await db.query(
                    """
                    insert into bot_referral (invited_user_id, inviter_user_id, bound_at, rewarded_at, paid_bonus_at, data)
                    values (\(Int64(row.invitedUserID)), \(Int64(row.record.inviterUserID)), \(row.record.boundAt),
                            \(row.record.rewardedAt), \(row.record.paidBonusAt), \(row.record))
                    on conflict (invited_user_id) do update set
                        inviter_user_id = excluded.inviter_user_id,
                        rewarded_at = excluded.rewarded_at,
                        paid_bonus_at = excluded.paid_bonus_at,
                        data = excluded.data
                    """,
                    logger: log
                )
            }

            for row in batch.referralTallies {
                try await db.query(
                    """
                    insert into bot_referral_tally (inviter_user_id, data)
                    values (\(Int64(row.inviterUserID)), \(row.tally))
                    on conflict (inviter_user_id) do update set data = excluded.data
                    """,
                    logger: log
                )
            }

            for row in batch.trafficAttributions {
                let attribution = row.attribution
                try await db.query(
                    """
                    insert into bot_traffic_attribution (user_id, tag, joined_at, activated_at, paid_at, payments)
                    values (\(Int64(row.userID)), \(attribution.tag), \(attribution.joinedAt),
                            \(attribution.activatedAt), \(attribution.paidAt), \(attribution.payments))
                    on conflict (user_id) do update set
                        activated_at = excluded.activated_at,
                        paid_at = excluded.paid_at,
                        payments = excluded.payments
                    """,
                    logger: log
                )
            }

            for row in batch.funnelDays {
                try await db.query(
                    """
                    insert into bot_funnel_daily (day, event, count)
                    values (\(row.day), \(row.event), \(Int64(row.count)))
                    on conflict (day, event) do update set count = excluded.count
                    """,
                    logger: log
                )
            }

            for row in batch.cryptoInvoices {
                let invoice = row.invoice
                try await db.query(
                    """
                    insert into bot_crypto_invoice (id, owner_key, status, expires_at, data)
                    values (\(invoice.id), \(invoice.ownerKey.storageValue), \(invoice.status.rawValue), \(invoice.expiresAt), \(invoice))
                    on conflict (id) do update set
                        status = excluded.status, expires_at = excluded.expires_at, data = excluded.data
                    """,
                    logger: log
                )
            }

            for row in batch.externalOrders {
                let order = row.order
                try await db.query(
                    """
                    insert into bot_external_order (id, payer_key, status, expires_at, vendor_payment_id, data)
                    values (\(order.id), \(order.payerKey), \(order.status.rawValue), \(order.expiresAt),
                            \(order.vendorPaymentID), \(order))
                    on conflict (id) do update set
                        status = excluded.status,
                        expires_at = excluded.expires_at,
                        vendor_payment_id = excluded.vendor_payment_id,
                        data = excluded.data
                    """,
                    logger: log
                )
            }

            for config in batch.configs {
                try await db.query(
                    """
                    insert into bot_config (key, data, updated_at)
                    values (\(config.key.rawValue), \(ConfigEnvelope(value: config)), now())
                    on conflict (key) do update set data = excluded.data, updated_at = excluded.updated_at
                    """,
                    logger: log
                )
            }
        }
    }
}

// MARK: - Documents stored inside table rows

/// The four preset sets of a tenant. Always read and written together and never
/// searched inside — a document, and therefore one `jsonb` column.
///
/// The decoder is hand-written because Swift's synthesised one **ignores
/// property defaults** and throws on a missing key. The column's default is
/// `'{}'`, and a row created by the payment path (which only fills the columns
/// a payment knows about) would otherwise be unreadable — taking the whole
/// restore down with it and dropping the bot into memory-only mode.
struct TenantPresetsDocument: Codable, Sendable, PostgresCodable {
    var model: [Preset] = []
    var temp: [Preset] = []
    var history: [Preset] = []
    var role: [Preset] = []

    init(model: [Preset] = [], temp: [Preset] = [], history: [Preset] = [], role: [Preset] = []) {
        self.model = model
        self.temp = temp
        self.history = history
        self.role = role
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decodeIfPresent([Preset].self, forKey: .model) ?? []
        temp = try c.decodeIfPresent([Preset].self, forKey: .temp) ?? []
        history = try c.decodeIfPresent([Preset].self, forKey: .history) ?? []
        role = try c.decodeIfPresent([Preset].self, forKey: .role) ?? []
    }
}

/// Who a tenant's licence covers. Same reason for the hand-written decoder.
struct TenantLicencesDocument: Codable, Sendable, PostgresCodable {
    var whitelistedUserIDs: [Int] = []
    var admins: [UserKey] = []
    var licensed: [UserKey] = []

    init(whitelistedUserIDs: [Int] = [], admins: [UserKey] = [], licensed: [UserKey] = []) {
        self.whitelistedUserIDs = whitelistedUserIDs
        self.admins = admins
        self.licensed = licensed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        whitelistedUserIDs = try c.decodeIfPresent([Int].self, forKey: .whitelistedUserIDs) ?? []
        admins = try c.decodeIfPresent([UserKey].self, forKey: .admins) ?? []
        licensed = try c.decodeIfPresent([UserKey].self, forKey: .licensed) ?? []
    }
}

/// `bot_config.data` is always a JSON object, whatever the payload type — a
/// bare `7` is legal `jsonb` but makes the column impossible to read uniformly.
struct ConfigEnvelope<Value: Encodable & Sendable>: Encodable, Sendable, PostgresEncodable {
    let value: Value
}

/// The read side. Separate from `ConfigEnvelope` because writing goes through
/// the `GlobalConfigValue` enum (encode-only) while reading resolves the one
/// concrete type that knows what the JSON means.
private struct ConfigDocument<Value: Decodable>: Decodable {
    let value: Value
}

/// Serialising a config value is the one place the enum's associated values
/// reach the database. The switch is exhaustive, so a new key cannot be stored
/// as nothing — the compiler asks for its line. There is no decode side: a
/// config row is read into its own concrete type.
extension GlobalConfigValue: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .starsPrice(let value): try container.encode(value)
        case .starsPerUsd(let value): try container.encode(value)
        case .freeModels(let value): try container.encode(value)
        case .crypto(let value): try container.encode(value)
        case .card(let value): try container.encode(value)
        case .superAdmins(let value): try container.encode(value)
        case .pollingOffset(let value): try container.encode(value)
        case .ads(let value): try container.encode(value)
        case .markup(let value): try container.encode(value)
        case .funnel(let value): try container.encode(value)
        case .dailyPremiumLimit(let value): try container.encode(value)
        case .selfPromo(let value): try container.encode(value)
        case .modes(let value): try container.encode(value)
        case .reminders(let value): try container.encode(value)
        case .onboarding(let value): try container.encode(value)
        case .referrals(let value): try container.encode(value)
        case .referralTotals(let value): try container.encode(value)
        case .trafficTotals(let value): try container.encode(value)
        case .externalPayments(let value): try container.encode(value)
        case .spendPolicy(let value): try container.encode(value)
        }
    }
}

// MARK: - Column bridges

/// `UserKey` is a `text` column, not a document: the whole schema is keyed on
/// it (`bot_wallet`, `bot_tenant`, `bot_chat.owner_key`, …).
///
/// The bridge lives here rather than on the type so the domain keeps no
/// knowledge of the driver — and reading is deliberately total
/// (`init(storageValue:)` sanitises rather than throws), because one malformed
/// key must not take a whole restore down with it and drop the bot into the
/// memory-only mode where it stops selling (§10.6).
extension UserKey: PostgresEncodable, PostgresDecodable {
    static var psqlType: PostgresDataType { String.psqlType }
    static var psqlFormat: PostgresFormat { String.psqlFormat }

    func encode(into byteBuffer: inout ByteBuffer, context: PostgresEncodingContext<some PostgresJSONEncoder>) throws {
        try storageValue.encode(into: &byteBuffer, context: context)
    }

    init(
        from buffer: inout ByteBuffer,
        type: PostgresDataType,
        format: PostgresFormat,
        context: PostgresDecodingContext<some PostgresJSONDecoder>
    ) throws {
        self.init(storageValue: try String(from: &buffer, type: type, format: format, context: context))
    }
}

// MARK: - jsonb payloads

extension ChatContextSnapshot: PostgresCodable {}
extension CumulativeUsage: PostgresCodable {}
extension ReferralRecord: PostgresCodable {}
extension ReferralTally: PostgresCodable {}
extension CryptoInvoice: PostgresCodable {}
extension ExternalPaymentOrder: PostgresCodable {}
