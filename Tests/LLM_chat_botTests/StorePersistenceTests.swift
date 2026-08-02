import XCTest
@testable import LLM_chat_bot

/// Write-behind persistence: only what changed is written, a failed batch is
/// merged into the next one, and a restart rebuilds the same state.
final class StorePersistenceTests: XCTestCase {

    func testDrainReturnsOnlyChangedRowsAndClearsThem() async {
        let store = Fixtures.makeStore()
        let chat = ChatKey(chatID: 950, threadID: 0)
        _ = await store.drainDirtyBatch()   // whatever boot marked

        await store.setModelOnly(chatKey: chat, model: "a/model")
        await store.setMarkupPercent(40)

        let batch = await store.drainDirtyBatch()
        XCTAssertEqual(batch.contexts.map(\.key), [chat])
        XCTAssertTrue(batch.configs.contains { $0.name == .markup })

        let second = await store.drainDirtyBatch()
        XCTAssertTrue(second.isEmpty, "a drained change must not be written twice")
    }

    /// Every new mutation has to mark its dirty set, or it silently never
    /// reaches the database.
    func testEachAreaMarksItsOwnDirtySet() async {
        let store = Fixtures.makeStore()
        await store.identifyUser(userID: 960, username: "payer", firstName: nil)
        _ = await store.drainDirtyBatch()

        _ = await store.seedPurchasedBalance(key: UserKey.identified(960), amount: .usd(1))
        _ = await store.activatePaidSubscription(UserKey.identified(960))
        _ = await store.assignChat(chatID: -960, to: UserKey.identified(960))
        await store.setDailyPremiumLimit(3)

        let batch = await store.drainDirtyBatch()
        let wallets = await store.drainDirtyWallets()
        XCTAssertFalse(batch.tenants.isEmpty, "tenants")
        XCTAssertFalse(batch.chats.isEmpty, "chat ownership")
        XCTAssertFalse(wallets.changed.isEmpty, "wallets")
        XCTAssertTrue(batch.configs.contains { $0.name == .dailyPremiumLimit }, "daily premium limit")
    }

    /// The daily premium counter is persisted on purpose: an in-memory one
    /// hands everyone a fresh allowance on every redeploy.
    func testDailyPremiumUsageIsPersisted() async {
        let store = Fixtures.makeStore()
        await store.setDailyPremiumLimit(3)
        _ = await store.drainDirtyBatch()
        _ = await store.consumeDailyPremium(chatID: 961, userID: 961, isGroup: false)

        let batch = await store.drainDirtyBatch()
        XCTAssertEqual(batch.premiumUsage.count, 1)
        XCTAssertEqual(batch.premiumUsage.first?.usage.used, 1)
    }

    func testMergeKeepsTheNewerRowAndHonoursDeletes() {
        var older = PersistenceBatch()
        older.tenants = [TenantRow(key: UserKey.identified(1), snapshot: makeTenantSnapshot(model: "old/model"))]
        older.chats = [ChatRow(chatID: -1, meta: nil, ownerKey: UserKey.identified(1))]
        older.configs = [StoredConfig(Config.markup, 10)]
        var newer = PersistenceBatch()
        newer.tenants = [TenantRow(key: UserKey.identified(1), snapshot: makeTenantSnapshot(model: "new/model"))]
        newer.deletedChats = [-1]
        newer.configs = [StoredConfig(Config.markup, 20)]

        let merged = PersistenceBatch.merged(older: older, newer: newer)
        XCTAssertEqual(merged.tenants.count, 1)
        XCTAssertEqual(merged.tenants.first?.snapshot.defaultModel, "new/model")
        XCTAssertTrue(merged.chats.isEmpty)
        XCTAssertEqual(merged.deletedChats, [-1])
        XCTAssertEqual(merged.configs.count, 1)
        XCTAssertEqual(merged.configs.first?.name, .markup)
        XCTAssertEqual(try JSONEncoder().encode(merged.configs[0]), try JSONEncoder().encode(StoredConfig(Config.markup, 20)))
    }

    /// A row written and then deleted must not come back, and vice versa.
    func testMergeResurrectsARowWrittenAfterItsDelete() {
        var older = PersistenceBatch()
        older.deletedTenants = [UserKey.identified(1)]
        var newer = PersistenceBatch()
        newer.tenants = [TenantRow(key: UserKey.identified(1), snapshot: makeTenantSnapshot(model: "m"))]

        let merged = PersistenceBatch.merged(older: older, newer: newer)
        XCTAssertEqual(merged.tenants.count, 1)
        XCTAssertTrue(merged.deletedTenants.isEmpty)
    }

