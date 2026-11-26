import XCTest
@testable import LLM_chat_bot

/// Renders every page of the inline menu and checks the keyboards it produces.
///
/// This is the net under the callback refactor: a button carries a string, and
/// until somebody taps it nothing checks that the string means anything. Here
/// every button on every page is parsed back with the dispatcher's own rules,
/// so a dead button fails the build instead of a user's tap.
final class MenuPageRenderTests: XCTestCase {

    private var telegram: FakeTelegram!
    private var gateway: TelegramHTTPGateway!
    var store: ChatContextStore!
    var menu: BotMenuHandler!

    let ownerID: UserID = 7_000
    let plainID: UserID = 7_100

    override func setUp() async throws {
        telegram = FakeTelegram()
        let baseURL = try await telegram.start()
        store = Fixtures.makeStore(ownerUsername: "owner", ownerUserID: ownerID, model: "paid/model")
        gateway = TelegramHTTPGateway(
            network: NetworkClient(),
            botToken: "test-token",
            apiBase: baseURL,
            rateLimiter: nil,
            metrics: nil
        )
        menu = BotMenuHandler(
            telegram: gateway,
            state: store,
            gateways: ProviderGatewayRegistry(providers: [.openrouter: FakeProviderGateway(reply: "ok")]),
            logger: SilentLogger(),
            formatOptions: "",
            botUsername: "testbot"
        )
    }

    override func tearDown() async throws {
        await telegram.stop()
        telegram = nil
        gateway = nil
        menu = nil
        store = nil
    }

    /// Callback data as the dispatcher sees it: `menu:<action>`. Anything else
    /// (a URL button, the stop button) is not this test's business.
    func menuActions(_ markup: InlineKeyboardMarkup) -> [String] {
        markup.inline_keyboard
            .flatMap { $0 }
            .compactMap(\.callback_data)
            .compactMap { data in
                guard case .menu(let action)? = BotCallbackAction(rawData: data) else { return nil }
                return action
            }
    }

    /// Every page, in a DM and in a group, for the owner and for a stranger.
    func everyRendering() -> [(page: MenuPage, chat: ChatKey, user: UserKey)] {
        var cases: [(MenuPage, ChatKey, UserKey)] = []
        for page in MenuPage.allCases {
            for chat in [ChatKey(chatID: plainID.privateChat, threadID: 0), ChatKey(chatID: -7_200, threadID: 0)] {
                for user in [UserKey.identified(ownerID), UserKey.identified(plainID)] {
                    cases.append((page, chat, user))
                }
            }
        }
        return cases
    }

    // MARK: - Tests

