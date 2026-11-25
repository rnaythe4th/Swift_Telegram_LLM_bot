import XCTest
@testable import LLM_chat_bot

extension MenuPageRenderTests {
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