    func testRestoreRebuildsStateAfterARestart() async {
        let store = Fixtures.makeStore()
        let paidUntil = Date().addingTimeInterval(Fixtures.days(10))
        var stored = PersistedBotState()
        stored.users = [UserRow(identity: UserIdentity(
            userID: 970, username: "sponsor", firstName: nil, seenAt: Date(), firstSeenAt: Date()
        ))]
        stored.contexts = [ChatContextRow(
            key: ChatKey(chatID: -970, threadID: 0),
            snapshot: makeContextSnapshot(model: "restored/model")
        )]
        stored.tenants = [TenantRow(
            key: UserKey.identified(970),
            snapshot: makeTenantSnapshot(model: "tenant/model", paidUntil: paidUntil)
        )]
        stored.chats = [ChatRow(chatID: -970, meta: nil, ownerKey: UserKey.identified(970))]
        stored.wallets = [UserKey.identified(970): UserBalance(
            balance: .usd(3), spentBilled: .usd(1), spentReal: .usd(0.5), toppedUp: .usd(3)
        )]
        var configs = ConfigDocuments()
        configs.set(Config.starsPrice, 777)
        configs.set(Config.markup, 42)
        stored.configs = configs
        await store.restore(from: stored)

        let help = await store.fetchHelp(chatKey: ChatKey(chatID: -970, threadID: 0))
        XCTAssertEqual(help.model, "restored/model")
        let owner = await store.chatOwner(chatID: -970)
        XCTAssertEqual(owner, UserKey.identified(970))
        let subscription = await store.tenantSubscription(ownerKey: UserKey.identified(970))
        XCTAssertTrue(subscription.isActive)
        let markup = await store.markupPercent()
        XCTAssertEqual(markup, 42)
        let pricing = await store.subscriptionPricing(key: nil)
        XCTAssertEqual(pricing.stars, 777)
        let wallet = await store.balance(UserKey.pending("@sponsor")!)
        XCTAssertEqual(wallet?.toppedUp, .usd(3))
        let label = await store.displayLabel(forKey: UserKey.identified(970))
        XCTAssertEqual(label, "@sponsor")
    }

    /// Campaign aggregates are what a media buy is judged on, and they are
    /// meant to outlive the per-person rows they came from: attributions are
    /// pruned by age, the aggregates are not. Recomputing them from whatever
    /// attributions survived would quietly hand a campaign back a CAC of zero
    /// customers.
    func testCampaignAggregatesSurviveTheLossOfTheirAttributions() async {
        let store = Fixtures.makeStore()
        _ = await store.bindTrafficSource(userID: 992, tag: "youtube", username: nil)
        await store.markTrafficSourceActivation(userID: 992)
        await store.recordTrafficSourcePayment(userID: 992)

        let batch = await store.drainDirtyBatch()
        XCTAssertTrue(batch.configs.contains { $0.name == .trafficTotals }, "the aggregates have to be exported")

        // A restart that finds the document but not the rows behind it.
        var stored = PersistedBotState()
        var configs = ConfigDocuments()
        configs.set(Config.trafficTotals, await store.trafficSourceLedger().totals)
        stored.configs = configs

        let reloaded = Fixtures.makeStore()
        await reloaded.restore(from: stored)

        let overview = await reloaded.trafficSourceOverview()
        XCTAssertEqual(overview.joined, 1)
        XCTAssertEqual(overview.activated, 1)
        XCTAssertEqual(overview.payers, 1, "a campaign must not forget the customer it paid for")
    }

    // MARK: - Builders

    private func makeTenantSnapshot(model: String, paidUntil: Date? = nil) -> TenantStateSnapshot {
        TenantStateSnapshot(
            ownerKey: UserKey.identified(1),
            defaultModel: model,
            defaultRole: "role",
            defaultHistoryLength: 10,
            modelPresets: [],
            tempPresets: [],
            historyLengthPresets: [],
            rolePresets: [],
            whitelistedUserIDs: [],
            adminKeys: [],
            licensedKeys: [],
            cumulativeUsage: nil,
            createdAt: nil,
            paidUntil: paidUntil
        )
    }

