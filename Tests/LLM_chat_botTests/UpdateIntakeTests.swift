import XCTest
@testable import LLM_chat_bot

/// The runtime edge: what arrives from Telegram passes the deduplicator once,
/// albums are glued back together within bounds, and nothing that was already
/// acknowledged with a 200 is dropped on the way out.
final class UpdateIntakeTests: XCTestCase {

    private let group = Fixtures.chat(id: -5_000, type: "supergroup", title: "чат")

    private func update(_ id: Int, mediaGroup: String? = nil, text: String? = "привет", chat: TelegramChat? = nil) -> TelegramUpdate {
        let message = TelegramMessage(
            message_id: id,
            from: Fixtures.user(id: 77),
            chat: chat ?? group,
            date: 0,
            text: mediaGroup == nil ? text : nil,
            caption: mediaGroup == nil ? nil : "подпись",
            voice: nil,
            video: nil,
            message_thread_id: nil,
            media_group_id: mediaGroup,
            reply_to_message: nil,
            photo: mediaGroup == nil ? nil : [PhotoSize(file_id: "f\(id)", file_unique_id: "u\(id)", width: 100, height: 100, file_size: 10_000)]
        )
        return TelegramUpdate(update_id: id, message: message, callback_query: nil, pre_checkout_query: nil, my_chat_member: nil)
    }

    // MARK: - Deduplication

    /// Telegram redelivers whenever a webhook answer is lost. A second copy of
    /// the same update is the same question asked twice — answering it twice is
    /// two replies and, on a paid model, two charges.
    func testTheSameUpdateIsDeliveredOnce() {
        var deduplicator = UpdateDeduplicator()

        XCTAssertTrue(deduplicator.insert(42))
        XCTAssertFalse(deduplicator.insert(42))
        XCTAssertTrue(deduplicator.insert(43))
    }

    /// The ring is a fixed-size memory, not a set that grows with traffic: the
    /// oldest id is forgotten once `capacity` newer ones have gone through.
    func testTheDeduplicatorForgetsOnlyAfterItsCapacity() {
        var deduplicator = UpdateDeduplicator(capacity: 16)

        XCTAssertTrue(deduplicator.insert(1))
        for id in 2...16 { XCTAssertTrue(deduplicator.insert(id)) }
        XCTAssertFalse(deduplicator.insert(1), "still remembered while it is inside the window")

        XCTAssertTrue(deduplicator.insert(17))
        XCTAssertTrue(deduplicator.insert(1), "evicted once the window moved past it")
    }

    // MARK: - Albums

    func testAnAlbumIsHeldBackAndThenReleasedAsOneMessage() {
        var buffer = TelegramPhotoAlbumBuffer()
        let start = Date()

        let immediate = buffer.ingest([update(1, mediaGroup: "album"), update(2, mediaGroup: "album")], now: start)
        XCTAssertTrue(immediate.isEmpty, "parts wait for the holdback")

        let released = buffer.ingest([], now: start.addingTimeInterval(1))
        XCTAssertEqual(released.count, 1)
        XCTAssertEqual(released.first?.message?.album_photos?.count, 2)
        XCTAssertFalse(buffer.hasBufferedUpdates)
    }

    /// A client that keeps posting parts under one `media_group_id` pushes the
    /// quiet-period forward with every part. Without the lifetime ceiling the
    /// album — and every message queued behind it — is held indefinitely.
    func testAnAlbumThatNeverGoesQuietIsStillReleased() {
        var buffer = TelegramPhotoAlbumBuffer()
        let start = Date()
        var released: [TelegramUpdate] = []

        // A part every second, so the album is never quiet for a holdback.
        for id in 1...12 {
            released += buffer.ingest(
                [update(id, mediaGroup: "endless")],
                now: start.addingTimeInterval(Double(id))
            )
        }

        XCTAssertFalse(released.isEmpty, "released on its lifetime, not on silence that never comes")
        XCTAssertLessThanOrEqual(
            released.first?.message?.album_photos?.count ?? 0,
            12,
            "the drip is cut at the lifetime, not carried whole"
        )
    }

