import XCTest
import Logging
import PostgresNIO
@testable import LLM_chat_bot

/// The only tests that touch a real database, and the only way to check the
/// three things that exist *because* it is a real database: the schema applies,
/// the constraints hold, and a transaction is a transaction.
///
/// Skipped unless `TEST_DATABASE_URL` is set, so the normal `swift test` stays
/// offline and fast:
///
/// ```
/// docker run -d --rm --name pg -e POSTGRES_PASSWORD=test -e POSTGRES_DB=botdb -p 55432:5432 postgres:16-alpine
/// TEST_DATABASE_URL='postgres://postgres:test@127.0.0.1:55432/botdb?sslmode=disable' swift test
/// ```
final class PostgresIntegrationTests: XCTestCase {
    private var client: PostgresClient!
    private var runner: Task<Void, Never>!
    private var persistence: PostgresStatePersistence!
    private var ledger: PostgresLedger!

    override func setUp() async throws {
        guard let url = ProcessInfo.processInfo.environment["TEST_DATABASE_URL"],
              let endpoint = DatabaseEndpoint(urlString: url) else {
            throw XCTSkip("set TEST_DATABASE_URL to run the database tests")
        }
        client = PostgresClient(
            configuration: try endpoint.clientConfiguration(maximumConnections: 4),
            backgroundLogger: Logger(label: "test") { _ in SwiftLogNoOpLogHandler() }
        )
        let client = self.client!
        runner = Task { await client.run() }

        persistence = PostgresStatePersistence(client: client, logger: SilentLogger())
        ledger = PostgresLedger(client: client, logger: SilentLogger())
        try await dropEverything()
        try await persistence.migrate()
    }

    override func tearDown() async throws {
        runner?.cancel()
        runner = nil
        client = nil
        persistence = nil
        ledger = nil
    }

    private func dropEverything() async throws {
        // A fresh schema per test class: these tests assert about counts, and a
        // leftover row from a previous run is a false failure nobody enjoys.
        for table in [
            "bot_ledger", "bot_payment", "bot_wallet", "bot_chat_context", "bot_chat",
            "bot_invite", "bot_premium_usage", "bot_referral", "bot_referral_tally",
            "bot_traffic_attribution", "bot_funnel_daily", "bot_crypto_invoice",
            "bot_external_order", "bot_tenant", "bot_user", "bot_config", "bot_schema_meta",
        ] {
            try await client.query(PostgresQuery(unsafeSQL: "drop table if exists \(table) cascade"))
        }
    }

    // MARK: - Schema

    func testMigrationIsIdempotentAndRecordsItsVersion() async throws {
        try await persistence.migrate()
        let rows = try await client.query("select version from bot_schema_meta where id = 1")
        var version = 0
        for try await row in rows { version = try PostgresRandomAccessRow(row)["version"].decode(Int.self) }
        XCTAssertEqual(version, PostgresSchema.version)
    }