    private func makeContextSnapshot(model: String) -> ChatContextSnapshot {
        ChatContextSnapshot(
            role: "role",
            history: [ChatMessage(role: "system", content: "role")],
            model: model,
            temp: 1,
            showStats: false,
            maxHistory: 10,
            showCost: false,
            showModel: false,
            provider: .openrouter,
            backupNotify: false
        )
    }
}

/// Funnel counters: all-time totals plus per-day buckets, both surviving a
/// restart.
final class StoreFunnelTests: XCTestCase {

    func testEventsCountIntoTotalsAndToday() async {
        let store = Fixtures.makeStore()
        await store.bumpFunnel(.start)
        await store.bumpFunnel(.start)
        await store.bumpFunnel(.paid)

        let report = await store.funnelReport()
        XCTAssertEqual(report.counters[FunnelEvent.start.rawValue], 2)
        XCTAssertEqual(report.todayCounters[FunnelEvent.start.rawValue], 2)
        XCTAssertEqual(report.counters[FunnelEvent.paid.rawValue], 1)
    }

    /// The purchase page is opened from many surfaces; each keeps its own
    /// counter, in a namespace that cannot collide with an event name.
    func testPurchaseSourcesAreCountedSeparately() async {
        let store = Fixtures.makeStore()
        await store.bumpPurchaseOpen(source: .cap)
        await store.bumpPurchaseOpen(source: .menu)
        await store.bumpPurchaseOpen(source: .cap)

        let report = await store.funnelReport()
        XCTAssertEqual(report.counters[PurchaseSource.cap.counterKey], 2)
        XCTAssertEqual(report.counters[PurchaseSource.menu.counterKey], 1)
        XCTAssertEqual(report.counters[FunnelEvent.openPurchase.rawValue], 3, "the total still counts every open")
    }

    func testUnknownPurchaseSourceFallsBackToMenu() {
        XCTAssertEqual(PurchaseSource.parse("cap"), .cap)
        XCTAssertEqual(PurchaseSource.parse("who-knows"), .menu)
        XCTAssertEqual(PurchaseSource.parse(nil), .menu)
    }

    func testFirstMessageIsCountedOncePerChat() async {
        let store = Fixtures.makeStore()
        let chat = ChatKey(chatID: 980, threadID: 0)
        await store.markFirstMessageIfNeeded(chatKey: chat)
        await store.markFirstMessageIfNeeded(chatKey: chat)

        let report = await store.funnelReport()
        XCTAssertEqual(report.counters[FunnelEvent.firstMessage.rawValue], 1)
    }

    func testSponsorCountsAreLive() async {
        let store = Fixtures.makeStore()
        await store.identifyUser(userID: 981, username: "active", firstName: nil)
        await store.identifyUser(userID: 982, username: "lapsed", firstName: nil)
        _ = await store.activatePaidSubscription(UserKey.identified(981))
        _ = await store.activatePaidSubscription(UserKey.identified(982))
        _ = await store.expireTenantSubscription(UserKey.identified(982))

        var report = await store.funnelReport()
        XCTAssertEqual(report.sponsorsActive, 1)
        XCTAssertEqual(report.sponsorsExpired, 1)
        XCTAssertEqual(report.sponsorsUnlimited, 0, "the bot's own owners are not sponsors")

        await store.identifyUser(userID: 983, username: "forever", firstName: nil)
        _ = await store.activatePaidSubscription(UserKey.identified(983))
        _ = await store.setTenantUnlimited(UserKey.identified(983))
        report = await store.funnelReport()
        XCTAssertEqual(report.sponsorsUnlimited, 1)
    }

    func testDailyLogKeepsAWindowOfDays() {
        var log = FunnelDailyLog.empty
        let now = Date()
        let longAgo = now.addingTimeInterval(-Fixtures.days(Double(FunnelDailyLog.windowDays + 5)))

        log.bump(key: FunnelEvent.start.rawValue, now: longAgo)
        log.bump(key: FunnelEvent.start.rawValue, now: now)

        // A period view only ever sums the days inside it.
        XCTAssertEqual(log.counts(lastDays: 1, now: now)[FunnelEvent.start.rawValue], 1)
        XCTAssertEqual(log.counts(lastDays: 30, now: now)[FunnelEvent.start.rawValue], 1)

        // Pruning is relative to the real current day, never to a backdated
        // write, so an old bump cannot wipe newer buckets.
        log.prune(now: now)
        XCTAssertNil(log.days[FunnelDailyLog.dayNumber(longAgo)])
        XCTAssertNotNil(log.days[FunnelDailyLog.dayNumber(now)])
    }
}
