import XCTest
@testable import LLM_chat_bot

/// End-to-end: a real update goes into `BotOrchestrator.dispatch`, through the
/// real command/menu/generation path and the real `TelegramHTTPGateway`, and
/// lands in a local Bot API stand-in — where the test reads exactly what the
/// user would have seen. Only the model and the media downloader are faked.
final class EndToEndTests: XCTestCase {

    private var telegram: FakeTelegram!
    private var store: ChatContextStore!
    private var orchestrator: BotOrchestrator!
    private var baseURL = ""

    private let botUsername = "testbot"
    private let ownerID = 4_000
    private let userID = 4_100

    override func setUp() async throws {
        telegram = FakeTelegram()
        baseURL = try await telegram.start()

        let gateway = TelegramHTTPGateway(
            network: NetworkClient(),
            botToken: "test-token",
            apiBase: baseURL,
            rateLimiter: nil,
            metrics: nil
        )
        store = Fixtures.makeStore(ownerUsername: "owner", ownerUserID: ownerID, model: "paid/model")
        orchestrator = BotOrchestrator(
            telegram: gateway,
            state: store,
            sessionRegistry: SessionRegistry(),
            mediaResolver: FakeMediaResolver(),
            providers: [.openrouter: FakeProviderGateway(reply: "ответ модели")],
            persistence: nil,
            logger: SilentLogger(),
            metrics: RuntimeMetrics(),
            flags: RuntimeFlags(),
            generationLimiter: GenerationLimiter(maxConcurrent: 4),
            botUsername: botUsername,
            formatOptions: ""
        )
    }

    override func tearDown() async throws {
        await telegram.stop()
        telegram = nil
        orchestrator = nil
        store = nil
    }

