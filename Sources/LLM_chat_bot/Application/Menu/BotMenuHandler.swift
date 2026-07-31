import Foundation

// The inline menu. Wiring, the callback dispatcher and page rendering live
// here; the pages themselves are split across BotMenuHandler+*.swift by area.

final class BotMenuHandler: @unchecked Sendable {
    let telegram: TelegramGatewayPort
    let state: ChatContextStore
    let gateways: ProviderGatewayRegistry
    let logger: LoggerPort
    let formatOptions: String
    let botUsername: String
    let modelPriceMonitor: ModelPriceMonitor?
    let cryptoService: CryptoPaymentService?
    let reminderService: SubscriptionReminderService?

    init(
        telegram: TelegramGatewayPort,
        state: ChatContextStore,
        gateways: ProviderGatewayRegistry,
        logger: LoggerPort,
        formatOptions: String,
        botUsername: String = "",
        modelPriceMonitor: ModelPriceMonitor? = nil,
        cryptoService: CryptoPaymentService? = nil,
        reminderService: SubscriptionReminderService? = nil
    ) {
        self.telegram = telegram
        self.state = state
        self.gateways = gateways
        self.logger = logger
        self.formatOptions = formatOptions
        self.botUsername = botUsername
        self.modelPriceMonitor = modelPriceMonitor
        self.cryptoService = cryptoService
        self.reminderService = reminderService
    }

    /// Plain chat message, no keyboard — used for the short confirmations and
    /// refusals that follow a typed value.
    func sendPlain(chatKey: ChatKey, text: String) async {
        _ = try? await telegram.sendMessage(.init(
            chatID: chatKey.chatID,
            threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
            replyTo: nil,
            text: text,
            replyMarkup: nil
        ))
    }

    /// Storage key of whoever tapped the button, always resolvable: a callback
    /// always carries a userID, while a @username is optional and rentable. Role
    /// gates keyed off the raw handle locked out anyone without one — including
    /// a super-admin whose record sits under `#<userID>` (CLAUDE.md §6). Store
    /// APIs that take `username:` pass a key through unchanged.
    func invokerKey(_ callback: CallbackQuery) -> String {
        state.userKey(userID: callback.from.id)
    }