    func testGroupMemberCanChangeWebDeepThinkAndRole() async throws {
        let store = Fixtures.makeStore(ownerUserID: ownerID, defaultProvider: .deepseekWeb)
        let gateways = ProviderGatewayRegistry(
            providers: [.openrouter: OpenRouterProviderAdapter(network: NetworkClient(), apiKey: "fixture")],
            web: DeepSeekWebProviderAdapter(network: NetworkClient(), port: 8765, token: "fixture")
        )
        let menu = BotMenuHandler(telegram: gateway, state: store, gateways: gateways, logger: SilentLogger(),
                                  formatOptions: "", botUsername: "testbot", canReadAllGroupMessages: false)
        let commands = BotCommandHandler(telegram: gateway, state: store, gateways: gateways,
                                         botUsername: "testbot", formatOptions: "", menuHandler: menu)
        let member = Fixtures.user(id: plainID, username: nil)
        let topic = ChatKey(chatID: -7_200, threadID: 8)
        let other = ChatKey(chatID: topic.chatID, threadID: 9)
        let message = MaybeInaccessibleMessage(chat: .init(id: topic.chatID, type: "supergroup"),
                                               message_id: 51, date: 1, text: "меню", message_thread_id: topic.threadID)

        func tap(_ action: String, as user: TelegramUser) async {
            await menu.handle(action: action, callback: .init(id: action, from: user, data: "menu:\(action)", message: message))
        }

        func send(_ text: String) async throws {
            let handled = try await commands.handleIfCommand(text: text, chatKey: topic, fromUser: member, isPrivate: false)
            XCTAssertTrue(handled)
        }

        await tap("nav:reasoning", as: member)
        let reasoningPage = await telegram.lastCall("editMessageText")
        XCTAssertTrue(reasoningPage?.buttonActions.contains("menu:reasoning:web:on") == true)
        await tap("reasoning:web:on", as: member)
        let deepThinkOn = await store.webState(chatKey: topic)?.deepThink
        XCTAssertEqual(deepThinkOn, true)
        try await send("/reasoning off")
        let deepThinkOff = await store.webState(chatKey: topic)?.deepThink
        XCTAssertEqual(deepThinkOff, false)

        await tap("nav:role", as: member)
        let rolePage = await telegram.lastCall("editMessageText")
        XCTAssertTrue(rolePage?.buttonActions.contains("menu:role:custom") == true)
        let originalEpoch = await store.webState(chatKey: topic)?.contextEpoch
        await tap("role:custom", as: member)
        let prompt = await telegram.lastCall("editMessageText")
        XCTAssertTrue(prompt?.text?.contains("Ответьте на это сообщение") == true)

        // A tap by someone else must leave the role prompt with its author.
        let otherMember = Fixtures.user(id: 7_101, username: nil)
        await tap("listen:on", as: otherMember)
        await menu.sendMenu(chatKey: topic, userID: otherMember.id)
        let strangerReply = await menu.processTextInput(text: "Чужой ответ", chatKey: topic,
                                                       userID: otherMember.id, replyToMessageID: message.message_id)
        let unrelated = await menu.processTextInput(text: "Другой вопрос", chatKey: topic,
                                                   userID: member.id, replyToMessageID: nil)
        let roleReply = await menu.processTextInput(text: "Отвечай как математик", chatKey: topic,
                                                   userID: member.id, replyToMessageID: message.message_id)
        XCTAssertFalse(strangerReply)
        XCTAssertFalse(unrelated)
        XCTAssertTrue(roleReply)
        let updated = await store.fetchHelp(chatKey: topic)
        let otherHelp = await store.fetchHelp(chatKey: other)
        let web = await store.webState(chatKey: topic)
        XCTAssertEqual(updated.role, "Отвечай как математик")
        XCTAssertNotEqual(otherHelp.role, updated.role)
        XCTAssertFalse(otherHelp.webDeepThinkEnabled)
        XCTAssertNotEqual(web?.contextEpoch, originalEpoch)
        XCTAssertEqual(web?.deepThink, false)

        try await send("/setrole Краткий ответ")
        let commandRole = await store.fetchHelp(chatKey: topic)
        XCTAssertEqual(commandRole.role, "Краткий ответ")
        await tap("role:default", as: member)
        let resetRole = await store.fetchHelp(chatKey: topic)
        XCTAssertEqual(resetRole.role, otherHelp.role)

        await tap("nav:listen", as: member)
        let listenPage = await telegram.lastCall("editMessageText")
        XCTAssertTrue(listenPage?.text?.contains("Прослушка беседы") == true)
        XCTAssertFalse(listenPage?.buttonActions.contains("menu:listen:on") == true)
        try await send("/listen on")
        let listening = await store.listening(chatKey: topic)
        let sharingAllowed = await store.webListeningAllowed(chatKey: topic)
        XCTAssertFalse(listening.isOn)
        XCTAssertFalse(sharingAllowed)

        _ = await store.changeProvider(chatKey: topic, newProvider: .openrouter)
        try await send("/reasoning high")
        await tap("reasoning:set:high", as: member)
        let apiReasoning = await store.reasoningEffort(chatKey: topic)
        XCTAssertNil(apiReasoning)
    }