    /// Every part carries a photo that would be downloaded and base64-encoded
    /// into the model request, so the count is capped rather than trusted.
    func testAnAlbumKeepsAtMostItsCapInParts() {
        var buffer = TelegramPhotoAlbumBuffer()
        let start = Date()
        var released: [TelegramUpdate] = []

        for id in 1...40 {
            released += buffer.ingest([update(id, mediaGroup: "flood")], now: start)
        }
        released += buffer.ingest([], now: start.addingTimeInterval(1))

        XCTAssertFalse(released.isEmpty)
        for album in released {
            XCTAssertLessThanOrEqual(album.message?.album_photos?.count ?? 0, 16)
        }
        XCTAssertFalse(buffer.hasBufferedUpdates)
    }

    /// Ordering inside a chat is a nicety; unbounded memory is not. Past the cap
    /// the updates queued behind an album go through slightly out of order
    /// instead of piling up.
    func testUpdatesQueuedBehindAnAlbumAreBounded() {
        var buffer = TelegramPhotoAlbumBuffer()
        let start = Date()

        _ = buffer.ingest([update(1, mediaGroup: "album")], now: start)
        var passedThrough = 0
        for id in 2...100 {
            passedThrough += buffer.ingest([update(id)], now: start).count
        }

        XCTAssertGreaterThan(passedThrough, 0, "the queue behind the album has a ceiling")
        let released = buffer.ingest([], now: start.addingTimeInterval(1))
        XCTAssertEqual(passedThrough + released.count, 100, "nothing is lost, only reordered")
    }

    /// A callback query has no message and must never wait behind an album:
    /// «Стоп» has to reach the generation it is stopping.
    func testACallbackIsNeverHeldBehindAnAlbum() {
        var buffer = TelegramPhotoAlbumBuffer()
        let start = Date()
        _ = buffer.ingest([update(1, mediaGroup: "album")], now: start)

        let callback = TelegramUpdate(
            update_id: 2,
            message: nil,
            callback_query: CallbackQuery(id: "cb", from: Fixtures.user(id: 77), data: "stop:x", message: nil),
            pre_checkout_query: nil,
            my_chat_member: nil
        )
        let released = buffer.ingest([callback], now: start)

        XCTAssertEqual(released.map { $0.update_id }, [2])
    }

    /// Telegram considers an update delivered the moment the webhook answered
    /// 200, so a half-collected album left in the buffer at shutdown is a
    /// message lost with no trace anywhere.
    func testShutdownHandsOnWhatIsStillBuffered() async {
        let metrics = RuntimeMetrics()
        let delivered = LockedValue<[Int]>([])
        let intake = UpdateIntake(metrics: metrics) { update in
            delivered.withLock { $0.append(update.update_id) }
        }

        await intake.enqueue([update(1, mediaGroup: "album"), update(2, mediaGroup: "album")])
        XCTAssertEqual(delivered.value, [], "still inside the holdback")

        await intake.shutdown()
        XCTAssertEqual(delivered.value, [1], "the album goes out merged rather than dropped")
    }

    func testTheIntakeDeliversEachUpdateOnce() async {
        let metrics = RuntimeMetrics()
        let delivered = LockedValue<[Int]>([])
        let intake = UpdateIntake(metrics: metrics) { update in
            delivered.withLock { $0.append(update.update_id) }
        }

        await intake.enqueue([update(1), update(2)])
        await intake.enqueue([update(2), update(3)])

        XCTAssertEqual(delivered.value, [1, 2, 3])
        let counters = await metrics.snapshot().counters
        XCTAssertEqual(counters[MetricName.updatesDeduplicated], 1)
    }
}

/// Per-chat serialization: one chat's messages are answered in the order they
/// were sent, different chats run in parallel, and a flood is dropped with one
/// word rather than growing a task chain for everybody else's memory.
final class ChatUpdateDispatcherTests: XCTestCase {

    private let chat = ChatKey(chatID: -6_000, threadID: 0)

