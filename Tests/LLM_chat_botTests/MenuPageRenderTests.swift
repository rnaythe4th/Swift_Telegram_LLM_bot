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
    private var store: ChatContextStore!
    private var menu: BotMenuHandler!

    private let ownerID: UserID = 7_000
    private let plainID: UserID = 7_100

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
    private func menuActions(_ markup: InlineKeyboardMarkup) -> [String] {
        markup.inline_keyboard
            .flatMap { $0 }
            .compactMap(\.callback_data)
            .compactMap { data in
                guard case .menu(let action)? = BotCallbackAction(rawData: data) else { return nil }
                return action
            }
    }

    /// Every page, in a DM and in a group, for the owner and for a stranger.
    private func everyRendering() -> [(page: MenuPage, chat: ChatKey, user: UserKey)] {
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

    /// The settings page leads with modes, and a ⭐ one stays visible to a free
    /// chat: a ceiling nobody can see is a ceiling nobody pays to lift.
    func testSettingsPageOffersModesAndMarksLockedOnes() async {
        let chat = ChatKey(chatID: plainID.privateChat, threadID: 0)
        let screen = await menu.renderPage(.main, chatKey: chat, invoker: UserKey.identified(plainID))

        let picks = menuActions(screen.markup).filter { $0.hasPrefix("mode:pick:") }
        XCTAssertFalse(picks.isEmpty, "the settings page offers no modes at all")

        let labels = screen.markup.inline_keyboard.flatMap { $0 }.map(\.text)
        XCTAssertTrue(labels.contains { $0.hasSuffix("⭐") }, "no locked mode is advertised to a free chat")
    }

    /// Telegram caps `callback_data` at 64 bytes and refuses the *whole*
    /// message when one button is over it, so an oversized payload does not
    /// disable a button — it stops the page from opening at all. Every button
    /// on every page has to stay inside the cap, including the ones carrying a
    /// preset the owner typed in.
    func testNoButtonCarriesAPayloadTelegramWouldReject() async {
        // Longer than the 48 characters that fit after `menu:model:gsel:` —
        // OpenRouter really does list ids this long.
        let longModelID = "cognitivecomputations/dolphin3.0-r1-mistral-24b:free"
        XCTAssertGreaterThan(longModelID.utf8.count, 48, "this id is too short to prove anything")

        let chat = ChatKey(chatID: plainID.privateChat, threadID: 0)
        _ = await store.addPreset(category: .model, display: "Длинная", value: longModelID, chatID: chat.chatID)
        _ = await store.addChatPreset(category: .model, chatKey: chat, display: "Своя длинная", value: longModelID)
        await store.addFreeModel(longModelID)

        for (page, chatKey, user) in everyRendering() {
            let markup = await menu.renderPage(page, chatKey: chatKey, invoker: user).markup
            for button in markup.inline_keyboard.flatMap({ $0 }) {
                guard let data = button.callback_data else { continue }
                XCTAssertLessThanOrEqual(
                    data.utf8.count, MenuRoute.maxCallbackDataBytes,
                    "\(page): \"\(button.text)\" carries \(data.utf8.count) bytes — Telegram would refuse the whole page"
                )
            }
        }
    }

    /// …and the button still means what it says: the payload it carries has to
    /// resolve back to the preset it was drawn for, or the page renders and
    /// nothing happens when it is tapped.
    func testAModelButtonResolvesBackToItsPreset() async {
        let longModelID = "cognitivecomputations/dolphin3.0-r1-mistral-24b:free"
        let chat = ChatKey(chatID: plainID.privateChat, threadID: 0)
        _ = await store.addPreset(category: .model, display: "Длинная", value: longModelID, chatID: chat.chatID)

        let presets = await store.modelPresets(chatID: chat.chatID)
        let markup = await menu.renderPage(.model, chatKey: chat, invoker: UserKey.identified(ownerID)).markup
        let tokens = menuActions(markup)
            .compactMap { MenuRoute(action: $0) }
            .filter { $0.command == .model && $0.sub == "gsel" }
            .compactMap { $0.arg(2) }

        XCTAssertEqual(tokens.count, presets.count, "the picker did not draw one button per preset")
        for (token, preset) in zip(tokens, presets) {
            XCTAssertEqual(
                BotMenuHandler.presetTarget(token, in: presets)?.value, preset.value,
                "button payload \"\(token)\" does not lead back to \(preset.value)"
            )
        }

        // Buttons in messages an older build already sent carry the value
        // itself; they have to keep working.
        XCTAssertEqual(BotMenuHandler.presetTarget(longModelID, in: presets)?.value, longModelID)
    }

    /// Text a person typed is escaped where it becomes markup.
    ///
    /// «✏️ Своя модель» and «✏️ Своя роль» are open to every member of a chat,
    /// and both values are printed into HTML on four pages. An unescaped `<`
    /// does not garble a page — Telegram refuses the whole message, so the menu
    /// stops opening at all, in a group for everybody, and the only way back is
    /// a command. One member could switch off the chat's menu with one message.
    func testTypedModelAndRoleCannotBreakThePagesTheyAppearOn() async {
        let chat = ChatKey(chatID: plainID.privateChat, threadID: 0)
        _ = await store.setModelAndResetHistory(chatKey: chat, newModel: "<b>evil</b>/model", providerRouting: "<i>up</i>")
        _ = await store.setRoleAndResetHistory(chatKey: chat, role: "Ты <script>alert(1)</script> & друг")

        for page in [MenuPage.main, .model, .role, .tuning] {
            let text = await menu.renderPage(page, chatKey: chat, invoker: UserKey.identified(plainID)).text
            XCTAssertFalse(text.contains("<b>evil"), "\(page) printed a typed model id as markup")
            XCTAssertFalse(text.contains("<script>"), "\(page) printed a typed role as markup")
            XCTAssertFalse(text.contains("<i>up</i>"), "\(page) printed a typed provider pin as markup")
        }
    }

    /// The same rule for a preset: any member of a chat can add one, and its
    /// name is printed in the price list on the model page.
    func testAPresetNameCannotBreakTheModelPage() async {
        let chat = ChatKey(chatID: -7_500, threadID: 0)
        _ = await store.addChatPreset(category: .model, chatKey: chat, display: "<b>free", value: "openai/gpt-4o")
        await store.updateOpenRouterModelPrices(["openai/gpt-4o": ModelPriceInfo(inputPerToken: 0.000_01, outputPerToken: 0.000_03)])

        let text = await menu.renderPage(.model, chatKey: chat, invoker: UserKey.identified(plainID)).text
        XCTAssertTrue(text.contains("&lt;b&gt;free"), "the preset name was not escaped into the price list")
        XCTAssertFalse(text.contains("<b>free"), "a preset name reached the page as markup")
    }

    /// A button that changes something carries the record's id, never its row
    /// number: these two pages reorder and delete their own lists, so a
    /// position describes the keyboard rather than the thing it was drawn for —
    /// and «❌» then hits the neighbour.
    func testEditorButtonsCarryIdsRatherThanPositions() async {
        let chat = ChatKey(chatID: ownerID.privateChat, threadID: 0)

        let modeIDs = Set(await store.modeConfig().modes.map(\.id))
        XCTAssertFalse(modeIDs.isEmpty, "premise: there are modes to address")
        let modeArguments = await menuActions(menu.renderPage(.superModes, chatKey: chat, invoker: UserKey.identified(ownerID)).markup)
            .compactMap { MenuRoute(action: $0) }
            .filter { $0.command == .smode && ["on", "tier", "edit", "role", "work", "up", "del"].contains($0.sub) }
            .compactMap { $0.arg(2) }
        XCTAssertFalse(modeArguments.isEmpty, "the editor drew no per-mode buttons")
        for argument in modeArguments {
            XCTAssertTrue(modeIDs.contains(argument), "a mode button carries \"\(argument)\", which is not a mode id")
        }

        let exampleIDs = Set(await store.onboardingConfig().examples.map(\.id))
        let exampleArguments = await menuActions(menu.renderPage(.superOnboarding, chatKey: chat, invoker: UserKey.identified(ownerID)).markup)
            .compactMap { MenuRoute(action: $0) }
            .filter { $0.command == .onb && ["on", "place", "edit", "up", "del"].contains($0.sub) }
            .compactMap { $0.arg(2) }
        XCTAssertFalse(exampleArguments.isEmpty, "the editor drew no per-example buttons")
        for argument in exampleArguments {
            XCTAssertTrue(exampleIDs.contains(argument), "an example button carries \"\(argument)\", which is not an example id")
        }
    }

    /// Wallets, tenants and super-admins are addressed by their storage key.
    /// Interpolating the key wrote `UserKey(#42)`, which reads back as a
    /// pending handle belonging to nobody — every destructive button on those
    /// pages answered «не найдено» and left the record alone.
    func testKeyCarryingButtonsAddressTheRecordTheyWereDrawnFor() async {
        let chat = ChatKey(chatID: ownerID.privateChat, threadID: 0)
        let payer = UserKey.identified(plainID)
        await store.seedBalance(key: payer, amount: .usd(3))
        await store.registerTenant(payer)

        for page in [MenuPage.superBalances, .superTenants, .superAdmins] {
            let keys = await menuActions(menu.renderPage(page, chatKey: chat, invoker: UserKey.identified(ownerID)).markup)
                .compactMap { MenuRoute(action: $0) }
                .filter { ["rm", "rmyes", "info", "ext", "unlim", "exp"].contains($0.sub) }
                .compactMap { $0.userKey(2) }
            XCTAssertFalse(keys.isEmpty, "\(page) drew no button addressing a record")
            for key in keys {
                XCTAssertTrue(key.isIdentified, "\(page) addressed \(key.storageValue), which is not a stored key")
            }
        }
    }

    /// The purchase page in a group is a price list, not somebody's account.
    func testGroupPurchasePageCarriesNoPersonalNumbers() async {
        await store.seedBalance(key: UserKey.identified(ownerID), amount: .usd(9.87))
        let group = ChatKey(chatID: -7_400, threadID: 0)

        let text = await menu.renderPage(.pay, chatKey: group, invoker: UserKey.identified(ownerID)).text
        XCTAssertFalse(text.contains("9.87"), "the shared purchase page showed a member's balance")
    }
}
