import XCTest
@testable import LLM_chat_bot

/// Zone 24: the loops nobody watches — the owner alerter, the model-price
/// monitor, the retention sweep and the reminder sweep.
///
/// What they have in common is that their failure mode is not an exception, it
/// is *volume*: a condition that flaps, an upstream that answers 200 with
/// nothing in it, a table nobody deletes from, an outreach wave that eats the
/// whole Telegram budget. None of it shows up in a stack trace, so it has to
/// show up here.
final class BackgroundLoopTests: XCTestCase {

    // MARK: - Announcement throttle

    /// The bound is on speaking, not on observing: the condition may be
    /// reported a hundred times an hour, the owner hears it once.
    func testAThrottledSubjectSpeaksOncePerInterval() {
        var throttle = AnnouncementThrottle<String>(interval: 3600)
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertTrue(throttle.claim("a", now: t0))
        XCTAssertFalse(throttle.claim("a", now: t0.addingTimeInterval(60)))
        XCTAssertFalse(throttle.claim("a", now: t0.addingTimeInterval(3599)))
        XCTAssertTrue(throttle.claim("a", now: t0.addingTimeInterval(3601)))
        // Subjects do not share a budget — one noisy model must not silence
        // another one's first notice.
        XCTAssertTrue(throttle.claim("b", now: t0.addingTimeInterval(3601)))
    }

    func testForgettingASubjectLetsItSpeakImmediately() {
        var throttle = AnnouncementThrottle<String>(interval: 3600)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(throttle.claim("a", now: t0))
        throttle.forget("a")
        XCTAssertTrue(throttle.claim("a", now: t0.addingTimeInterval(1)))
    }

    // MARK: - Owner alerter

    /// A recovery message is only honest for an incident the owner was told
    /// about. The announcement is rate-limited and the recovery is not, so a
    /// condition flapping every few minutes used to be silent on the way up and
    /// chatty on the way down — the exact shape that gets an alerter muted.
    func testAThrottledIncidentRecoversQuietly() async {
        let telegram = RecordingTelegram()
        let alerter = await makeAlerter(telegram: telegram)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        await alerter.report(.databaseDown, active: true, now: t0)
        await alerter.report(.databaseDown, active: false, now: t0.addingTimeInterval(120))
        XCTAssertEqual(telegram.sentTexts.count, 2, "the first incident and its recovery are announced")

        await alerter.report(.databaseDown, active: true, now: t0.addingTimeInterval(300))
        XCTAssertEqual(telegram.sentTexts.count, 2, "a second incident inside the hour is throttled")
        await alerter.report(.databaseDown, active: false, now: t0.addingTimeInterval(420))
        XCTAssertEqual(telegram.sentTexts.count, 2, "and it must not announce a recovery nobody heard about")
    }

    /// The detail is a machine's words — a Postgres error, a connection string
    /// — printed into an HTML message. One `&` is enough for Telegram to
    /// reject the send, which would silence exactly the alert saying the
    /// database is unreachable.
    func testAnErrorDetailIsEscapedRatherThanBreakingItsOwnAlert() async {
        let telegram = RecordingTelegram()
        let alerter = await makeAlerter(telegram: telegram)

        await alerter.report(
            .databaseDown,
            active: true,
            detail: "connect to <db-1> failed: sslmode=require&target_session_attrs=rw"
        )

        let text = try? XCTUnwrap(telegram.sentTexts.first)
        let sent = text ?? ""
        XCTAssertFalse(sent.contains("<db-1>"), "an unescaped tag would make Telegram reject the alert")
        XCTAssertTrue(sent.contains("&lt;db-1&gt;"))
        XCTAssertTrue(sent.contains("sslmode=require&amp;target_session_attrs=rw"))
    }

    /// An alert that could not be delivered is not an alert that was sent. It
    /// stays unannounced, and the throttle offers the next attempt an hour
    /// later rather than turning an outage into a retry loop.
    func testAnUndeliveredAlertIsRetriedRatherThanRememberedAsSent() async {
        let telegram = RecordingTelegram()
        telegram.failNextSends(1)
        let alerter = await makeAlerter(telegram: telegram)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        await alerter.report(.ledgerMismatch, active: true, now: t0)
        XCTAssertEqual(telegram.attempts, 1)
        await alerter.report(.ledgerMismatch, active: true, now: t0.addingTimeInterval(300))
        XCTAssertEqual(telegram.attempts, 1, "a failed send must not become its own flood")

        await alerter.report(.ledgerMismatch, active: true, now: t0.addingTimeInterval(3601))
        XCTAssertEqual(telegram.attempts, 2, "the next hour tries again")
        XCTAssertEqual(telegram.sentTexts.count, 1)

        // Announced this time — so the recovery is worth sending.
        await alerter.report(.ledgerMismatch, active: false, now: t0.addingTimeInterval(3700))
        XCTAssertEqual(telegram.sentTexts.count, 2)
    }