    func handle(action rawAction: String, callback: CallbackQuery) async {
        guard let message = callback.message else {
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Сообщение недоступно")
            return
        }

        let chatKey = ChatKey(chatID: message.chat.id, threadID: message.message_thread_id ?? 0)
        guard let route = MenuRoute(action: rawAction) else {
            // An unknown command never reaches a handler. Answering is not
            // optional: a button that does nothing reads as a broken bot.
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Неизвестное действие")
            return
        }

        do {
            try await processAction(route: route, chatKey: chatKey, callback: callback, message: message)
        } catch {
            logger.error("menu action failed: \(error)")
            let alertText = UserFacingError.shortMessage(error, context: "Ошибка")
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: alertText)
        }
        // Whatever the action armed (if anything) belongs to whoever tapped:
        // in a group the next message can come from someone else entirely.
        await state.notePendingInputOwner(invokerKey(callback), chatKey: chatKey)
    }

    func sendMenu(chatKey: ChatKey, userID: Int? = nil, username: String? = nil) async {
        let username = userID.map { self.state.userKey(userID: $0) } ?? username
        await state.clearPending(chatKey: chatKey)
        let screen = await renderPage(.main, chatKey: chatKey, username: username)
        _ = try? await telegram.sendMessage(
            .init(
                chatID: chatKey.chatID,
                threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                replyTo: nil,
                text: screen.text,
                replyMarkup: screen.markup
            )
        )
    }

    private func processAction(
        route: MenuRoute,
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        switch route.command {
        case .open, .close, .nav, .noop:
            try await processNavigationAction(route: route, chatKey: chatKey, callback: callback, message: message)

        case .role, .model, .temp, .stats, .history, .provider, .reasoning, .reset, .help:
            try await processChatSettingsAction(route: route, chatKey: chatKey, callback: callback, message: message)

        case .mode, .smode:
            try await processModeAction(route: route, chatKey: chatKey, callback: callback, message: message)

        case .pm:
            try await processPresetAction(route: route, chatKey: chatKey, callback: callback, message: message)

        case .buy:
            try await processPurchaseAction(route: route, chatKey: chatKey, callback: callback, message: message)

        case .tenant, .wl, .def:
            try await processAdminAction(route: route, chatKey: chatKey, callback: callback, message: message)

        case .sa, .stenant, .sim, .sinspect, .ads, .markup, .dailylimit,
             .stars, .freemodels, .sbal, .crypto, .card:
            try await processSuperAdminAction(route: route, chatKey: chatKey, callback: callback, message: message)

        case .funnel, .promo, .rem, .examples, .onb, .sref, .strf:
            try await processGrowthAction(route: route, chatKey: chatKey, callback: callback, message: message)

        case .sahelp:
            try await processHelpAction(route: route, chatKey: chatKey, callback: callback, message: message)
        }
    }

    /// Menu navigation: open, close, page jumps.
    private func processNavigationAction(
        route: MenuRoute,
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        switch route.command {
        case .open:
            await state.clearPending(chatKey: chatKey)
            try await showPage(.main, chatKey: chatKey, callback: callback, message: message)

        case .close:
            await state.clearPending(chatKey: chatKey)
            try await closeMenu(callback: callback, message: message)

        case .nav:
            // Navigating away abandons any text-input prompt (incl. the
            // "❌ Отмена" buttons, which all point at nav:*).
            await state.clearPending(chatKey: chatKey)
            guard let menuPage = route.page(1) else {
                try await showPage(.main, chatKey: chatKey, callback: callback, message: message)
                return
            }
            if menuPage.requiresOperator {
                guard await requireOperator(callback, chatKey: chatKey, refusal: menuPage.restrictedNotice) else { return }
            } else if menuPage.requiresFullAccess, !(await hasFullAccess(callback, chatKey: chatKey)) {
                // Sell rather than refuse. This is somebody actively reaching
                // for something premium includes, which is the one moment a
                // paywall is welcome instead of annoying (GROWTH.md P0.4).
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: menuPage.restrictedNotice)
                try await showPage(.pay, chatKey: chatKey, callback: callback, message: message, purchaseSource: .tuning)
                return
            }
            switch menuPage {
            // Every `super*` page belongs here — the buttons inside them are
            // gated separately, but the pages themselves show the owner's
            // configuration and numbers.
            case .superAdmin, .superAdminHelp, .superStars, .superCrypto, .superCard, .superFreeModels, .superTenants, .superAdmins, .superSimulate, .superChats, .superAds, .superBalances, .superFunnel, .superReminders, .superOnboarding, .superModes, .superReferrals, .superTraffic:
                guard await requireSuperAdmin(callback) else { return }
            case .adminPanel, .adminHelp, .adminChats, .adminUsers, .adminWhitelist, .adminDefaults, .adminInvite:
                guard await requireAdmin(callback, chatKey: chatKey) else { return }
            default:
                break
            }
            // `nav:pay:<source>` — the optional third token says which surface
            // sent the person here; anything unknown reads as the plain menu.
            try await showPage(
                menuPage,
                chatKey: chatKey,
                callback: callback,
                message: message,
                purchaseSource: PurchaseSource.parse(route.arg(2))
            )

        case .noop:
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: nil)
            return

        default:
            break
        }
    }

    func showPage(
        _ page: MenuPage,
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage,
        purchaseSource: PurchaseSource = .menu
    ) async throws {
        // A shared menu message must never render a personal page: the answer
        // would be visible to everyone in the group, not just to whoever tapped.
        if page.isPersonal, chatKey.chatID < 0 {
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: page.privateOnlyNotice)
            return
        }
        // Funnel: reaching the purchase page counts as "opened purchase", and
        // the button that led here is counted separately — that is how the
        // pain-point upsells get compared with the plain menu (steps 5 and 7).
        if page == .pay { await state.bumpPurchaseOpen(source: purchaseSource) }
        let screen = await renderPage(page, chatKey: chatKey, username: state.userKey(userID: callback.from.id))
        warnIfOversized(screen, page: page)
        try await editOrAnswer(callback: callback, message: message, screen: screen)
    }

    /// A page that outgrew one message comes back with its tail cut off — and
    /// nothing says so, because `editMessage` cannot be split in two. The lists
    /// on `super*` pages are already capped for exactly this reason; this turns
    /// the remaining cases from an invisible truncation into a log line naming
    /// the page.
    private func warnIfOversized(_ screen: MenuScreen, page: MenuPage) {
        guard !screen.fitsInOneMessage else { return }
        logger.warning("menu page \(page.rawValue) is \(screen.text.count) chars and will be truncated")
    }

    private func closeMenu(callback: CallbackQuery, message: MaybeInaccessibleMessage) async throws {
        let chatKey = ChatKey(chatID: message.chat.id, threadID: message.message_thread_id ?? 0)
        await state.clearPending(chatKey: chatKey)
        try await telegram.editMessage(
            .init(
                chatID: message.chat.id,
                messageID: message.message_id,
                text: "Меню закрыто. Откройте снова — /menu",
                replyMarkup: InlineKeyboardMarkup(inline_keyboard: [])
            )
        )
        try? await telegram.answerCallback(callbackQueryID: callback.id, text: nil)
    }

    /// Redraws the tapped menu message in place, falling back to a new message
    /// when the old one can no longer be edited, and always answers the tap.
    func editOrAnswer(
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage,
        screen: MenuScreen
    ) async throws {
        do {
            try await telegram.editMessage(
                .init(
                    chatID: message.chat.id,
                    messageID: message.message_id,
                    text: screen.text,
                    replyMarkup: screen.markup
                )
            )
        } catch {
            _ = try? await telegram.sendMessage(
                .init(
                    chatID: message.chat.id,
                    threadID: message.message_thread_id,
                    replyTo: nil,
                    text: screen.text,
                    replyMarkup: screen.markup
                )
            )
        }
        try? await telegram.answerCallback(callbackQueryID: callback.id, text: nil)
    }

    /// Refreshes the menu message a text-input prompt came from. Its id was
    /// stored when the wait was armed, so there is no callback to answer here —
    /// the person replied with a message, not a tap.
    func refreshMenu(chatKey: ChatKey, menuMessageID: Int, screen: MenuScreen) async {
        try? await telegram.editMessage(
            .init(
                chatID: chatKey.chatID,
                messageID: menuMessageID,
                text: screen.text,
                replyMarkup: screen.markup
            )
        )
    }

    func renderPage(_ page: MenuPage, chatKey: ChatKey, username: String? = nil) async -> MenuScreen {
        // Second line of defence for the paths that render without a callback
        // (a menu refreshed after text input): a personal page never draws its
        // contents into a group message.
        if page.isPersonal, chatKey.chatID < 0 {
            var rows: Keyboard = []
            if !botUsername.isEmpty {
                rows.row([InlineKeyboardButton(text: "💬 Открыть бота", url: "https://t.me/\(botUsername)")])
            }
            rows.row(navButtons())
            return MenuScreen(page.privateOnlyNotice, rows)
        }
        // Same second line of defence for the restricted settings pages: this
        // path renders without a callback (a menu redrawn after a typed value),
        // so the nav gate above has not run.
        if page.requiresOperator, !(await state.isAdmin(username: username, chatID: chatKey.chatID)) {
            return MenuScreen(page.restrictedNotice, [navButtons()])
        }
        if page.requiresFullAccess,
           !(await state.hasFullModelAccess(username: username, chatID: chatKey.chatID)) {
            var rows: Keyboard = [[buyButton("⚡ Открыть тонкую настройку", source: .tuning)]]
            rows.row(navButtons())
            return MenuScreen(page.restrictedNotice, rows)
        }
        switch page {
        case .main:
            return await renderMain(chatKey: chatKey, username: username)
        case .role:
            return await renderRole(chatKey: chatKey)
        case .model:
            return await renderModel(chatKey: chatKey, username: username)
        case .temp:
            return await renderTemp(chatKey: chatKey)
        case .stats:
            return await renderStats(chatKey: chatKey, username: username)
        case .history:
            return await renderHistory(chatKey: chatKey, username: username)
        case .provider:
            return await renderProvider(chatKey: chatKey)
        case .reasoning:
            return await renderReasoning(chatKey: chatKey)
        case .tuning:
            return await renderTuning(chatKey: chatKey, username: username)
        case .helpPage:
            return await renderHelp(chatKey: chatKey)
        case .pay:
            return await renderPay(chatKey: chatKey, username: username)
        case .adminPanel:
            return await renderAdminPanel(chatKey: chatKey, username: username)
        case .adminHelp:
            return renderAdminHelp()
        case .adminChats:
            return await renderAdminChats(chatKey: chatKey, username: username)
        case .adminUsers:
            return await renderAdminUsers(chatKey: chatKey, username: username)
        case .adminWhitelist:
            return await renderAdminWhitelist(chatKey: chatKey)
        case .adminDefaults:
            return await renderAdminDefaults(chatKey: chatKey)
        case .superAdmin:
            return await renderSuperAdmin(chatKey: chatKey)
        case .superAdminHelp:
            return renderSuperAdminHelp()
        case .superStars:
            return await renderSuperStars(chatKey: chatKey)
        case .superCrypto:
            return await renderSuperCrypto(chatKey: chatKey)
        case .superCard:
            return await renderSuperCard(chatKey: chatKey)
        case .superFreeModels:
            return await renderSuperFreeModels(chatKey: chatKey)
        case .superTenants:
            return await renderSuperTenants(chatKey: chatKey)
        case .superAdmins:
            return await renderSuperAdmins(chatKey: chatKey, username: username)
        case .superSimulate:
            return await renderSuperSimulate(chatKey: chatKey, username: username)
        case .superChats:
            return await renderSuperChats(chatKey: chatKey)
        case .superAds:
            return await renderSuperAds(chatKey: chatKey)
        case .superBalances:
            return await renderSuperBalances(chatKey: chatKey)
        case .superFunnel:
            return await renderSuperFunnel(chatKey: chatKey)
        case .superReminders:
            return await renderSuperReminders(chatKey: chatKey)
        case .superOnboarding:
            return await renderSuperOnboarding(chatKey: chatKey)
        case .superModes:
            return await renderSuperModes(chatKey: chatKey)
        case .superReferrals:
            return await renderSuperReferrals(chatKey: chatKey)
        case .superTraffic:
            return await renderSuperTraffic(chatKey: chatKey)
        case .referral:
            // Private chats only (guarded at the nav gate), where chatID == the
            // user's ID — that is whose link and wallet the page is about.
            return await renderReferral(chatKey: chatKey, userID: chatKey.chatID)
        case .adminInvite:
            return await renderAdminInvite(chatKey: chatKey, username: username)
        case .close:
            return MenuScreen("Меню закрыто. Откройте снова — /menu", [])
        }
    }

    func sendHistoryDump(chatKey: ChatKey) async {
        let messages = await state.history(chatKey: chatKey)
        let text: String
        if messages.isEmpty {
            text = "📝 Бот пока ничего не помнит — переписки нет."
        } else {
            var lines: [String] = ["<b>📝 Что бот помнит</b> (\(messages.count))"]
            for msg in messages {
                let roleLabel: String
                switch msg.role {
                case "system": roleLabel = "⚙️"
                case "user": roleLabel = "👤"
                case "assistant": roleLabel = "🤖"
                default: roleLabel = msg.role
                }
                let content: String
                switch msg.content {
                case .text(let t):
                    content = t
                case .parts(let parts):
                    let textParts = parts.compactMap { $0.text }
                    let mediaTags = parts.compactMap { part -> String? in
                        if part.inputImage != nil { return "[изображение]" }
                        if part.inputAudio != nil { return "[аудио]" }
                        if part.inputVideo != nil { return "[видео]" }
                        return nil
                    }
                    content = (textParts.joined(separator: " ") + " " + mediaTags.joined(separator: " ")).trimmingCharacters(in: .whitespaces)
                }
                let limit = 280
                let displayContent: String
                if content.isEmpty {
                    displayContent = "<i>(пусто)</i>"
                } else if content.count > limit {
                    let endIndex = content.index(content.startIndex, offsetBy: limit)
                    displayContent = String(content[..<endIndex]) + "…"
                } else {
                    displayContent = content
                }
                lines.append("\n\(roleLabel) \(displayContent)")
            }
            text = lines.joined(separator: "\n")
        }
        _ = try? await telegram.sendMessage(.init(
            chatID: chatKey.chatID,
            threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
            replyTo: nil,
            text: text,
            replyMarkup: nil
        ))
    }

    /// Shown when the caller's storage key cannot be resolved. It used to read
    /// "У вас не задан @username", which is both wrong (identity is the userID
    /// since CLAUDE.md §6) and a dead end — it told people to fix something
    /// that is not the problem.
    static let unknownAccountNotice =
        "Не удалось определить ваш аккаунт. Напишите боту любое сообщение в личке и откройте меню снова."

    private func menuButton(_ text: String, action: String) -> InlineKeyboardButton {
        .init(text: text, callback_data: BotCallbackAction.menu(action: action).rawData)
    }

    /// A button that only names a command — no arguments to mistype.
    func menuButton(_ text: String, command: MenuCommand) -> InlineKeyboardButton {
        menuButton(text, action: command.rawValue)
    }

    /// A button carrying a command and its arguments. The payload format lives
    /// here and nowhere else: call sites pass values, not a string they glued
    /// together, so an argument cannot land in the wrong position or bring a
    /// stray separator with it.
    func menuButton(_ text: String, _ command: MenuCommand, _ arguments: String...) -> InlineKeyboardButton {
        menuButton(text, action: ([command.rawValue] + arguments).joined(separator: ":"))
    }

    /// A link to another page. The destination is a `MenuPage`, so a button
    /// cannot point at a page that does not exist — the old `"nav:superstars"`
    /// string was checked by nothing until somebody tapped it.
    func menuButton(_ text: String, page: MenuPage) -> InlineKeyboardButton {
        menuButton(text, action: MenuRoute.navigation(to: page))
    }

    /// A link to the purchase page. The surface that sent the person there is
    /// required by the type (CLAUDE.md §17): a new upsell that forgets it would
    /// silently merge into "Меню" in the funnel.
    func buyButton(_ text: String, source: PurchaseSource) -> InlineKeyboardButton {
        menuButton(text, action: MenuRoute.purchase(from: source))
    }

    /// "← К супер-админу", "← К моему премиуму", … — the label comes from the
    /// destination (`MenuPage.backLabel`), so it cannot name one page and lead
    /// to another.
    func backButton(to page: MenuPage) -> InlineKeyboardButton {
        menuButton(page.backLabel, page: page)
    }

    /// "❌ Отмена" — abandons a text-input prompt by navigating back to the
    /// page that armed it (`nav:` clears the pending wait on the way).
    func cancelButton(to page: MenuPage) -> InlineKeyboardButton {
        menuButton(Texts.cancel, page: page)
    }

    func navButtons() -> [InlineKeyboardButton] {
        [
            menuButton(Texts.back, command: .open),
            menuButton(Texts.close, command: .close),
        ]
    }

    func toggleMark(_ value: Bool) -> String {
        value ? "🟢" : "⚪️"
    }

    static func formatTemp(_ value: Float) -> String {
        if value.rounded() == value {
            return String(format: "%.1f", value)
        }
        return String(format: "%.2f", value)
    }

    static func tempBucket(_ value: Float) -> String {
        switch value {
        case ..<0.4: return "точно"
        case ..<0.9: return "сдержанно"
        case ..<1.3: return "сбалансировано"
        case ..<1.7: return "креативно"
        default: return "хаотично"
        }
    }
}
