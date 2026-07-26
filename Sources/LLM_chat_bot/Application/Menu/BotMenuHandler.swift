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
        let action = rawAction.isEmpty ? "open" : rawAction
        let parts = action.split(separator: ":", omittingEmptySubsequences: false).map(String.init)

        do {
            try await processAction(parts: parts, chatKey: chatKey, callback: callback, message: message)
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
        await clearAllPendingInputs(chatKey: chatKey)
        let (text, markup) = await renderPage(.main, chatKey: chatKey, username: username)
        _ = try? await telegram.sendMessage(
            .init(
                chatID: chatKey.chatID,
                threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                replyTo: nil,
                text: text,
                replyMarkup: markup
            )
        )
    }

    private func processAction(
        parts: [String],
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard let command = parts.first, !command.isEmpty else {
            try await showPage(.main, chatKey: chatKey, callback: callback, message: message)
            return
        }

        switch command {
        case "open", "close", "nav", "noop":
            try await processNavigationAction(
                command: command,
                parts: parts,
                chatKey: chatKey,
                callback: callback,
                message: message
            )

        case "role", "model", "temp", "stats", "history", "provider", "reasoning", "reset", "help":
            try await processChatSettingsAction(
                command: command,
                parts: parts,
                chatKey: chatKey,
                callback: callback,
                message: message
            )

        case "pm":
            try await processPresetAction(
                command: command,
                parts: parts,
                chatKey: chatKey,
                callback: callback,
                message: message
            )

        case "buy":
            try await processPurchaseAction(
                command: command,
                parts: parts,
                chatKey: chatKey,
                callback: callback,
                message: message
            )

        case "tenant", "wl", "def":
            try await processAdminAction(
                command: command,
                parts: parts,
                chatKey: chatKey,
                callback: callback,
                message: message
            )

        case "sa", "stenant", "sim", "sinspect", "ads", "markup", "dailylimit", "stars", "freemodels", "sbal", "crypto", "card":
            try await processSuperAdminAction(
                command: command,
                parts: parts,
                chatKey: chatKey,
                callback: callback,
                message: message
            )

        case "funnel", "promo", "rem", "examples", "onb", "sref", "strf":
            try await processGrowthAction(
                command: command,
                parts: parts,
                chatKey: chatKey,
                callback: callback,
                message: message
            )

        case "sahelp":
            try await processHelpAction(
                command: command,
                parts: parts,
                chatKey: chatKey,
                callback: callback,
                message: message
            )

        default:
            try await telegram.answerCallback(callbackQueryID: callback.id, text: "Неизвестное действие")
        }
    }

    /// Menu navigation: open, close, page jumps.
    private func processNavigationAction(
        command: String,
        parts: [String],
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        switch command {
        case "open":
            await clearAllPendingInputs(chatKey: chatKey)
            try await showPage(.main, chatKey: chatKey, callback: callback, message: message)

        case "close":
            await clearAllPendingInputs(chatKey: chatKey)
            try await closeMenu(callback: callback, message: message)

        case "nav":
            // Navigating away abandons any text-input prompt (incl. the
            // "❌ Отмена" buttons, which all point at nav:*).
            await clearAllPendingInputs(chatKey: chatKey)
            guard parts.count >= 2 else {
                try await showPage(.main, chatKey: chatKey, callback: callback, message: message)
                return
            }
            let page = parts[1].lowercased()
            guard let menuPage = MenuPage(rawValue: page) else {
                try await showPage(.main, chatKey: chatKey, callback: callback, message: message)
                return
            }
            switch menuPage {
            // Every `super*` page belongs here — the buttons inside them are
            // gated separately, but the pages themselves show the owner's
            // configuration and numbers.
            case .superAdmin, .superAdminHelp, .superStars, .superCrypto, .superCard, .superFreeModels, .superTenants, .superAdmins, .superSimulate, .superChats, .superAds, .superBalances, .superFunnel, .superReminders, .superOnboarding, .superReferrals, .superTraffic:
                guard await state.isSuperAdmin(username: invokerKey(callback)) else {
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
                    return
                }
            case .adminPanel, .adminHelp, .adminChats, .adminUsers, .adminWhitelist, .adminDefaults, .adminInvite:
                guard await state.isAdmin(username: invokerKey(callback), chatID: chatKey.chatID) else {
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только администратор")
                    return
                }
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
                purchaseSource: PurchaseSource.parse(parts.count >= 3 ? parts[2] : nil)
            )

        case "noop":
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
        let (text, markup) = await renderPage(page, chatKey: chatKey, username: state.userKey(userID: callback.from.id))
        try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)
    }

    private func closeMenu(callback: CallbackQuery, message: MaybeInaccessibleMessage) async throws {
        let chatKey = ChatKey(chatID: message.chat.id, threadID: message.message_thread_id ?? 0)
        await state.clearPendingInput(chatKey: chatKey)
        await state.clearPendingStarsPriceInput(chatKey: chatKey)
        await state.clearPendingStarsPerUsdInput(chatKey: chatKey)
        await state.clearPendingFreeModelInput(chatKey: chatKey)
        await state.clearPendingCryptoPriceInput(chatKey: chatKey)
        await state.clearPendingCryptoAddressInput(chatKey: chatKey)
        await state.clearPendingCryptoPoolAddInput(chatKey: chatKey)
        await state.clearAdminPendingInput(chatKey: chatKey)
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

    func editOrAnswer(
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage,
        text: String,
        markup: InlineKeyboardMarkup
    ) async throws {
        do {
            try await telegram.editMessage(
                .init(
                    chatID: message.chat.id,
                    messageID: message.message_id,
                    text: text,
                    replyMarkup: markup
                )
            )
        } catch {
            _ = try? await telegram.sendMessage(
                .init(
                    chatID: message.chat.id,
                    threadID: message.message_thread_id,
                    replyTo: nil,
                    text: text,
                    replyMarkup: markup
                )
            )
        }
        try? await telegram.answerCallback(callbackQueryID: callback.id, text: nil)
    }

    func renderPage(_ page: MenuPage, chatKey: ChatKey, username: String? = nil) async -> (String, InlineKeyboardMarkup) {
        // Second line of defence for the paths that render without a callback
        // (a menu refreshed after text input): a personal page never draws its
        // contents into a group message.
        if page.isPersonal, chatKey.chatID < 0 {
            var rows: [[InlineKeyboardButton]] = []
            if !botUsername.isEmpty {
                rows.append([InlineKeyboardButton(text: "💬 Открыть бота", url: "https://t.me/\(botUsername)")])
            }
            rows.append(navButtons())
            return (page.privateOnlyNotice, InlineKeyboardMarkup(inline_keyboard: rows))
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
            return await renderHistory(chatKey: chatKey)
        case .provider:
            return await renderProvider(chatKey: chatKey)
        case .reasoning:
            return await renderReasoning(chatKey: chatKey)
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
            return ("Меню закрыто. Откройте снова — /menu", InlineKeyboardMarkup(inline_keyboard: []))
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

    func menuButton(_ text: String, action: String) -> InlineKeyboardButton {
        .init(text: text, callback_data: BotCallbackAction.menu(action: action).rawData)
    }

    func navButtons() -> [InlineKeyboardButton] {
        [
            menuButton("← Назад", action: "open"),
            menuButton("✕ Закрыть", action: "close"),
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