    func testProviderListAndReasoningFollowTheSelectedService() async throws {
        let store = Fixtures.makeStore(ownerUserID: ownerID, defaultProvider: .deepseekWeb)
        let menu = BotMenuHandler(
            telegram: gateway,
            state: store,
            gateways: ProviderGatewayRegistry(
                providers: [.openrouter: OpenRouterProviderAdapter(network: NetworkClient(), apiKey: "fixture")],
                web: DeepSeekWebProviderAdapter(network: NetworkClient(), port: 8765, token: "fixture")
            ),
            logger: SilentLogger(),
            formatOptions: "",
            botUsername: "testbot"
        )
        let chat = ChatKey(chatID: ownerID.privateChat, threadID: 0)
        let owner = UserKey.identified(ownerID)
        _ = await store.seedBalance(key: owner, amount: .usd(1))
        let commands = BotCommandHandler(telegram: gateway, state: store, gateways: menu.gateways,
                                         botUsername: "testbot", formatOptions: "", menuHandler: menu)
        let user = Fixtures.user(id: ownerID, username: "owner")
        func sendCommand(_ text: String) async throws {
            let handled = try await commands.handleIfCommand(text: text, chatKey: chat, fromUser: user, isPrivate: true)
            XCTAssertTrue(handled)
        }
        let picker = await menu.renderPage(.provider, chatKey: chat, invoker: owner)
        let providerButtons = picker.markup.inline_keyboard.flatMap { $0 }
        XCTAssertTrue(providerButtons.contains { $0.text == "✓ DeepSeek Web" })
        XCTAssertTrue(providerButtons.contains { $0.text == "Openrouter" })
        XCTAssertTrue(providerButtons.contains { $0.text == "Deepseek · не настроен" })
        XCTAssertTrue(providerButtons.contains { $0.text == "Yandex · не настроен" })

        let main = await menu.renderPage(.main, chatKey: chat, invoker: owner)
        let mainActions = menuActions(main.markup)
        for page in [MenuPage.role, .history, .reasoning, .tuning, .presets] {
            XCTAssertTrue(mainActions.contains(MenuRoute.navigation(to: page)))
        }
        for page in [MenuPage.model, .temp, .provider, .stats] {
            XCTAssertFalse(mainActions.contains(MenuRoute.navigation(to: page)))
        }
        XCTAssertTrue(main.markup.inline_keyboard.flatMap { $0 }.contains { $0.text == "🧠 DeepThink" })
        let tuning = await menu.renderPage(.tuning, chatKey: chat, invoker: owner)
        let actions = menuActions(tuning.markup)
        for page in [MenuPage.provider, .tuningTemp, .stats] {
            XCTAssertTrue(actions.contains(MenuRoute.navigation(to: page)))
        }
        for page in [MenuPage.model, .history, .reasoning] {
            XCTAssertFalse(actions.contains(MenuRoute.navigation(to: page)))
        }
        XCTAssertTrue(actions.contains("mode:reset:tuning"))
        for page in [MenuPage.provider, .stats, .tuningTemp] {
            let screen = await menu.renderPage(page, chatKey: chat, invoker: owner)
            XCTAssertTrue(menuActions(screen.markup).contains("nav:tuning"))
        }
        let deepThink = await menu.renderPage(.reasoning, chatKey: chat, invoker: owner)
        XCTAssertEqual(menuActions(deepThink.markup).filter { $0.hasPrefix("reasoning:") },
                       ["reasoning:web:on", "reasoning:web:off"])

        try await sendCommand("/reasoning high")
        try await sendCommand("/reasoning on")
        let afterWebCommand = await store.fetchHelp(chatKey: chat)
        XCTAssertTrue(afterWebCommand.webDeepThinkEnabled)
        XCTAssertNil(afterWebCommand.reasoningEffort)

        try await sendCommand("/provider openrouter")
        let apiMain = await menu.renderPage(.main, chatKey: chat, invoker: owner)
        let apiActions = menuActions(apiMain.markup)
        XCTAssertTrue(apiActions.contains("nav:model"))
        XCTAssertTrue(apiActions.contains("nav:temp"))
        XCTAssertTrue(apiMain.markup.inline_keyboard.flatMap { $0 }.contains { $0.text.hasPrefix("🧠 Размышления") })
        XCTAssertFalse(apiMain.markup.inline_keyboard.flatMap { $0 }.contains { $0.text.contains("DeepThink") })
        let apiTemp = await menu.renderPage(.temp, chatKey: chat, invoker: owner)
        XCTAssertTrue(menuActions(apiTemp.markup).contains("open"))
        XCTAssertFalse(menuActions(apiTemp.markup).contains("nav:tuning"))
        let tunedTemp = await menu.renderPage(.tuningTemp, chatKey: chat, invoker: owner)
        XCTAssertTrue(menuActions(tunedTemp.markup).contains("nav:tuning"))
        XCTAssertFalse(menuActions(tunedTemp.markup).contains("open"))
        let reasoning = await menu.renderPage(.reasoning, chatKey: chat, invoker: owner)
        XCTAssertEqual(menuActions(reasoning.markup).filter { $0.hasPrefix("reasoning:") },
                       ["reasoning:set:low", "reasoning:set:medium", "reasoning:set:high", "reasoning:set:off"])
        try await sendCommand("/reasoning medium")
        try await sendCommand("/reasoning on")
        let afterAPICommands = await store.fetchHelp(chatKey: chat)
        XCTAssertEqual(afterAPICommands.provider, .openrouter)
        XCTAssertEqual(afterAPICommands.reasoningEffort, .medium)
        XCTAssertTrue(afterAPICommands.webDeepThinkEnabled)
    }