    /// `/metrics` reports what is on, not what was said: an incident held back
    /// by the throttle is still an incident an external monitor must see.
    func testMetricsSeeIncidentsTheOwnerWasNotToldAbout() async {
        let telegram = RecordingTelegram()
        telegram.failNextSends(1)
        let alerter = await makeAlerter(telegram: telegram)

        await alerter.report(.volatileMode, active: true)
        let active = await alerter.activeAlerts()
        XCTAssertEqual(active, [.volatileMode])
    }

    private func makeAlerter(telegram: TelegramGatewayPort) async -> OwnerAlerter {
        let store = Fixtures.makeStore()
        await store.identifyUser(userID: Fixtures.ownerUserID, username: Fixtures.ownerHandle, firstName: nil)
        await store.recordChatMeta(
            chatID: Fixtures.ownerUserID.privateChat,
            info: ChatMetaInfo(type: "private", title: nil, username: Fixtures.ownerHandle, firstName: nil, botRemoved: nil)
        )
        return OwnerAlerter(telegram: telegram, state: store, logger: SilentLogger())
    }

    // MARK: - Model catalogue

    /// An empty catalogue is an outage answering 200, not the news that every
    /// free model became paid. Believing it would empty the free set, and every
    /// free-tier chat would start spending its daily premium allowance on a
    /// model that costs nothing — while being told the model "стала платной".
    func testAnEmptyCatalogueIsRefusedRatherThanBelieved() throws {
        let response = try decodeCatalogue(#"{"data": []}"#)
        XCTAssertThrowsError(try ModelCatalogueReading(response)) { error in
            guard case ModelCatalogueError.empty = error else {
                return XCTFail("expected .empty, got \(error)")
            }
        }
    }

    func testACatalogueReadingSeparatesFreeModelsFromPrices() throws {
        let reading = try ModelCatalogueReading(decodeCatalogue(#"""
        {"data": [
          {"id": "vendor/free", "pricing": {"prompt": "0", "completion": "0"}},
          {"id": "vendor/paid", "pricing": {"prompt": "0.000001", "completion": "0.000002"}},
          {"id": "vendor/unpriced"}
        ]}
        """#))

        XCTAssertEqual(reading.freeModelIDs, ["vendor/free"])
        XCTAssertEqual(reading.prices.keys.sorted(), ["vendor/free", "vendor/paid"])
        XCTAssertEqual(reading.prices["vendor/paid"]?.outputPerToken, 0.000002)
    }

    /// Only models somebody is actually running are announced, and in a stable
    /// order — the announcements are side effects, and an arbitrary `Set` order
    /// makes them unreproducible.
    func testOnlyTrackedModelsThatStoppedBeingFreeAreAnnounced() throws {
        let reading = try ModelCatalogueReading(decodeCatalogue(#"""
        {"data": [
          {"id": "vendor/still-free", "pricing": {"prompt": "0", "completion": "0"}},
          {"id": "vendor/a", "pricing": {"prompt": "0.1", "completion": "0.1"}},
          {"id": "vendor/b", "pricing": {"prompt": "0.1", "completion": "0.1"}}
        ]}
        """#))

        let becamePaid = reading.modelsThatBecamePaid(
            previouslyFree: ["vendor/a", "vendor/b", "vendor/still-free", "vendor/nobody-uses"],
            tracked: ["vendor/a", "vendor/b", "vendor/still-free"]
        )
        XCTAssertEqual(becamePaid, ["vendor/a", "vendor/b"])
    }

    private func decodeCatalogue(_ json: String) throws -> OpenRouterModelsResponse {
        try JSONDecoder().decode(OpenRouterModelsResponse.self, from: Data(json.utf8))
    }

    // MARK: - Retention sweep

    /// Funnel buckets leave the window the loader reads and then stay in the
    /// table forever — ~30 rows a day that nothing ever deletes. The daily
    /// sweep owns "delete what nobody will read again", so it owns these too,
    /// and it prunes against the very horizon the loader filters on.
    func testTheDailySweepDropsFunnelBucketsOutsideTheLoadedWindow() async {
        let store = Fixtures.makeStore()
        let persistence = RecordingRetentionStorage()
        let retention = RetentionService(state: store, persistence: persistence, logger: SilentLogger())

        let outcome = await retention.sweep()

        let prunedBefore = await persistence.funnelPrunedBefore
        XCTAssertEqual(prunedBefore, FunnelDailyLog.oldestLoadedDay())
        XCTAssertEqual(outcome.funnelDays, 7)
    }

    /// The two halves are independent: conversations failing to prune must not
    /// leave the funnel table growing forever.
    func testAFailingConversationPruneStillLetsTheFunnelPruneRun() async {
        let store = Fixtures.makeStore()
        let persistence = RecordingRetentionStorage(failContexts: true)
        let retention = RetentionService(state: store, persistence: persistence, logger: SilentLogger())

        let outcome = await retention.sweep()

        XCTAssertEqual(outcome.conversations, 0)
        XCTAssertEqual(outcome.funnelDays, 7)
    }

    // MARK: - Reminder sweep

    /// A sweep spends the same Telegram budget live answers spend. An outreach
    /// wave to everyone at once would hold that budget for minutes and block
    /// the super-admin's "проверить сейчас" behind it, so the sweep stops at
    /// its budget — and, because a notice is only marked after delivery, the
    /// next sweep resumes at exactly the same front.
    func testASweepStopsAtItsSendBudgetAndTheNextOneResumes() async {
        let store = Fixtures.makeStore()
        let telegram = RecordingTelegram()
        let overflow = 3
        let sponsors = SubscriptionReminderService.maxNoticesPerSweep + overflow
        var paidUntil = Date()

        for index in 0..<sponsors {
            let userID = UserID(2_000 + index)
            await store.identifyUser(userID: userID, username: "sponsor\(index)", firstName: nil)
            let key = UserKey.identified(userID)
            _ = await store.activatePaidSubscription(key)
            await store.recordChatMeta(
                chatID: userID.privateChat,
                info: ChatMetaInfo(type: "private", title: nil, username: "sponsor\(index)", firstName: nil, botRemoved: nil)
            )
            paidUntil = await store.tenantSubscription(ownerKey: key).paidUntil ?? paidUntil
        }

        let service = SubscriptionReminderService(
            telegram: telegram,
            state: store,
            logger: SilentLogger(),
            metrics: RuntimeMetrics()
        )
        // Half a day before every subscription ends: the "завтра" wave is due
        // for all of them at once.
        let now = paidUntil.addingTimeInterval(-Fixtures.days(0.5))

        let first = await service.sweep(now: now)
        XCTAssertEqual(first.due, sponsors)
        XCTAssertEqual(first.expiryRemindersSent, SubscriptionReminderService.maxNoticesPerSweep)
        XCTAssertEqual(first.deferred, overflow)
        XCTAssertEqual(telegram.sentTexts.count, SubscriptionReminderService.maxNoticesPerSweep)

        let second = await service.sweep(now: now)
        XCTAssertEqual(second.due, overflow, "what did not fit is still due")
        XCTAssertEqual(second.expiryRemindersSent, overflow)
        XCTAssertEqual(second.deferred, 0)
    }
}

// MARK: - Doubles

/// A Bot API that only records what it was asked to say, and can be told to
/// fail the next few sends.
private final class RecordingTelegram: TelegramGatewayPort, @unchecked Sendable {
    struct Refused: Error {}

    private let state = LockedValue(State())

    private struct State {
        var texts: [String] = []
        var attempts = 0
        var failuresLeft = 0
    }

    var sentTexts: [String] { state.value.texts }
    var attempts: Int { state.value.attempts }

    func failNextSends(_ count: Int) {
        state.withLock { $0.failuresLeft = count }
    }

    func sendMessage(_ request: SendMessageRequest) async throws -> TelegramMessage {
        let refuse: Bool = state.withLock { current in
            current.attempts += 1
            guard current.failuresLeft > 0 else {
                current.texts.append(request.text)
                return false
            }
            current.failuresLeft -= 1
            return true
        }
        if refuse { throw Refused() }
        return Fixtures.message(chat: Fixtures.chat(id: request.chatID))
    }

    private struct Unsupported: Error {}
    func deleteWebhook() async throws { throw Unsupported() }
    func setWebhook(url: String, secretToken: String, allowedUpdates: [String]) async throws { throw Unsupported() }
    func decodeIncomingUpdate(_ data: Data) throws -> TelegramUpdate { throw Unsupported() }
    func getMe() async throws -> TelegramUser { throw Unsupported() }
    func getUpdates(offset: Int?) async throws -> [TelegramUpdate] { throw Unsupported() }
    func editMessage(_ request: EditMessageRequest) async throws { throw Unsupported() }
    func sendMessageDraft(_ request: SendMessageDraftRequest) async throws { throw Unsupported() }
    func deleteMessage(chatID: ChatID, messageID: Int) async throws { throw Unsupported() }
    func sendChatAction(chatID: ChatID, threadID: Int64?, action: String) async throws { throw Unsupported() }
    func answerCallback(callbackQueryID: String, text: String?) async throws { throw Unsupported() }
    func sendInvoice(_ request: SendInvoiceRequest) async throws { throw Unsupported() }
    func answerPreCheckoutQuery(queryID: String, ok: Bool, errorMessage: String?) async throws { throw Unsupported() }
    func getFile(fileID: String) async throws -> TelegramFile { throw Unsupported() }
    func downloadFile(filePath: String) async throws -> Data { throw Unsupported() }
}

/// Storage that records what the retention sweep asked it to delete.
private actor RecordingRetentionStorage: StatePersistencePort {
    struct Refused: Error {}

    private let failContexts: Bool
    private(set) var funnelPrunedBefore: Int?

    init(failContexts: Bool = false) { self.failContexts = failContexts }

    func loadEverything() async throws -> PersistedBotState { PersistedBotState() }
    func apply(_ batch: PersistenceBatch) async throws {}

    func pruneChatContexts(idleDays: Int, protecting: Set<ChatID>) async throws -> [ChatKey] {
        if failContexts { throw Refused() }
        return []
    }

    func pruneFunnelDays(before day: Int) async throws -> Int {
        funnelPrunedBefore = day
        return 7
    }
}