    /// An older binary must not write into a newer schema — it would drop
    /// whatever the new columns hold, silently.
    func testABinaryOlderThanTheSchemaRefusesToStart() async throws {
        try await client.query(
            "update bot_schema_meta set version = \(PostgresSchema.version + 5) where id = 1"
        )
        do {
            try await persistence.migrate()
            XCTFail("a newer schema must stop an older build")
        } catch let error as PostgresSchemaError {
            guard case .databaseNewerThanBinary = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    // MARK: - Money

    /// The constraint that makes "wallet in the red" unrepresentable, rather
    /// than merely unlikely.
    func testTheDatabaseRefusesANegativeBalance() async throws {
        do {
            try await client.query(
                "insert into bot_wallet (user_key, balance_nanos) values ('#1', -1)"
            )
            XCTFail("check (balance_nanos >= 0) did not hold")
        } catch {
            // Expected: the check constraint rejected it.
        }
    }

    func testPaymentIsClaimedExactlyOnceAcrossConcurrentDeliveries() async throws {
        let receipt = PaymentReceipt(
            payerKey: UserKey.identified(42), payerUserID: 42, chatID: 42,
            purpose: .subscription, idempotencyKey: "charge-x", method: .stars
        )
        let ledger = self.ledger!

        let winners = await withTaskGroup(of: Bool.self) { group -> Int in
            for _ in 0..<8 {
                group.addTask {
                    (try? await ledger.inTransaction { try await $0.claimPayment(receipt) }) ?? false
                }
            }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        XCTAssertEqual(winners, 1)
    }

    /// A transaction is all-or-nothing: a throw after the claim must leave the
    /// claim untaken, or a redelivery would find the payment "processed" and
    /// the person with nothing.
    func testAFailedTransactionLeavesNoTrace() async throws {
        struct Boom: Error {}
        let receipt = PaymentReceipt(
            payerKey: UserKey.identified(43), payerUserID: 43, chatID: 43,
            purpose: .credit(cents: 500), idempotencyKey: "charge-y", method: .card
        )
        do {
            try await ledger.inTransaction { transaction in
                _ = try await transaction.claimPayment(receipt)
                _ = try await transaction.credit(UserKey.identified(43), .cents(500), kind: .topup, purchased: true, ref: nil)
                throw Boom()
            }
            XCTFail("the transaction should have thrown")
        } catch {
            // The driver wraps the closure's error in a transaction error; what
            // matters is that it rolled back, which the assertions below check.
        }

        let wallets = try await persistence.loadEverything().wallets
        XCTAssertNil(wallets[UserKey.identified(43)], "a rolled-back credit must not exist")
        let claimedAgain = try await ledger.inTransaction { try await $0.claimPayment(receipt) }
        XCTAssertTrue(claimedAgain, "a rolled-back claim must be available to the redelivery")
    }

    func testDebitStopsAtZeroAndTheJournalAddsUp() async throws {
        _ = try await ledger.inTransaction {
            try await $0.credit(UserKey.identified(44), .cents(10), kind: .topup, purchased: true, ref: "top")
        }
        let debit = try await ledger.inTransaction {
            try await $0.debit(UserKey.identified(44), upTo: .cents(25), real: .cents(20), ref: "gen")
        }
        XCTAssertEqual(debit.charged, .cents(10))
        XCTAssertEqual(debit.remaining, .zero)
        XCTAssertTrue(debit.depleted)

        let mismatched = try await ledger.reconcile()
        XCTAssertTrue(mismatched.isEmpty, "journal and balance disagree for: \(mismatched)")
    }

    /// Two statements the ledger runs only against a real database: setting a
    /// balance to an exact amount, and closing a wallet's journal when the
    /// wallet is deleted.
    ///
    /// The second is what keeps `reconcile()` usable. The journal outlives the
    /// wallet on purpose, but it is summed from the beginning — so a key funded
    /// again after a deletion inherited the old rows and was reported corrupt
    /// forever, an alert about somebody's money that no one could clear.
    func testASetBalanceAndADeletedWalletBothKeepTheJournalHonest() async throws {
        let key = UserKey.identified(47)
        _ = try await ledger.inTransaction {
            try await $0.credit(key, .cents(300), kind: .topup, purchased: true, ref: "top")
        }
        let set = try await ledger.inTransaction { try await $0.setBalance(key, to: .cents(75), ref: "set") }
        XCTAssertEqual(set.balance, .cents(75))
        XCTAssertEqual(set.toppedUp, .cents(300), "a correction is not a refund of the top-up")
        var mismatched = try await ledger.reconcile()
        XCTAssertTrue(mismatched.isEmpty, "a balance that was set must still be explainable: \(mismatched)")

        // Super-admin deletes the wallet; the person comes back and tops up.
        try await ledger.syncWallets(changed: [:], removed: [key])
        _ = try await ledger.inTransaction {
            try await $0.credit(key, .cents(100), kind: .topup, purchased: true, ref: "top-again")
        }
        mismatched = try await ledger.reconcile()
        XCTAssertTrue(mismatched.isEmpty, "a recreated wallet must not inherit the old journal: \(mismatched)")

        // And the history is still there — the closing line explains where the
        // deleted balance went instead of erasing the evidence.
        let entries = try await ledger.recentEntries(userKey: key, limit: 10)
        XCTAssertEqual(entries.count, 4, "top-up, correction, closing line, top-up")
    }

    /// Paying never shortens access, and the end date is computed by the
    /// database so two renewals cannot read the same one.
    func testRenewalExtendsFromTheCurrentEnd() async throws {
        let defaults = TenantDefaults(ownerKey: UserKey.identified(45), model: "m", role: "r", historyLength: 10)
        let first = try await ledger.inTransaction {
            try await $0.extendSubscription(UserKey.identified(45), days: 30, defaults: defaults)
        }
        XCTAssertTrue(first.isNew)
        let second = try await ledger.inTransaction {
            try await $0.extendSubscription(UserKey.identified(45), days: 30, defaults: defaults)
        }
        XCTAssertFalse(second.isNew)
        let gap = second.paidUntil!.timeIntervalSince(first.paidUntil!)
        XCTAssertEqual(gap, 30 * 86_400, accuracy: 60)

        try await ledger.inTransaction { try await $0.setSubscription(UserKey.identified(45), paidUntil: nil) }
        let third = try await ledger.inTransaction {
            try await $0.extendSubscription(UserKey.identified(45), days: 30, defaults: defaults)
        }
        XCTAssertNil(third.paidUntil, "unlimited stays unlimited")
        XCTAssertTrue(third.wasUnlimited)
    }

    /// A payment creates the tenant row, filling only the columns a payment
    /// knows about — the rest take their column defaults. Those defaults are
    /// `'{}'::jsonb`, and Swift's synthesised `Decodable` **ignores property
    /// defaults**: a missing key throws. So a row created this way used to be
    /// unreadable, and one unreadable row took the whole restore down and
    /// dropped the bot into memory-only mode, where it stops selling.
    func testATenantCreatedByAPaymentCanBeReadBack() async throws {
        let defaults = TenantDefaults(ownerKey: UserKey.identified(46), model: "m/model", role: "роль", historyLength: 12)
        _ = try await ledger.inTransaction {
            try await $0.extendSubscription(UserKey.identified(46), days: 30, defaults: defaults)
        }

        let stored = try await persistence.loadEverything()
        guard let tenant = stored.tenants.first(where: { $0.key == UserKey.identified(46) }) else {
            return XCTFail("the tenant a payment created is missing")
        }
        XCTAssertEqual(tenant.snapshot.defaultModel, "m/model")
        XCTAssertTrue(tenant.snapshot.modelPresets.isEmpty)
        XCTAssertTrue(tenant.snapshot.adminKeys.isEmpty)
        XCTAssertEqual(tenant.snapshot.cumulativeUsage, .zero)
        XCTAssertNotNil(tenant.snapshot.paidUntil)

        // And the store has to accept it.
        let store = Fixtures.makeStore()
        await store.restore(from: stored)
        let subscription = await store.tenantSubscription(ownerKey: UserKey.identified(46))
        XCTAssertTrue(subscription.isActive)
    }

    /// Write-behind must never carry a stale subscription date back over one a
    /// payment just committed. `paid_until` and the winback discount belong to
    /// the money transaction, so they are deliberately absent from the columns
    /// a flush updates — this is what proves it.
    func testWriteBehindDoesNotUndoAPaidRenewal() async throws {
        let key = UserKey.identified(47)
        // The payment path creates the tenant with a real end date.
        let extended = try await ledger.inTransaction {
            try await $0.extendSubscription(
                key, days: 30,
                defaults: TenantDefaults(ownerKey: key, model: "m", role: "r", historyLength: 10)
            )
        }
        let paidUntil = try XCTUnwrap(extended.paidUntil)

        // A process that then loads that state and edits something unrelated…
        let store = Fixtures.makeStore()
        await store.restore(from: try await persistence.loadEverything())
        _ = await store.assignChat(chatID: -47, to: key)
        _ = await store.setDefaultRole("новая роль", chatID: -47)
        try await persistence.apply(await store.drainDirtyBatch())

        let reloaded = try await persistence.loadEverything()
        let tenant = try XCTUnwrap(reloaded.tenants.first { $0.key == key })
        XCTAssertEqual(tenant.snapshot.defaultRole, "новая роль")
        XCTAssertEqual(
            tenant.snapshot.paidUntil?.timeIntervalSince1970 ?? 0,
            paidUntil.timeIntervalSince1970,
            accuracy: 1,
            "a flush must not undo a paid renewal"
        )
    }

    /// A tenant a super-admin created by hand is open-ended, and paying must
    /// not turn that into a 30-day countdown — "оплата никогда не сокращает
    /// срок" applies to unlimited access too.
    func testPayingAnUnlimitedTenantLeavesThemUnlimited() async throws {
        let store = Fixtures.makeStore()
        await store.identifyUser(userID: 48, username: "granted", firstName: nil)
        let key = UserKey.identified(48)
        await store.registerTenant(key)
        try await persistence.apply(await store.drainDirtyBatch())

        let extended = try await ledger.inTransaction {
            try await $0.extendSubscription(
                key, days: 30,
                defaults: TenantDefaults(ownerKey: key, model: "m", role: "r", historyLength: 10)
            )
        }
        XCTAssertTrue(extended.wasUnlimited)
        XCTAssertNil(extended.paidUntil)

        let stored = try await persistence.loadEverything()
        let tenant = try XCTUnwrap(stored.tenants.first { $0.key == key })
        XCTAssertNil(tenant.snapshot.paidUntil, "an open-ended tenant must stay open-ended")
    }

    /// A super-admin extending, granting or ending a subscription changes
    /// columns the write-behind flush never writes. Without `SubscriptionWriter`
    /// those edits were correct in memory and gone after the next restart —
    /// which is exactly the shape of bug nobody notices until a customer does.
    func testSuperAdminSubscriptionEditsSurviveARestart() async throws {
        let store = Fixtures.makeStore()
        let writer = SubscriptionWriter(
            state: store, ledger: ledger, logger: SilentLogger(), alerter: nil
        )
        await store.identifyUser(userID: 60, username: "granted", firstName: nil)
        let key = UserKey.identified(60)
        await store.registerTenant(key)
        try await persistence.apply(await store.drainDirtyBatch())

        // `registerTenant` opens an open-ended one, and adding days to that is
        // refused (it would swap unlimited access for an end date), so the
        // term is put there by ending it first — which is also the order the
        // super-admin page offers the two buttons in.
        let expired = await writer.expire(key: key)
        XCTAssertTrue(expired)
        var reloaded = Fixtures.makeStore()
        await reloaded.restore(from: try await persistence.loadEverything())
        var subscription = await reloaded.tenantSubscription(ownerKey: key)
        XCTAssertFalse(subscription.isActive, "an expiry has to outlive the process that made it")

        guard case .extended(let until) = await writer.extend(key: key, days: 30) else {
            return XCTFail("a sponsor with a term must be extendable")
        }
        reloaded = Fixtures.makeStore()
        await reloaded.restore(from: try await persistence.loadEverything())
        subscription = await reloaded.tenantSubscription(ownerKey: key)
        XCTAssertEqual(
            subscription.paidUntil?.timeIntervalSince1970 ?? 0,
            until.timeIntervalSince1970,
            accuracy: 1,
            "an extension has to outlive it too"
        )

        let unlimited = await writer.setUnlimited(key: key)
        XCTAssertTrue(unlimited)
        reloaded = Fixtures.makeStore()
        await reloaded.restore(from: try await persistence.loadEverything())
        subscription = await reloaded.tenantSubscription(ownerKey: key)
        XCTAssertNil(subscription.paidUntil)
        XCTAssertTrue(subscription.isActive)
    }

    /// The winback offer prices a purchase, so losing it on restart means the
    /// sweep grants a fresh one and the "истекает через 48 часов" deadline
    /// walks forward every hour — an urgency that never actually expires.
    func testAWinbackOfferSurvivesARestart() async throws {
        let store = Fixtures.makeStore()
        let writer = SubscriptionWriter(
            state: store, ledger: ledger, logger: SilentLogger(), alerter: nil
        )
        await store.identifyUser(userID: 61, username: "lapsed", firstName: nil)
        let key = UserKey.identified(61)
        await store.registerTenant(key)
        _ = await writer.extend(key: key, days: 30)
        try await persistence.apply(await store.drainDirtyBatch())

        let issued = await writer.grantWinback(key: key, percent: 30, hours: 48)
        let granted = try XCTUnwrap(issued)

        let reloaded = Fixtures.makeStore()
        await reloaded.restore(from: try await persistence.loadEverything())
        let discount = await reloaded.subscriptionDiscount(key: key)
        XCTAssertEqual(discount?.percent, granted.percent)
        XCTAssertEqual(
            discount?.expiresAt.timeIntervalSince1970 ?? 0,
            granted.expiresAt.timeIntervalSince1970,
            accuracy: 1,
            "the deadline must not restart with the process"
        )

        _ = await writer.consumeWinback(key: key)
        let after = Fixtures.makeStore()
        await after.restore(from: try await persistence.loadEverything())
        let consumed = await after.subscriptionDiscount(key: key)
        XCTAssertNil(consumed, "a one-shot offer must stay consumed")
    }

    // MARK: - Retention (§7.2)

    /// Idle conversations age out; a customer's never does. Sweeping a paying
    /// sponsor's group would be a downgrade of what they bought, and sweeping
    /// their DM would lose the context they pay to keep.
    func testRetentionDropsIdleChatsAndKeepsCustomers() async throws {
        let store = Fixtures.makeStore()
        await store.identifyUser(userID: 70, username: "sponsor", firstName: nil)
        let sponsor = UserKey.identified(70)
        await store.registerTenant(sponsor)
        _ = await store.assignChat(chatID: -70, to: sponsor)
        _ = try await ledger.inTransaction {
            try await $0.extendSubscription(
                sponsor, days: 30,
                defaults: TenantDefaults(ownerKey: sponsor, model: "m", role: "r", historyLength: 10)
            )
        }

        let stranger = ChatKey(chatID: 71, threadID: 0)
        let ownedGroup = ChatKey(chatID: -70, threadID: 0)
        let sponsorDM = ChatKey(chatID: 70, threadID: 0)
        for key in [stranger, ownedGroup, sponsorDM] {
            await store.setModelOnly(chatKey: key, model: "some/model")
        }
        try await persistence.apply(await store.drainDirtyBatch())

        // Nothing is old enough yet.
        var protectedKeys = await store.chatsWorthKeeping()
        var removed = try await persistence.pruneChatContexts(idleDays: 180, protecting: protectedKeys)
        XCTAssertTrue(removed.isEmpty)

        // Age every row past the horizon and sweep again.
        try await client.query("update bot_chat_context set updated_at = now() - interval '200 days'")
        // The store has to be reloaded so `chatsWorthKeeping` sees the
        // subscription the ledger wrote.
        let reloaded = Fixtures.makeStore()
        await reloaded.restore(from: try await persistence.loadEverything())
        protectedKeys = await reloaded.chatsWorthKeeping()
        removed = try await persistence.pruneChatContexts(idleDays: 180, protecting: protectedKeys)

        XCTAssertEqual(removed, [stranger], "only the chat nobody pays for goes")

        let left = try await persistence.loadEverything().contexts.map(\.key)
        XCTAssertTrue(left.contains(ownedGroup), "a sponsored group keeps its history")
        XCTAssertTrue(left.contains(sponsorDM), "so does the sponsor's own chat")
        XCTAssertFalse(left.contains(stranger))
    }

    /// `/forget` erases the conversation and nothing else: the wallet and the
    /// journal are the person's own evidence in a billing dispute.
    func testForgetErasesTheConversationButNotTheMoney() async throws {
        let store = Fixtures.makeStore()
        await store.identifyUser(userID: 72, username: "payer", firstName: nil)
        let key = UserKey.identified(72)
        let chat = ChatKey(chatID: 72, threadID: 0)
        await store.setModelOnly(chatKey: chat, model: "some/model")
        _ = try await ledger.inTransaction {
            try await $0.credit(key, .cents(500), kind: .topup, purchased: true, ref: "top")
        }
        try await persistence.apply(await store.drainDirtyBatch())

        let erased = await store.forgetChat(chatKey: chat)
        XCTAssertTrue(erased)
        try await persistence.apply(await store.drainDirtyBatch())

        let stored = try await persistence.loadEverything()
        XCTAssertFalse(stored.contexts.contains { $0.key == chat }, "the conversation is gone")
        XCTAssertEqual(stored.wallets[key]?.balance, .cents(500), "the money is not")
        let entries = try await ledger.recentEntries(userKey: key, limit: 10)
        XCTAssertEqual(entries.count, 1, "and neither is its journal")
    }

    // MARK: - Write-behind round trip

    /// Everything the store exports has to come back the way it went in — the
    /// class of bug where a value is written but never read, and silently
    /// reverts to its default on every restart.
    func testTheWholeStateSurvivesAFlushAndReload() async throws {
        let store = Fixtures.makeStore()
        await store.identifyUser(userID: 900, username: "sponsor", firstName: "S")
        _ = await store.registerTenant(UserKey.identified(900))
        await store.recordChatMeta(
            chatID: -900,
            info: ChatMetaInfo(type: "supergroup", title: "Команда", username: nil, firstName: nil)
        )
        _ = await store.assignChat(chatID: -900, to: UserKey.identified(900))
        await store.setMarkupPercent(42)
        await store.setDailyPremiumLimit(7)
        await store.setSpendPolicy(SpendPolicy(
            dailyGlobalCap: .cents(1000), dailyPerTenantCap: .cents(100), onTenantCap: .refuse
        ))
        await store.setModelOnly(chatKey: ChatKey(chatID: -900, threadID: 0), model: "some/model")
        await store.bumpFunnel(.paid)
        _ = await store.consumeDailyPremium(chatID: -900, userID: 900, isGroup: true)
        _ = await store.regenerateInviteToken(owner: UserKey.identified(900))

        try await persistence.apply(await store.drainDirtyBatch())

        let reloaded = Fixtures.makeStore()
        await reloaded.restore(from: try await persistence.loadEverything())

        let markup = await reloaded.markupPercent()
        XCTAssertEqual(markup, 42)
        let limit = await reloaded.dailyPremiumLimit()
        XCTAssertEqual(limit, 7)
        let policy = await reloaded.spendPolicy()
        XCTAssertEqual(policy.dailyGlobalCap, .cents(1000))
        XCTAssertEqual(policy.onTenantCap, .refuse)
        let owner = await reloaded.chatOwner(chatID: -900)
        XCTAssertEqual(owner, UserKey.identified(900))
        let label = await reloaded.chatDisplayLabel(chatID: -900)
        XCTAssertEqual(label, "Команда")
        let help = await reloaded.fetchHelp(chatKey: ChatKey(chatID: -900, threadID: 0))
        XCTAssertEqual(help.model, "some/model")
        let identity = await reloaded.displayLabel(forKey: UserKey.identified(900))
        XCTAssertEqual(identity, "@sponsor")
        let funnel = await reloaded.funnelReport()
        XCTAssertEqual(funnel.todayCounters[FunnelEvent.paid.rawValue], 1)
        let remaining = await reloaded.remainingDailyPremium(chatID: -900, userID: 900, isGroup: true)
        XCTAssertEqual(remaining.remaining, 6, "the spent allowance must not come back on restart")
        let token = await reloaded.inviteToken(owner: UserKey.identified(900))
        XCTAssertNotNil(token)
    }

    /// A delete must actually name its row. The old string-built filter had a
    /// comment warning that losing it empties the table; this proves the
    /// parameterised one cannot.
    func testDeletingOneTenantLeavesTheOthers() async throws {
        let store = Fixtures.makeStore()
        await store.identifyUser(userID: 901, username: "a", firstName: nil)
        await store.identifyUser(userID: 902, username: "b", firstName: nil)
        _ = await store.registerTenant(UserKey.identified(901))
        _ = await store.registerTenant(UserKey.identified(902))
        try await persistence.apply(await store.drainDirtyBatch())

        _ = await store.removeTenant(UserKey.identified(901))
        try await persistence.apply(await store.drainDirtyBatch())

        let tenants = try await persistence.loadEverything().tenants.map(\.key)
        XCTAssertFalse(tenants.contains(UserKey.identified(901)))
        XCTAssertTrue(tenants.contains(UserKey.identified(902)), "the other tenant must survive")
    }

    /// One document this build cannot read must not cost the bot its whole
    /// state — and with it the checkout, because a failed restore leaves the
    /// process memory-only and refusing to sell. Conversations are the one kind
    /// of row where skipping is right: the chat rebuilds it on its next
    /// message. Tenants and wallets stay strict.
    func testAnUnreadableConversationDoesNotTakeTheRestoreDown() async throws {
        let store = Fixtures.makeStore()
        await store.setModelOnly(chatKey: ChatKey(chatID: -910, threadID: 0), model: "good/model")
        try await persistence.apply(await store.drainDirtyBatch())

        // The shape a rollback to a build that predates a field produces.
        let broken = #"{"role":"only half a snapshot"}"#
        try await client.query(
            "insert into bot_chat_context (chat_id, thread_id, data) values (-911, 0, \(broken)::jsonb)"
        )

        let loaded = try await persistence.loadEverything()
        XCTAssertEqual(loaded.contexts.count, 1, "the readable conversation must still arrive")
        XCTAssertEqual(loaded.contexts.first?.key.chatID, ChatID(-910))
    }

    /// Only one process may write. This is the guarantee a lease with a TTL
    /// cannot give, and the reason the pooler must be in session mode.
    func testOnlyOneWriterLockIsGranted() async throws {
        let first = WriterLock(client: client, logger: SilentLogger())
        let second = WriterLock(client: client, logger: SilentLogger())

        let firstHolds = await first.acquire(onLost: {})
        XCTAssertTrue(firstHolds)
        let secondHolds = await second.acquire(onLost: {})
        XCTAssertFalse(secondHolds, "a second instance must not become a writer")

        await first.release()
        // The lock follows the connection, so it is free as soon as that
        // connection goes away — no expiry to wait out.
        var reacquired = false
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(200))
            reacquired = await second.acquire(onLost: {})
            if reacquired { break }
        }
        XCTAssertTrue(reacquired, "the lock must be free once the holder lets go")
        await second.release()
    }

    /// `onLost` means "the lock we were holding is gone" and nothing else. An
    /// instance waiting out a deploy retries every two seconds; if a losing
    /// attempt reported a lost lock, that callback would step the process down
    /// — possibly seconds after a later attempt made it the writer.
    func testALosingAttemptNeverReportsALostLock() async throws {
        let holder = WriterLock(client: client, logger: SilentLogger())
        let waiter = WriterLock(client: client, logger: SilentLogger())
        let reportedLost = LockedValue(false)

        let holds = await holder.acquire(onLost: {})
        XCTAssertTrue(holds)
        for _ in 0..<3 {
            let got = await waiter.acquire(onLost: { reportedLost.value = true })
            XCTAssertFalse(got, "the lock is taken")
        }
        // Long enough for the losing attempts' tails to run.
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(reportedLost.value, "failing to take the lock is not losing it")

        await holder.release()
    }
}