    /// No button may carry a callback the dispatcher cannot route. This is the
    /// failure the old `[String]` handling could not catch: a mistyped literal
    /// rendered fine and did nothing at all when tapped.
    func testEveryButtonOnEveryPageRoutesToAKnownCommand() async {
        for (page, chat, user) in everyRendering() {
            let markup = await menu.renderPage(page, chatKey: chat, invoker: user).markup
            for action in menuActions(markup) {
                XCTAssertNotNil(
                    MenuRoute(action: action),
                    "\(page) (chat \(chat.chatID), user \(user)) has a dead button: \(action)"
                )
            }
        }
    }

    /// A navigation button must point at a page that exists.
    func testEveryNavigationButtonPointsAtARealPage() async {
        for (page, chat, user) in everyRendering() {
            let markup = await menu.renderPage(page, chatKey: chat, invoker: user).markup
            for action in menuActions(markup) {
                guard let route = MenuRoute(action: action), route.command == .nav else { continue }
                XCTAssertNotNil(
                    route.page(1),
                    "\(page) links to a page that does not exist: \(action)"
                )
            }
        }
    }

    /// Every page must render something. An empty body is a 400 from Telegram,
    /// which reaches the user as a menu that stopped working.
    func testEveryPageRendersText() async {
        for (page, chat, user) in everyRendering() {
            let text = await menu.renderPage(page, chatKey: chat, invoker: user).text
            XCTAssertFalse(
                text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(page) rendered an empty body (chat \(chat.chatID))"
            )
        }
    }

    /// One message has a hard limit, and a page cannot be split across two
    /// (CLAUDE.md §13). Anything past the cap is silently cut off — half a page
    /// of super-admin settings that simply is not there.
    func testEveryPageFitsInOneMessage() async {
        for (page, chat, user) in everyRendering() {
            let screen = await menu.renderPage(page, chatKey: chat, invoker: user)
            XCTAssertTrue(
                screen.fitsInOneMessage,
                "\(page) is \(screen.text.count) chars and would be cut off"
            )
        }
    }

    /// The listen page has a branch the loop above never renders: the warning
    /// shown when Telegram's privacy mode is on. It is the longest thing on
    /// that page, and it is the one people will actually see — the setting is
    /// on by default.
    func testListenPageFitsWithThePrivacyWarning() async {
        let blind = BotMenuHandler(
            telegram: gateway,
            state: store,
            gateways: ProviderGatewayRegistry(providers: [.openrouter: FakeProviderGateway(reply: "ok")]),
            logger: SilentLogger(),
            formatOptions: "",
            botUsername: "testbot",
            canReadAllGroupMessages: false
        )
        let group = ChatKey(chatID: -7_300, threadID: 0)
        await store.setListenMode(chatKey: group, on: true)

        let screen = await blind.renderPage(.listen, chatKey: group, invoker: UserKey.identified(ownerID))
        XCTAssertTrue(screen.fitsInOneMessage, "\(screen.length) UTF-16 units")
        XCTAssertTrue(screen.text.contains("setprivacy"), "the one setting the feature cannot work without")
    }

    /// «📜 Что бот слышал» is the button that answers "а он вообще нас
    /// слышит?", so it is on the page whether or not the buffer has anything in
    /// it. Hiding it when empty took the diagnostic away in exactly the case
    /// somebody opens the page to ask.
    func testTheListenPageAlwaysOffersToShowWhatWasHeard() async {
        let group = ChatKey(chatID: -7_310, threadID: 0)
        let screen = await menu.renderPage(.listen, chatKey: group, invoker: UserKey.identified(ownerID))
        XCTAssertTrue(
            menuActions(screen.markup).contains("listen:dump"),
            "an empty buffer is the state that needs explaining most: \(menuActions(screen.markup))"
        )
    }

