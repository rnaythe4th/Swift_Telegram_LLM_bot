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
    private var store: ChatContextStore!
    private var menu: BotMenuHandler!

    private let ownerID: UserID = 7_000
    private let plainID: UserID = 7_100

    override func setUp() async throws {
        telegram = FakeTelegram()
        let baseURL = try await telegram.start()
        store = Fixtures.makeStore(ownerUsername: "owner", ownerUserID: ownerID, model: "paid/model")
        menu = BotMenuHandler(
            telegram: TelegramHTTPGateway(
                network: NetworkClient(),
                botToken: "test-token",
                apiBase: baseURL,
                rateLimiter: nil,
                metrics: nil
            ),
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

    /// The purchase page in a group is a price list, not somebody's account.
    func testGroupPurchasePageCarriesNoPersonalNumbers() async {
        await store.seedBalance(key: UserKey.identified(ownerID), amount: .usd(9.87))
        let group = ChatKey(chatID: -7_400, threadID: 0)

        let text = await menu.renderPage(.pay, chatKey: group, invoker: UserKey.identified(ownerID)).text
        XCTAssertFalse(text.contains("9.87"), "the shared purchase page showed a member's balance")
    }
}