    func testOperationsInOneChatRunInOrder() async throws {
        let dispatcher = ChatUpdateDispatcher()
        let order = LockedValue<[Int]>([])

        for i in 1...5 {
            let result = await dispatcher.submit(chatKey: chat) {
                // A suspension in the middle is exactly where interleaving
                // would show up.
                try? await Task.sleep(nanoseconds: UInt64((6 - i) * 2_000_000))
                order.withLock { $0.append(i) }
            }
            guard case .accepted = result else { return XCTFail("update \(i) was dropped") }
        }

        try await waitUntil { await dispatcher.totalQueuedOperations == 0 }
        XCTAssertEqual(order.value, [1, 2, 3, 4, 5])
    }

    /// The queue is bounded, and the chat is told once per burst — a warning
    /// per dropped message would be its own flood, and never warning again
    /// would leave a flooder in silence forever.
    func testAFloodIsDroppedWithExactlyOneWarning() async throws {
        let dispatcher = ChatUpdateDispatcher(maxQueuedPerChat: 2)
        let release = LockedValue(false)

        var notifications = 0
        var rejections = 0
        for _ in 0..<6 {
            switch await dispatcher.submit(chatKey: chat, operation: {
                while !release.value { await Task.yield() }
            }) {
            case .accepted: break
            case .rejected(let shouldNotify):
                rejections += 1
                if shouldNotify { notifications += 1 }
            }
        }

        XCTAssertEqual(rejections, 4)
        XCTAssertEqual(notifications, 1, "one warning for the whole burst")

        release.value = true
        try await waitUntil { await dispatcher.totalQueuedOperations == 0 }

        // Drained: the next burst is a new burst and gets its own warning.
        let accepted = await dispatcher.submit(chatKey: chat) {}
        guard case .accepted = accepted else { return XCTFail("a drained queue must take work again") }
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @escaping () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition not met within \(timeout)s", file: file, line: line)
    }
}

/// The global concurrency cap and the registry of what is currently streaming.
final class GenerationRuntimeTests: XCTestCase {

    /// Excess generations wait; the slot is handed to the next waiter directly,
    /// so a released slot can never be counted twice.
    func testTheLimiterHandsASlotToTheNextWaiter() async {
        let limiter = GenerationLimiter(maxConcurrent: 1)
        await limiter.acquire()

        let waiting = Task { await limiter.acquire() }
        // The waiter is queued rather than admitted.
        while await limiter.waitingCount == 0 { await Task.yield() }
        var active = await limiter.activeCount
        XCTAssertEqual(active, 1)

        await limiter.release()
        await waiting.value
        active = await limiter.activeCount
        let waitingCount = await limiter.waitingCount
        XCTAssertEqual(active, 1, "the slot moved, it was not duplicated")
        XCTAssertEqual(waitingCount, 0)
    }

    func testAMisconfiguredLimitStillAdmitsOneGeneration() async {
        let limiter = GenerationLimiter(maxConcurrent: 0)
        await limiter.acquire()
        let active = await limiter.activeCount
        XCTAssertEqual(active, 1)
    }

    /// «Стоп» can be tapped before the streaming task exists: the button lives
    /// on the placeholder message, which is sent first. The reason recorded then
    /// has to reach the task the moment it is attached — otherwise the answer is
    /// generated, billed and posted after the user was told «Остановлено».
    func testStoppingBeforeTheStreamStartsStillCancelsIt() async {
        let registry = SessionRegistry()
        let chat = ChatKey(chatID: -1, threadID: 0)
        let generation = await registry.register(chatKey: chat)

        let cancelled = await registry.cancel(generationID: generation)
        XCTAssertEqual(cancelled, chat)

        let started = LockedValue(false)
        let task = Task<Void, Never> {
            guard !Task.isCancelled else { return }
            started.value = true
        }
        await registry.attach(generationID: generation, task: task)
        await task.value

        XCTAssertTrue(task.isCancelled, "the task inherits the stop that arrived before it existed")
        XCTAssertFalse(started.value)
    }

    /// A second tap on «Стоп» must not tell the chat twice.
    func testASecondStopFindsTheGenerationAlreadyCancelled() async {
        let registry = SessionRegistry()
        let generation = await registry.register(chatKey: ChatKey(chatID: -1, threadID: 0))

        let first = await registry.cancel(generationID: generation)
        let second = await registry.cancel(generationID: generation)
        XCTAssertNotNil(first)
        XCTAssertNil(second)
    }
}