    /// Polls a condition the bot satisfies on its own tasks (history written,
    /// wallet credited) rather than sleeping for a fixed time.
    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @escaping () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("condition not met within \(timeout)s", file: file, line: line)
    }

    // MARK: - Update builders

    private func message(
        _ text: String,
        chatID: Int? = nil,
        userID: Int? = nil,
        username: String? = "tester",
        isGroup: Bool = false
    ) -> TelegramUpdate {
        let sender = userID ?? self.userID
        let chat = TelegramChat(
            id: chatID ?? sender,
            type: isGroup ? "supergroup" : "private",
            title: isGroup ? "Тестовая группа" : nil
        )
        return TelegramUpdate(
            update_id: Int.random(in: 1...1_000_000),
            message: Fixtures.message(
                text: text,
                from: Fixtures.user(id: sender, username: username),
                chat: chat
            ),
            callback_query: nil,
            pre_checkout_query: nil,
            my_chat_member: nil
        )
    }

    private func callback(_ data: String, chatID: Int? = nil, userID: Int? = nil, isGroup: Bool = false) -> TelegramUpdate {
        let sender = userID ?? self.userID
        let chat = TelegramChat(id: chatID ?? sender, type: isGroup ? "supergroup" : "private")
        return TelegramUpdate(
            update_id: Int.random(in: 1...1_000_000),
            message: nil,
            callback_query: CallbackQuery(
                id: "cb-\(Int.random(in: 1...100_000))",
                from: Fixtures.user(id: sender, username: "tester"),
                data: data,
                message: MaybeInaccessibleMessage(
                    chat: chat,
                    message_id: 5_000,
                    date: 0,
                    text: "меню",
                    message_thread_id: nil
                )
            ),
            pre_checkout_query: nil,
            my_chat_member: nil
        )
    }

    // MARK: - Tests

    /// The first thing every user sees: the greeting, and the example buttons
    /// that are the main defence against an empty chat.
    func testStartGreetsWithOnboardingButtons() async throws {
        await orchestrator.dispatch(update: message("/start"))

        let call = await telegram.waitForCall("sendMessage")
        let sent = try XCTUnwrap(call)
        XCTAssertEqual(sent.chatID, userID)
        XCTAssertEqual(sent.parseMode, "HTML")
        XCTAssertFalse(sent.buttonActions.isEmpty, "the greeting must carry buttons")
        XCTAssertTrue(
            sent.buttonActions.contains { $0.hasPrefix("ex:") },
            "onboarding examples missing: \(sent.buttonActions)"
        )

        // The funnel records the start it just served.
        let report = await store.funnelReport()
        XCTAssertEqual(report.counters[FunnelEvent.start.rawValue], 1)
        XCTAssertEqual(report.counters[FunnelEvent.onboardingShown.rawValue], 1)
    }

    /// A plain question in a DM must produce an answer from the model, written
    /// into that chat's history.
    func testPrivateMessageGetsAnAnswer() async throws {
        await orchestrator.dispatch(update: message("привет"))

        // A private chat first gets the "💭 Думаю…" control message with the
        // stop button; the answer itself follows.
        let answerCall = await telegram.waitForCall("sendMessage", containing: "ответ модели")
        let answer = try XCTUnwrap(answerCall, "no answer was sent")
        XCTAssertEqual(answer.chatID, userID)

        try await waitUntil { await self.store.history(chatKey: ChatKey(chatID: self.userID, threadID: 0)).count == 3 }
        let history = await store.history(chatKey: ChatKey(chatID: userID, threadID: 0))
        XCTAssertEqual(history.map(\.role), ["system", "user", "assistant"])
    }

    /// In a group the bot stays quiet unless it is addressed.
    func testGroupMessageWithoutMentionIsIgnored() async throws {
        await orchestrator.dispatch(update: message("болтаем", chatID: -4_200, isGroup: true))
        try await Task.sleep(nanoseconds: 300_000_000)

        let calls = await telegram.calls("sendMessage")
        XCTAssertTrue(calls.isEmpty, "answered an unaddressed group message: \(calls.map(\.body))")
    }

    func testGroupMentionIsAnswered() async throws {
        await orchestrator.dispatch(update: message("@testbot привет", chatID: -4_201, isGroup: true))

        let call = await telegram.waitForCall("sendMessage")
        let answer = try XCTUnwrap(call)
        XCTAssertEqual(answer.chatID, -4_201)
    }

    /// `/menu` renders a keyboard; every callback_data on it must route back to
    /// a page the handler knows.
    func testMenuRendersAndNavigates() async throws {
        await orchestrator.dispatch(update: message("/menu"))
        let menuCall = await telegram.waitForCall("sendMessage")
        let menu = try XCTUnwrap(menuCall)
        XCTAssertFalse(menu.buttonActions.isEmpty)
        XCTAssertTrue(menu.buttonActions.allSatisfy { $0.hasPrefix("menu:") }, "\(menu.buttonActions)")

        await telegram.reset()
        await orchestrator.dispatch(update: callback("menu:nav:pay:menu"))

        let pageCall = await telegram.waitForCall("editMessageText")
        let page = try XCTUnwrap(pageCall)
        XCTAssertTrue(page.contains("credits") || page.body.contains("премиум"), "not a purchase page: \(page.body)")
        XCTAssertTrue(page.buttonActions.contains("menu:open"), "no way back: \(page.buttonActions)")

        // Opening the purchase page is a funnel event, tagged with its source.
        let report = await store.funnelReport()
        XCTAssertEqual(report.counters[PurchaseSource.menu.counterKey], 1)
    }

    /// **Every** `super*` page must refuse a normal user — not just the one
    /// that happened to get a test. The gate names its pages one by one
    /// (CLAUDE.md §13), and a page left out of that list falls through to
    /// `default: break` and opens for anyone who guesses its callback_data.
    /// One page per loop iteration, so a new page joins the check for free.
    func testEverySuperAdminPageRefusesANormalUser() async throws {
        for page in MenuPage.allCases where page.rawValue.hasPrefix("super") {
            await telegram.reset()
            let data = BotCallbackAction.menu(action: MenuRoute.navigation(to: page)).rawData
            await orchestrator.dispatch(update: callback(data))

            let refusalCall = await telegram.waitForCall("answerCallbackQuery")
            let refusal = try XCTUnwrap(refusalCall, "\(page): no answer to the tap at all")
            XCTAssertTrue(
                refusal.body.contains("Только"),
                "\(page): expected a refusal toast, got: \(refusal.body)"
            )
            let edits = await telegram.calls("editMessageText")
            XCTAssertTrue(edits.isEmpty, "\(page) was rendered to a non-super-admin")
        }
    }

    /// A ⭐ mode tapped without access sells instead of refusing: the tap lands
    /// on the purchase page, tagged with the surface it came from, and the
    /// chat's settings are left exactly as they were.
    func testLockedModeTapOpensPurchaseAndChangesNothing() async throws {
        let chat = ChatKey(chatID: userID, threadID: 0)
        await store.setModeConfig(ModePresetConfig(
            enabled: true,
            modes: [
                ModePreset(id: "free", title: "⚡ Быстрый", subtitle: "быстро",
                           model: "free/model", temp: 1.0, maxHistory: 12, tier: .free),
                ModePreset(id: "smart", title: "🧠 Умный", subtitle: "умно",
                           model: "paid/smart", temp: 0.4, maxHistory: 40, tier: .premium),
            ],
            defaultModeID: "free"
        ))
        // Someone has to be on the free tier for the gate to fire.
        await store.setDailyPremiumLimit(0)
        let before = await store.fetchHelp(chatKey: chat)

        await orchestrator.dispatch(update: callback("menu:mode:pick:smart"))

        let pageCall = await telegram.waitForCall("editMessageText")
        let page = try XCTUnwrap(pageCall, "no page was rendered")
        XCTAssertTrue(page.body.contains("премиум") || page.contains("credits"),
                      "expected the purchase page, got: \(page.body)")

        let after = await store.fetchHelp(chatKey: chat)
        XCTAssertEqual(after.model, before.model, "a locked mode changed the chat's model")
        XCTAssertEqual(after.maxHistory, before.maxHistory)

        let report = await store.funnelReport()
        XCTAssertEqual(report.counters[PurchaseSource.mode.counterKey], 1,
                       "the mode paywall did not record its own surface")
    }

    /// A 🆓 mode applies the whole bundle in one tap — that is the difference
    /// between a mode and a model picker.
    func testFreeModeAppliesEverySettingAtOnce() async throws {
        let chat = ChatKey(chatID: userID, threadID: 0)
        await store.setModeConfig(ModePresetConfig(
            enabled: true,
            modes: [
                ModePreset(id: "free", title: "⚡ Быстрый", subtitle: "быстро",
                           model: "free/model", temp: 1.3, maxHistory: 12, tier: .free),
            ],
            defaultModeID: "free"
        ))

        await orchestrator.dispatch(update: callback("menu:mode:pick:free"))
        _ = await telegram.waitForCall("editMessageText")

        try await waitUntil { await self.store.fetchHelp(chatKey: chat).model == "free/model" }
        let help = await store.fetchHelp(chatKey: chat)
        XCTAssertEqual(help.temp, 1.3)
        XCTAssertEqual(help.maxHistory, 12)
    }

    /// The owner gets the page, and it carries the super-admin controls.
    func testSuperAdminPageOpensForTheOwner() async throws {
        await orchestrator.dispatch(update: callback("menu:nav:superadmin", userID: ownerID))

        let pageCall = await telegram.waitForCall("editMessageText")
        let page = try XCTUnwrap(pageCall)
        XCTAssertTrue(
            page.buttonActions.contains { $0.contains("superfunnel") || $0.contains("superstars") },
            "super-admin controls missing: \(page.buttonActions)"
        )
    }

    /// A referral deep link binds the pair, and the friend's first real answer
    /// pays both sides.
    func testReferralDeepLinkPaysAfterTheFirstAnswer() async throws {
        // The inviter has to be someone the bot has met.
        await orchestrator.dispatch(update: message("/start", userID: ownerID, username: "owner"))
        await telegram.reset()

        let friendID = 4_300
        await orchestrator.dispatch(update: message("/start ref_\(ownerID)", userID: friendID, username: "friend"))
        _ = await telegram.waitForCall("sendMessage")

        var inviterWallet = await store.balance(username: UserKey.forUserID(ownerID))
        XCTAssertNil(inviterWallet, "binding alone must not pay")

        await orchestrator.dispatch(update: message("первый вопрос", userID: friendID, username: "friend"))
        _ = await telegram.waitForCall("sendMessage", containing: "ответ модели")
        try await waitUntil { await self.store.balance(username: UserKey.forUserID(self.ownerID)) != nil }

        inviterWallet = await store.balance(username: UserKey.forUserID(ownerID))
        let friendWallet = await store.balance(username: UserKey.forUserID(friendID))
        XCTAssertEqual(inviterWallet?.balanceUsd, ReferralConfig.default.inviterRewardUsd)
        XCTAssertEqual(friendWallet?.balanceUsd, ReferralConfig.default.inviteeRewardUsd)
    }

    /// A paid-traffic link says nothing to the user but records the campaign.
    func testTrafficSourceLinkIsSilentButCounted() async throws {
        let visitorID = 4_400
        await orchestrator.dispatch(update: message("/start src_vk", userID: visitorID, username: "visitor"))
        _ = await telegram.waitForCall("sendMessage")

        let overview = await store.trafficSourceOverview()
        XCTAssertEqual(overview.rows.first?.tag, "vk")
        XCTAssertEqual(overview.rows.first?.tally.joined, 1)
        XCTAssertEqual(overview.rows.first?.tally.activated, 0, "a click is not an activation")

        await orchestrator.dispatch(update: message("вопрос", userID: visitorID, username: "visitor"))
        _ = await telegram.waitForCall("sendMessage", containing: "ответ модели")
        try await waitUntil { await self.store.trafficSourceOverview().rows.first?.tally.activated == 1 }

        let after = await store.trafficSourceOverview()
        XCTAssertEqual(after.rows.first?.tally.activated, 1)
    }

    /// Free tier: the daily premium taste runs out and the offer arrives with
    /// buttons that lead to the purchase page.
    func testDailyLimitOfferArrivesWhenTheAllowanceRunsOut() async throws {
        await store.setDailyPremiumLimit(1)
        await store.setFreeModelIDs(["free/model"])

        let freeUserID = 4_500
        await orchestrator.dispatch(update: message("первый", userID: freeUserID, username: "free"))
        _ = await telegram.waitForCalls("sendMessage", count: 1)

        await orchestrator.dispatch(update: message("второй", userID: freeUserID, username: "free"))
        let calls = await telegram.waitForCalls("sendMessage", count: 3)

        let offer = calls.first { $0.buttonActions.contains { $0.contains("nav:pay") } }
        XCTAssertNotNil(offer, "no purchase offer after the cap: \(calls.map(\.body))")

        let report = await store.funnelReport()
        XCTAssertEqual(report.counters[FunnelEvent.capHit.rawValue], 1)

        // The chat is parked on a free model until access appears.
        let help = await store.fetchHelp(chatKey: ChatKey(chatID: freeUserID, threadID: 0))
        XCTAssertEqual(help.model, "free/model")
    }

    /// Tapping an example is an ordinary question: the prompt is echoed and
    /// answered.
    func testOnboardingExampleTapRunsThePrompt() async throws {
        let config = await store.onboardingConfig()
        let example = try XCTUnwrap(config.activeExamples(inGroup: false).first)

        await orchestrator.dispatch(update: callback("ex:\(example.id)"))
        let echo = await telegram.waitForCall("sendMessage", containing: "blockquote")
        XCTAssertNotNil(echo, "the tapped prompt must be echoed into the chat")
        let answer = await telegram.waitForCall("sendMessage", containing: "ответ модели")
        XCTAssertNotNil(answer, "the tap must be answered like a typed question")

        let updated = await store.onboardingConfig().example(id: example.id)
        XCTAssertEqual(updated?.taps, 1)
    }

    /// A "type me a value" prompt armed in a group belongs to whoever tapped.
    /// Anyone else's message must go on to be answered normally instead of
    /// being eaten by the wait (and answered with "🔒 Только суперадмин…").
    func testPendingInputInAGroupDoesNotSwallowSomeoneElsesMessage() async throws {
        let group = -4_600

        // The owner (super-admin) taps "✏️ Изменить цену" in the group.
        await orchestrator.dispatch(update: callback("menu:stars:setprice", chatID: group, userID: ownerID, isGroup: true))
        try await waitUntil { await self.store.hasAnyPendingInput(chatKey: ChatKey(chatID: group, threadID: 0)) }
        await telegram.reset()

        // Another member speaks. The wait is not theirs to spend. In a group
        // the answer lands as an edit of the placeholder, not a new message.
        await orchestrator.dispatch(update: message("@testbot привет", chatID: group, userID: userID, isGroup: true))
        let answer = await telegram.waitForCall("editMessageText", containing: "ответ модели")
        XCTAssertNotNil(answer, "the other member's question was swallowed by someone else's prompt")

        let stillPending = await store.hasAnyPendingInput(chatKey: ChatKey(chatID: group, threadID: 0))
        XCTAssertTrue(stillPending, "the wait must survive a stranger's message")
        let priceUntouched = await store.starsPrice()
        XCTAssertNil(priceUntouched)

        // The owner's value lands.
        await telegram.reset()
        await orchestrator.dispatch(update: message("50", chatID: group, userID: ownerID, username: "owner", isGroup: true))
        try await waitUntil { await self.store.starsPrice() == 50 }

        let spent = await store.hasAnyPendingInput(chatKey: ChatKey(chatID: group, threadID: 0))
        XCTAssertFalse(spent, "an applied value must leave the slot empty")
    }

    /// An invalid value re-arms the same wait — and it must stay the owner's,
    /// otherwise the retry prompt starts eating the group's messages.
    func testInvalidValueRearmsTheWaitForTheSameOwner() async throws {
        let group = -4_601
        let chatKey = ChatKey(chatID: group, threadID: 0)

        await orchestrator.dispatch(update: callback("menu:stars:setprice", chatID: group, userID: ownerID, isGroup: true))
        try await waitUntil { await self.store.hasAnyPendingInput(chatKey: chatKey) }

        await telegram.reset()
        await orchestrator.dispatch(update: message("не число", chatID: group, userID: ownerID, username: "owner", isGroup: true))
        _ = await telegram.waitForCall("sendMessage", containing: "⚠️")

        let stillPending = await store.hasAnyPendingInput(chatKey: chatKey)
        XCTAssertTrue(stillPending, "a rejected value must leave the prompt armed")
        let owner = await store.pendingInputOwner(chatKey: chatKey)
        XCTAssertEqual(owner, UserKey.forUserID(ownerID), "the retry prompt lost its owner")
    }

    /// Buttons the bot sends outside the menu — the greeting, the daily-limit
    /// offer, the referral nudge — carry the same `menu:` payloads and are just
    /// as easy to mistype. Every one of them must route somewhere.
    func testEveryMenuButtonTheBotSendsRoutesSomewhere() async throws {
        await store.setDailyPremiumLimit(1)
        await store.setFreeModelIDs(["free/model"])

        let freeUserID = 4_700
        await orchestrator.dispatch(update: message("/start", userID: freeUserID, username: "free"))
        _ = await telegram.waitForCall("sendMessage")
        await orchestrator.dispatch(update: message("/menu", userID: freeUserID, username: "free"))
        _ = await telegram.waitForCalls("sendMessage", count: 2)
        await orchestrator.dispatch(update: message("/buy", userID: freeUserID, username: "free"))
        _ = await telegram.waitForCalls("sendMessage", count: 3)
        // Burn the allowance so the cap offer (and its buttons) is sent too.
        await orchestrator.dispatch(update: message("первый", userID: freeUserID, username: "free"))
        _ = await telegram.waitForCalls("sendMessage", count: 4)
        await orchestrator.dispatch(update: message("второй", userID: freeUserID, username: "free"))
        _ = await telegram.waitForCalls("sendMessage", count: 6)

        var checked = 0
        for call in await telegram.calls("sendMessage") + telegram.calls("editMessageText") {
            for data in call.buttonActions {
                guard case .menu(let action)? = BotCallbackAction(rawData: data) else { continue }
                checked += 1
                XCTAssertNotNil(MenuRoute(action: action), "dead button sent to the user: \(action)")
            }
        }
        XCTAssertGreaterThan(checked, 5, "no menu buttons were exercised — the check would pass vacuously")
    }

    /// Unknown callback data must not crash or go silent — the user gets a toast.
    func testUnknownCallbackIsAnswered() async throws {
        await orchestrator.dispatch(update: callback("menu:definitely-not-a-real-action"))
        let toastCall = await telegram.waitForCall("answerCallbackQuery")
        let toast = try XCTUnwrap(toastCall)
        XCTAssertFalse(toast.body.isEmpty)
    }

    /// Long answers are split, and every chunk stays inside Telegram's limit
    /// once escaped — the failure mode this guards is a 400 that loses text.
    func testLongAnswerIsSplitIntoValidChunks() async throws {
        // A model reply well past one message, full of characters that grow
        // when escaped (`<` → `&lt;`, `&` → `&amp;`).
        let long = String(repeating: "строка с < и & символами. ", count: 400)
        orchestrator = BotOrchestrator(
            telegram: TelegramHTTPGateway(
                network: NetworkClient(),
                botToken: "test-token",
                apiBase: baseURL,
                rateLimiter: nil,
                metrics: nil
            ),
            state: store,
            sessionRegistry: SessionRegistry(),
            mediaResolver: FakeMediaResolver(),
            providers: [.openrouter: FakeProviderGateway(reply: long)],
            persistence: nil,
            logger: SilentLogger(),
            metrics: RuntimeMetrics(),
            flags: RuntimeFlags(),
            generationLimiter: GenerationLimiter(maxConcurrent: 4),
            botUsername: botUsername,
            formatOptions: ""
        )

        await orchestrator.dispatch(update: message("дай длинный ответ"))
        let calls = await telegram.waitForCalls("sendMessage", count: 2)
        XCTAssertGreaterThanOrEqual(calls.count, 2, "a long answer must be split")

        for call in calls {
            // The body carries the final HTML, so the length Telegram measures
            // is the length of that string.
            XCTAssertLessThanOrEqual(
                (call.text ?? "").count,
                MessageSplitter.telegramMaxChars,
                "a chunk would come back as 400 'message is too long'"
            )
        }
    }
}