    /// "Fits" has to be measured the way Telegram measures — in UTF-16 code
    /// units. Every menu page starts with an emoji and is full of them; counting
    /// `Character`s said a page of emoji fits while the API was already cutting
    /// it, and a truncated page is settings that are simply not there.
    func testPageLengthIsMeasuredTheWayTelegramMeasuresIt() {
        let emoji = String(repeating: "🟢", count: MessageSplitter.telegramMaxChars / 2 + 1)
        let screen = MenuScreen(emoji)
        XCTAssertLessThan(emoji.count, MessageSplitter.telegramMaxChars, "premise: it looks short in characters")
        XCTAssertGreaterThan(screen.length, MessageSplitter.telegramMaxChars)
        XCTAssertFalse(screen.fitsInOneMessage, "an emoji is two units, not one")

        XCTAssertTrue(MenuScreen(String(repeating: "a", count: MessageSplitter.telegramMaxChars)).fitsInOneMessage)
    }

    /// A "← …" button must name the page it actually opens. The label used to
    /// be typed next to the destination at every call site, so the two could
    /// drift apart — and had: the same page was reached by "← К моему
    /// премиуму" from seven buttons and "← Назад" from three more.
    func testBackButtonsNameTheirDestination() async {
        for (page, chat, user) in everyRendering() {
            let markup = await menu.renderPage(page, chatKey: chat, invoker: user).markup
            for button in markup.inline_keyboard.flatMap({ $0 }) where button.text.hasPrefix("←") {
                guard let data = button.callback_data,
                      case .menu(let action)? = BotCallbackAction(rawData: data),
                      let route = MenuRoute(action: action),
                      route.command == .nav,
                      let destination = route.page(1)
                else { continue }
                XCTAssertEqual(
                    button.text,
                    destination.backLabel,
                    "\(page): button \"\(button.text)\" leads to \(destination), which is called \"\(destination.backLabel)\""
                )
            }
        }
    }

    /// A personal page never draws its contents into a group: the menu is one
    /// shared message, so whatever it renders, everyone reads.
    func testPersonalPagesRefuseToRenderInAGroup() async {
        let group = ChatKey(chatID: -7_300, threadID: 0)
        await store.seedBalance(key: UserKey.identified(ownerID), amount: .usd(12.34))

        for page in MenuPage.allCases where page.isPersonal {
            let text = await menu.renderPage(page, chatKey: group, invoker: UserKey.identified(ownerID)).text
            XCTAssertEqual(text, page.privateOnlyNotice, "\(page) rendered its contents into a group")
            XCTAssertFalse(text.contains("12.34"), "\(page) leaked a wallet into a group")
        }
    }

    /// The redraw path has to gate exactly like the tap path. It runs after a
    /// typed value — minutes after the button was pressed, long enough for a
    /// licence to lapse or a super-admin to be taken off the roster — and it
    /// used to check only two of the four audiences, so an admin or super-admin
    /// page was redrawn for whoever no longer had the right to see it.
    func testRoleGatedPagesRefuseSomebodyWhoLostTheRole() async {
        let chat = ChatKey(chatID: plainID.privateChat, threadID: 0)
        let stranger = UserKey.identified(plainID)

        for page in MenuPage.allCases where page.access == .superAdmin || page.access == .chatOperator {
            let screen = await menu.renderPage(page, chatKey: chat, invoker: stranger)
            XCTAssertEqual(
                screen.text,
                page.restrictedNotice,
                "\(page) drew the owner's settings for somebody without the role"
            )
        }

        // …and still opens for the owner, or the gate would be a wall.
        for page in MenuPage.allCases where page.access == .superAdmin || page.access == .chatOperator {
            let screen = await menu.renderPage(page, chatKey: chat, invoker: UserKey.identified(ownerID))
            XCTAssertNotEqual(screen.text, page.restrictedNotice, "\(page) refused the owner")
        }
    }

    /// The audience of a page is data, not a list somebody remembers to update.
    /// Every `super*` page must say so on the type — that is what both gates
    /// read, and a page in the wrong bucket opens for everyone who taps it.
    func testEverySuperPageDeclaresItsAudience() {
        for page in MenuPage.allCases where page.rawValue.hasPrefix("super") {
            XCTAssertEqual(page.access, .superAdmin, "\(page) is not gated as a super-admin page")
        }
        for page in MenuPage.allCases where page.rawValue.hasPrefix("admin") {
            XCTAssertEqual(page.access, .chatOperator, "\(page) is not gated as an admin page")
        }
        // Every refusal says something: a button that goes quiet reads as a
        // broken bot rather than as a "no".
        for page in MenuPage.allCases where page.access != .everyone {
            XCTAssertFalse(page.restrictedNotice.isEmpty, "\(page) refuses without a word")
        }
    }

