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
        XCTAssertTrue(batch.configs.contains { if case .markup = $0 { return true } else { return false } })

        let second = await store.drainDirtyBatch()
        XCTAssertTrue(second.isEmpty, "a drained change must not be written twice")
    }

    /// Every new mutation has to mark its dirty set, or it silently never
    /// reaches the database.
    func testEachAreaMarksItsOwnDirtySet() async {
        let store = Fixtures.makeStore()
        await store.identifyUser(userID: 960, username: "payer", firstName: nil)
        _ = await store.drainDirtyBatch()

        _ = await store.creditPurchasedBalance(key: UserKey.forUserID(960), amountUsd: 1)
        _ = await store.activatePaidSubscription(username: UserKey.forUserID(960))
        _ = await store.assignChat(chatID: -960, to: UserKey.forUserID(960))
        await store.setDailyPremiumLimit(3)

        let batch = await store.drainDirtyBatch()
        XCTAssertFalse(batch.tenants.isEmpty, "tenants")
        XCTAssertFalse(batch.ownership.isEmpty, "ownership")
        XCTAssertTrue(batch.configs.contains { if case .balances = $0 { return true } else { return false } }, "balances")
        XCTAssertTrue(
            batch.configs.contains { if case .dailyPremiumLimit = $0 { return true } else { return false } },
            "daily premium limit"
        )
    }

    /// The daily premium counter is persisted on purpose: an in-memory one
    /// hands everyone a fresh allowance on every redeploy.
    func testDailyPremiumUsageIsPersisted() async {
        let store = Fixtures.makeStore()
        await store.setDailyPremiumLimit(3)
        _ = await store.drainDirtyBatch()
        _ = await store.consumeDailyPremium(chatID: 961, userID: 961, isGroup: false)

        let batch = await store.drainDirtyBatch()
        XCTAssertTrue(batch.configs.contains { if case .dailyPremiumUsage = $0 { return true } else { return false } })
    }

    func testMergeKeepsTheNewerRowAndHonoursDeletes() {
        let older = PersistenceBatch(
            tenants: [TenantRow(username: "#1", snapshot: makeTenantSnapshot(model: "old/model"))],
            ownership: [OwnershipRow(chatID: -1, owner: "#1")],
            configs: [.markup(10)]
        )
        let newer = PersistenceBatch(
            tenants: [TenantRow(username: "#1", snapshot: makeTenantSnapshot(model: "new/model"))],
            deletedOwnership: [-1],
            configs: [.markup(20)]
        )

        let merged = PersistenceBatch.merged(older: older, newer: newer)
        XCTAssertEqual(merged.tenants.count, 1)
        XCTAssertEqual(merged.tenants.first?.snapshot.defaultModel, "new/model")
        XCTAssertTrue(merged.ownership.isEmpty)
        XCTAssertEqual(merged.deletedOwnership, [-1])
        XCTAssertEqual(merged.configs.count, 1)
        if case .markup(let percent) = merged.configs[0] {
            XCTAssertEqual(percent, 20)
        } else {
            XCTFail("expected the newer markup")
        }
    }

    /// A row written and then deleted must not come back, and vice versa.
    func testMergeResurrectsARowWrittenAfterItsDelete() {
        let older = PersistenceBatch(deletedTenants: ["#1"])
        let newer = PersistenceBatch(tenants: [TenantRow(username: "#1", snapshot: makeTenantSnapshot(model: "m"))])

        let merged = PersistenceBatch.merged(older: older, newer: newer)
        XCTAssertEqual(merged.tenants.count, 1)
        XCTAssertTrue(merged.deletedTenants.isEmpty)
    }

    func testRestoreRebuildsStateAfterARestart() async {
        let store = Fixtures.makeStore()
        var directory = UserDirectory.empty
        directory.record(userID: 970, username: "sponsor", firstName: nil)

        let paidUntil = Date().addingTimeInterval(Fixtures.days(10))
        await store.restore(from: PersistedBotState(
            contexts: [
                ChatContextRow(
                    key: ChatKey(chatID: -970, threadID: 0),
                    snapshot: makeContextSnapshot(model: "restored/model")
                )
            ],
            tenants: [
                TenantRow(
                    username: "#970",
                    snapshot: makeTenantSnapshot(model: "tenant/model", paidUntil: paidUntil)
                )
            ],
            ownership: [OwnershipRow(chatID: -970, owner: "#970")],
            configs: PersistedGlobalConfigs(
                starsPrice: 777,
                markup: 42,
                balances: ["#970": UserBalance(balanceUsd: 3, spentBilledUsd: 1, spentRealUsd: 0.5, updatedAt: nil, toppedUpUsd: 3)],
                userDirectory: directory
            )
        ))

        let help = await store.fetchHelp(chatKey: ChatKey(chatID: -970, threadID: 0))
        XCTAssertEqual(help.model, "restored/model")
        let owner = await store.chatOwner(chatID: -970)
        XCTAssertEqual(owner, "#970")
        let subscription = await store.tenantSubscription(ownerUsername: "#970")
        XCTAssertTrue(subscription.isActive)
        let markup = await store.markupPercent()
        XCTAssertEqual(markup, 42)
        let pricing = await store.subscriptionPricing(username: nil)
        XCTAssertEqual(pricing.stars, 777)
        let wallet = await store.balance(username: "@sponsor")
        XCTAssertEqual(wallet?.toppedUpUsd, 3)
        let label = await store.displayLabel(forKey: "#970")
        XCTAssertEqual(label, "@sponsor")
    }

    // MARK: - Builders

    private func makeTenantSnapshot(model: String, paidUntil: Date? = nil) -> TenantStateSnapshot {
        TenantStateSnapshot(
            ownerUsername: "#1",
            defaultModel: model,
            defaultRole: "role",
            defaultHistoryLength: 10,
            modelPresets: [],
            tempPresets: [],
            historyLengthPresets: [],
            rolePresets: [],
            whitelistedUserIDs: [],
            adminUsernames: [],
            licensedUsernames: [],
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
        _ = await store.activatePaidSubscription(username: UserKey.forUserID(981))
        _ = await store.activatePaidSubscription(username: UserKey.forUserID(982))
        _ = await store.expireTenantSubscription(username: UserKey.forUserID(982))

        var report = await store.funnelReport()
        XCTAssertEqual(report.sponsorsActive, 1)
        XCTAssertEqual(report.sponsorsExpired, 1)
        XCTAssertEqual(report.sponsorsUnlimited, 0, "the bot's own owners are not sponsors")

        await store.identifyUser(userID: 983, username: "forever", firstName: nil)
        _ = await store.activatePaidSubscription(username: UserKey.forUserID(983))
        _ = await store.setTenantUnlimited(username: UserKey.forUserID(983))
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