    /// Hand-tuning is what premium unlocks. A free chat gets the offer instead
    /// of the controls — on the page itself, not only behind the nav gate,
    /// because a menu redrawn after a typed value never passes that gate.
    func testRestrictedPagesRefuseAFreeChat() async {
        let chat = ChatKey(chatID: plainID.privateChat, threadID: 0)
        let stranger = UserKey.identified(plainID)

        for page in MenuPage.allCases where page.access == .paidAccess {
            let screen = await menu.renderPage(page, chatKey: chat, invoker: stranger)
            XCTAssertEqual(screen.text, page.restrictedNotice, "\(page) rendered its controls for a free chat")
        }

        // A wallet is enough — the line is "pays for something", not "has a
        // subscription" (CLAUDE.md §6, `hasFullModelAccess`).
        await store.seedBalance(key: stranger, amount: .usd(1.0))
        for page in MenuPage.allCases where page.access == .paidAccess {
            let screen = await menu.renderPage(page, chatKey: chat, invoker: stranger)
            XCTAssertNotEqual(screen.text, page.restrictedNotice, "\(page) still refused a paying chat")
        }
    }

    /// Memory length re-sends every remembered message on every turn, so it is
    /// the owner's lever. The page stays readable; the controls do not.
    func testMemoryLengthControlsAreOwnerOnly() async {
        let chat = ChatKey(chatID: plainID.privateChat, threadID: 0)

        let strangerActions = await menuActions(
            menu.renderPage(.history, chatKey: chat, invoker: UserKey.identified(plainID)).markup
        )
        XCTAssertFalse(
            strangerActions.contains { $0.hasPrefix("history:length") || $0 == "history:custom" },
            "a regular user could change how much the bot remembers"
        )

        let ownerActions = await menuActions(
            menu.renderPage(.history, chatKey: chat, invoker: UserKey.identified(ownerID)).markup
        )
        XCTAssertTrue(
            ownerActions.contains { $0 == "history:custom" },
            "the owner lost the control they are the only one allowed to use"
        )
    }

    /// All configured modes live in Presets, retaining their access markers.
    func testSettingsPageOffersModesAndMarksLockedOnes() async {
        let chat = ChatKey(chatID: plainID.privateChat, threadID: 0)
        let user = UserKey.identified(plainID)
        let main = await menu.renderPage(.main, chatKey: chat, invoker: user)
        let mainActions = menuActions(main.markup)
        XCTAssertTrue(mainActions.contains("nav:presets"))
        XCTAssertFalse(mainActions.contains { $0.hasPrefix("mode:pick:") || $0.hasPrefix("mode:reset") })

        let screen = await menu.renderPage(.presets, chatKey: chat, invoker: user)
        let picks = menuActions(screen.markup).filter { $0.hasPrefix("mode:pick:") }
        let modes = await store.modeConfig().activeModes
        XCTAssertFalse(modes.isEmpty)
        XCTAssertEqual(picks, modes.map { "mode:pick:\($0.id)" })
        XCTAssertTrue(menuActions(screen.markup).contains("open"))

        let labels = screen.markup.inline_keyboard.flatMap { $0 }.map(\.text)
        XCTAssertTrue(labels.contains { $0.hasSuffix("⭐") }, "no locked mode is advertised to a free chat")
    }


    func testPaywallReturnsToTheSettingThatOpenedIt() async throws {
        let chat = ChatKey(chatID: plainID.privateChat, threadID: 0)
        let user = Fixtures.user(id: plainID, username: "plain")
        let message = MaybeInaccessibleMessage(chat: .init(id: chat.chatID, type: "private"),
                                               message_id: 53, date: 1, text: "меню", message_thread_id: nil)
        await store.setDailyPremiumLimit(0)
        let config = await store.modeConfig()
        let locked = try XCTUnwrap(config.activeModes.first { $0.tier != .free })

        for (action, back) in [("nav:tuningtemp", "nav:tuning"), ("nav:temp", "nav:main"),
                               ("mode:pick:\(locked.id)", "nav:presets")] {
            await menu.handle(action: action, callback: .init(id: action, from: user, data: "menu:\(action)", message: message))
            let paywall = await telegram.lastCall("editMessageText")
            let actions = paywall?.buttonActions ?? []
            XCTAssertTrue(actions.contains("menu:\(back)") || (back == "nav:main" && actions.contains("menu:open")), action)
        }
    }

    func testPresetAndTuningCallbacksReturnToTheirOwnPages() async throws {
        let chat = ChatKey(chatID: ownerID.privateChat, threadID: 0)
        let user = Fixtures.user(id: ownerID, username: "owner")
        let message = MaybeInaccessibleMessage(chat: .init(id: chat.chatID, type: "private"),
                                               message_id: 52, date: 1, text: "меню", message_thread_id: nil)
        _ = await store.seedBalance(key: .identified(ownerID), amount: .usd(1))
        let config = await store.modeConfig()
        let preset = try XCTUnwrap(config.activeModes.first { $0.tier == .free })

        func tap(_ action: String) async {
            await menu.handle(action: action, callback: .init(id: action, from: user, data: "menu:\(action)", message: message))
        }
        await tap("nav:presets")
        await tap("mode:pick:\(preset.id)")
        let selected = await telegram.lastCall("editMessageText")
        XCTAssertTrue(selected?.text?.contains("Пресеты") == true)
        XCTAssertTrue(selected?.buttonActions.contains("menu:open") == true)
        await tap("open")
        let main = await telegram.lastCall("editMessageText")
        XCTAssertTrue(main?.buttonActions.contains("menu:nav:presets") == true)
        await tap("nav:tuning")
        await tap("mode:reset:tuning")
        let tuning = await telegram.lastCall("editMessageText")
        XCTAssertTrue(tuning?.buttonActions.contains("menu:nav:stats") == true)
        await tap("nav:provider")
        let provider = await telegram.lastCall("editMessageText")
        XCTAssertTrue(provider?.buttonActions.contains("menu:nav:tuning") == true)
        await tap("nav:tuning")
        let returned = await telegram.lastCall("editMessageText")
        XCTAssertTrue(returned?.buttonActions.contains("menu:nav:stats") == true)

        await tap("nav:tuningtemp")
        let style = await telegram.lastCall("editMessageText")
        XCTAssertTrue(style?.buttonActions.contains("menu:nav:tuning") == true)
        XCTAssertFalse(style?.buttonActions.contains("menu:open") == true)
        await tap("temp:0.5:tuningtemp")
        let applied = await telegram.lastCall("editMessageText")
        XCTAssertTrue(applied?.buttonActions.contains("menu:nav:tuning") == true)

        await tap("temp:custom:tuningtemp")
        let prompt = await telegram.lastCall("editMessageText")
        XCTAssertTrue(prompt?.buttonActions.contains("menu:nav:tuningtemp") == true)
        let handled = await menu.processTextInput(text: "0.7", chatKey: chat, userID: ownerID, replyToMessageID: nil)
        XCTAssertTrue(handled)
        let saved = await telegram.lastCall("editMessageText")
        XCTAssertTrue(saved?.buttonActions.contains("menu:nav:tuning") == true)

        await tap("pm:tuningtemp")
        let editor = await telegram.lastCall("editMessageText")
        XCTAssertTrue(editor?.buttonActions.contains("menu:nav:tuningtemp") == true)
        await tap("pm:tuningtemp:add")
        let presetPrompt = await telegram.lastCall("editMessageText")
        XCTAssertTrue(presetPrompt?.buttonActions.contains("menu:pm:tuningtemp") == true)
        let savedPreset = await menu.processTextInput(text: "Факты | 0.3", chatKey: chat, userID: ownerID, replyToMessageID: nil)
        XCTAssertTrue(savedPreset)
        let refreshed = await telegram.lastCall("editMessageText")
        XCTAssertTrue(refreshed?.buttonActions.contains("menu:nav:tuningtemp") == true)

        await tap("nav:temp")
        let fromMain = await telegram.lastCall("editMessageText")
        XCTAssertTrue(fromMain?.buttonActions.contains("menu:open") == true)
        XCTAssertFalse(fromMain?.buttonActions.contains("menu:nav:tuning") == true)
    }
}
