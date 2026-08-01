import Foundation

// Tenant-owner panel: licensed chats, guests, defaults, invite link.

extension BotMenuHandler {
    /// Tenant-owner actions: licence, guests, defaults.
    func processAdminAction(
        route: MenuRoute,
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        switch route.command {
        case .tenant:
            try await handleTenantAction(route: route, chatKey: chatKey, callback: callback, message: message)
            return

        case .wl:
            guard await requireAdmin(callback, chatKey: chatKey) else { return }
            guard !route.sub.isEmpty else { return }
            switch route.sub {
            case "add":
                await state.setPending(.admin(.init(kind: .whitelistAdd)), menuMessageID: message.message_id, chatKey: chatKey)
                let promptText = """
                <b>👤 Добавить гостя</b>

                Отправьте его номер в Telegram одним сообщением (целое число).

                <i>Ваш премиум заработает для него в этом чате. Свой номер человек узнаёт командой /chatid в личке с ботом.</i>
                """
                let markup: Keyboard = [[cancelButton(to: .adminWhitelist)]]
                try await editOrAnswer(callback: callback, message: message, screen: MenuScreen(promptText, markup))
            case "remove":
                guard let id = route.int(2) else { return }
                await state.removeFromWhitelist(userID: id, chatID: chatKey.chatID)
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Убрано")
                try await showPage(.adminWhitelist, chatKey: chatKey, callback: callback, message: message)
            default:
                try await showPage(.adminWhitelist, chatKey: chatKey, callback: callback, message: message)
            }
            return

        case .def:
            guard await requireAdmin(callback, chatKey: chatKey) else { return }
            guard !route.sub.isEmpty else { return }
            let defs = await state.getDefaults(chatID: chatKey.chatID)
            let kind: AdminPendingInputKind
            let prompt: String
            switch route.sub {
            case "model":
                kind = .defaultsModel
                prompt = "<b>⚙️ Модель в новых чатах</b>\n\nСейчас: <code>\(defs.model)</code>\n\nОтправьте ID модели одним сообщением (названия — на openrouter.ai)."
            case "hist":
                kind = .defaultsHistory
                prompt = "<b>⚙️ Память в новых чатах</b>\n\nСейчас: <b>\(defs.historyLength) сообщ.</b>\n\nОтправьте число от 1 до 50 — сколько последних сообщений бот держит в голове."
            case "role":
                kind = .defaultsRole
                prompt = "<b>⚙️ Роль в новых чатах</b>\n\nСейчас:\n<blockquote expandable>\(defs.role)</blockquote>\n\nОтправьте новый текст роли одним сообщением."
            default:
                return
            }
            await state.setPending(.admin(.init(kind: kind)), menuMessageID: message.message_id, chatKey: chatKey)
            let markup: Keyboard = [[cancelButton(to: .adminDefaults)]]
            try await editOrAnswer(callback: callback, message: message, screen: MenuScreen(prompt, markup))
            return

        default:
            break
        }
    }

    func renderAdminPanel(chatKey: ChatKey, username: String?) async -> MenuScreen {
        let defaults = await state.getDefaults(chatID: chatKey.chatID)
        let whitelist = await state.listWhitelisted(chatID: chatKey.chatID)
        let admins = await state.listAdmins(chatID: chatKey.chatID)

        let globalRoles = await state.rolePresets(chatID: chatKey.chatID).count
        let globalModels = await state.modelPresets(chatID: chatKey.chatID).count
        let globalTemps = await state.tempPresets(chatID: chatKey.chatID).count
        let globalHist = await state.historyLengthPresets(chatID: chatKey.chatID).count

        let invoker = await state.userKey(username: username)
        let chatOwner = await state.chatOwner(chatID: chatKey.chatID)
        let isOwnChat = invoker != nil && chatOwner == invoker
        let chatStatusLine: String
        if let chatOwner {
            chatStatusLine = isOwnChat ? "🟢 премиум в этом чате открыли вы" : "🔒 премиум в этом чате открыл \(await state.displayLabel(forKey: chatOwner))"
        } else {
            chatStatusLine = "⚪ в этом чате премиум ещё никто не открыл"
        }

        let licensedChats: [Int]
        let licensedUsers: [(key: String, label: String)]
        let usage: CumulativeUsage
        if let invoker {
            licensedChats = await state.chatsOwnedBy(invoker)
            licensedUsers = await state.licensedUsers(ownerUsername: invoker)
            usage = await state.tenantUsage(ownerUsername: invoker)
        } else {
            licensedChats = []
            licensedUsers = []
            usage = .zero
        }

        var rows: Keyboard = []
        if isOwnChat {
            rows.row([menuButton("📌 Выключить премиум в этом чате", .tenant, "release")])
        } else if chatOwner == nil {
            rows.row([menuButton("📌 Включить премиум в этом чате", .tenant, "claim")])
        }
        rows.row([menuButton("🔗 Ссылка-приглашение", page: .adminInvite)])
        rows.row([
            menuButton("📋 Чаты с премиумом · \(licensedChats.count)", page: .adminChats),
            menuButton("👥 Гости премиума · \(licensedUsers.count)", page: .adminUsers),
        ])
        rows.row([
            menuButton("⚙️ Новые чаты", page: .adminDefaults),
            menuButton("👤 Гости этого чата · \(whitelist.count)", page: .adminWhitelist),
        ])
        rows.row([menuButton("🤖 Заготовки моделей · \(globalModels)", .pm, "model"),
                     menuButton("🎭 Ролей · \(globalRoles)", .pm, "role")])
        rows.row([menuButton("🌡 Стилей · \(globalTemps)", .pm, "temp"),
                     menuButton("📝 Памяти · \(globalHist)", .pm, "history")])
        rows.row([menuButton("ℹ️ Справка", page: .adminHelp)])
        rows.row(navButtons())

        let adminsLine = admins.isEmpty
            ? "<i>только вы</i>"
            : admins.map(\.label).joined(separator: ", ")

        let costStr = await state.billedCost(of: usage).formatted()
        let usageLine = usage.generationCount == 0
            ? "📈 Запросов пока нет"
            : "📈 запросов <b>\(usage.generationCount)</b> · итого <b>\(costStr)</b>"

        // A daily spending ceiling that nobody can see is not a protection —
        // it is an unexplained downgrade of something they paid for (§4.1). It
        // only appears when one is actually set.
        var spendLine: String?
        if let invoker { spendLine = await state.spendStatusLine(forKey: invoker) }

        var subscriptionLine: String
        // Reminder line + opt-out: the sponsor sees when the renewal nudge will
        // arrive and can switch it off for themselves (roadmap step 8).
        var reminderLine: String? = nil
        if let invoker {
            let sub = await state.tenantSubscription(ownerUsername: invoker)
            if !sub.exists {
                subscriptionLine = "💳 Премиум · <i>не оплачен — /buy</i>"
            } else if let until = sub.paidUntil {
                let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy"
                subscriptionLine = sub.isActive
                    ? "💳 Премиум · оплачен до <b>\(f.string(from: until))</b> · продлить /buy"
                    : "💳 Премиум · <b>⛔ закончился \(f.string(from: until))</b> · продлить /buy"

                let reminders = await state.reminderConfig()
                let optedOut = await state.remindersOptOut(username: invoker)
                if optedOut {
                    reminderLine = "🔕 Напоминания о продлении · <b>выключены</b>"
                } else if reminders.enabled, sub.isActive,
                          // Nearest wave still ahead of us — the widest one has
                          // usually already gone out by the time this is read.
                          let nextWave = reminders.expiryReminderDays
                            .map({ until.addingTimeInterval(-Double($0) * 86_400) })
                            .filter({ $0 > Date() })
                            .min() {
                    reminderLine = "🔔 Напомню о продлении · <b>\(f.string(from: nextWave))</b>"
                } else if reminders.enabled {
                    reminderLine = "🔔 Напоминания о продлении · <b>включены</b>"
                }
                if let discount = await state.subscriptionDiscount(username: invoker) {
                    let df = DateFormatter(); df.dateFormat = "dd.MM HH:mm"
                    subscriptionLine += "\n🎁 Скидка <b>−\(discount.percent)%</b> действует до <b>\(df.string(from: discount.expiresAt))</b>"
                }
                // Keep the nav row last.
                rows.insertBeforeLast([menuButton(
                    optedOut ? "🔕 Напоминания о продлении: выкл" : "🔔 Напоминания о продлении: вкл",
                    .tenant, "remtoggle"
                )])
            } else {
                subscriptionLine = "💳 Премиум · <b>бессрочный</b>"
            }
        } else {
            subscriptionLine = "💳 Премиум · <i>не оплачен — /buy</i>"
        }

        let text = """
        <b>⚡ Мой премиум</b>

        <b>📌 Где он работает</b>
        \(chatStatusLine)
        🆔 Номер этого чата · <code>\(chatKey.chatID)</code>
        \(subscriptionLine)\(reminderLine.map { "\n" + $0 } ?? "")\(spendLine.map { "\n" + $0 } ?? "")
        Чатов · <b>\(licensedChats.count)</b> · гостей · <b>\(licensedUsers.count)</b>
        \(usageLine)

        <b>Что включается в новых чатах</b>
        🤖 Модель · <code>\(defaults.model)</code>
        📝 Память · <b>\(defaults.historyLength) сообщ.</b>
        🎭 Роль:
        <blockquote expandable>\(defaults.role)</blockquote>

        <b>👥 Кому открыт доступ</b>
        Гости этого чата · <b>\(whitelist.count)</b>
        Помогают управлять · \(adminsLine)

        <b>📋 Общие заготовки</b>
        Кнопки ниже задают готовые варианты для всех ваших чатов.
        """
        return MenuScreen(text, rows)
    }

    func renderAdminChats(chatKey: ChatKey, username: String?) async -> MenuScreen {
        guard let invoker = await state.userKey(username: username) else {
            return MenuScreen(Self.unknownAccountNotice, [[backButton(to: .adminPanel)]])
        }
        let invokerLabel = await state.displayLabel(forKey: invoker)
        let chats = await state.chatsOwnedBy(invoker).sorted()

        var rows: Keyboard = []
        var listLines: [String] = []
        // A bare `-1001234567890` says nothing about which chat it is: the
        // owner has to guess which of their groups they are switching off.
        for chatID in chats.prefix(40) {
            let kind = chatID < 0 ? "👥" : "👤"
            let label = await state.chatDisplayLabel(chatID: chatID)
            let named = label != String(chatID)
            rows.row([
                menuButton("\(kind) \(label)", command: .noop),
                menuButton("🗑 Выключить", .tenant, "rmchat", "\(chatID)"),
            ])
            listLines.append(named
                ? "\(kind) <b>\(label)</b> · <code>\(chatID)</code>"
                : "\(kind) <code>\(chatID)</code>")
        }
        if chats.count > 40 {
            listLines.append("<i>…и ещё \(chats.count - 40)</i>")
        }
        let chatOwner = await state.chatOwner(chatID: chatKey.chatID)
        if chatOwner != invoker {
            rows.row([menuButton("📌 Включить премиум здесь", .tenant, "claim")])
        }
        rows.row([menuButton("📥 Добавить чат по номеру", .tenant, "assignprompt")])
        rows.row([backButton(to: .adminPanel)])

        let listText = chats.isEmpty ? "<i>пока ни одного</i>" : listLines.joined(separator: "\n")
        let text = """
        <b>📋 Чаты с премиумом \(invokerLabel)</b> (\(chats.count))

        \(listText)

        <i>Чтобы премиум заработал ещё в одном чате — просто добавьте туда бота, он подхватит доступ сам. \
        Или откройте нужный чат и нажмите «Включить премиум здесь». Ещё можно ввести номер чата кнопкой ниже.</i>
        """
        return MenuScreen(text, rows)
    }

    func renderAdminWhitelist(chatKey: ChatKey) async -> MenuScreen {
        let ids = await state.listWhitelisted(chatID: chatKey.chatID).sorted()
        var rows: Keyboard = [
            [menuButton("➕ Добавить гостя", .wl, "add")],
        ]
        var listLines: [String] = []
        // Guests are stored by numeric ID, but the owner recognises people by
        // name — resolve it whenever the bot has ever seen them.
        for id in ids.prefix(40) {
            let label = await state.displayLabel(forUserID: id)
            let named = label != "id \(id)"
            rows.row([
                menuButton(label, command: .noop),
                menuButton("🗑 Убрать", .wl, "remove", "\(id)"),
            ])
            listLines.append(named ? "• <b>\(label)</b> · <code>\(id)</code>" : "• <code>\(id)</code>")
        }
        if ids.count > 40 {
            listLines.append("<i>…и ещё \(ids.count - 40)</i>")
        }
        rows.row([backButton(to: .adminPanel)])

        let listText = ids.isEmpty ? "<i>пусто</i>" : listLines.joined(separator: "\n")
        let text = """
        <b>👤 Гости этого чата</b> (\(ids.count))

        \(listText)

        <i>Люди, которым вы открыли умные модели в этом чате бесплатно. Добавляются по номеру пользователя в Telegram — его можно узнать, переслав сюда его сообщение любому ID-боту.</i>
        """
        return MenuScreen(text, rows)
    }

    func renderAdminDefaults(chatKey: ChatKey) async -> MenuScreen {
        let defs = await state.getDefaults(chatID: chatKey.chatID)
        let rows: Keyboard = [
            [menuButton("✏️ Модель", .def, "model")],
            [menuButton("✏️ Память", .def, "hist")],
            [menuButton("✏️ Роль", .def, "role")],
            [backButton(to: .adminPanel)],
        ]
        let text = """
        <b>⚙️ Что включается в новых чатах</b>

        🤖 Модель · <code>\(defs.model)</code>
        📝 Память · <b>\(defs.historyLength) сообщ.</b>
        🎭 Роль:
        <blockquote expandable>\(defs.role)</blockquote>

        <i>С этими настройками бот стартует в каждом новом чате. Они же возвращаются по команде /reset.</i>
        """
        return MenuScreen(text, rows)
    }

    func renderAdminUsers(chatKey: ChatKey, username: String?) async -> MenuScreen {
        guard let invoker = await state.userKey(username: username) else {
            return MenuScreen(Self.unknownAccountNotice, [[backButton(to: .adminPanel)]])
        }
        let invokerLabel = await state.displayLabel(forKey: invoker)
        let users = await state.licensedUsers(ownerUsername: invoker)

        var rows: Keyboard = [
            [menuButton("🔗 Ссылка-приглашение", page: .adminInvite)],
            [menuButton("➕ Добавить по @username", .tenant, "adduserprompt")],
        ]
        for (i, user) in users.prefix(40).enumerated() {
            rows.row([
                menuButton(user.label, command: .noop),
                menuButton("🗑 Удалить", .tenant, "rmuser", "\(i)"),
            ])
        }
        rows.row([backButton(to: .adminPanel)])

        let listText: String
        if users.isEmpty {
            listText = "<i>пока никого</i>"
        } else {
            listText = users.map { "• \($0.label)" }.joined(separator: "\n")
        }
        let text = """
        <b>👥 Гости премиума \(invokerLabel)</b> (\(users.count))

        \(listText)

        <i>Этим людям умные модели доступны за ваш счёт в любом чате с ботом. Проще всего — дать им ссылку-приглашение (кнопка выше). Командой: <code>/tenant adduser @username</code>.</i>
        """
        return MenuScreen(text, rows)
    }

    func renderAdminInvite(chatKey: ChatKey, username: String?) async -> MenuScreen {
        // The invite is filed under the caller's storage key, like every other
        // per-person record — a raw handle would miss anyone without one.
        guard let invoker = await state.userKey(username: username) else {
            return MenuScreen(Self.unknownAccountNotice, [[backButton(to: .adminPanel)]])
        }
        guard await state.isTenant(username: invoker) else {
            return MenuScreen(
                "🔗 <b>Ссылка-приглашение</b>\n\nОна появится, как только у вас будет активный премиум: по ссылке умные модели работают за ваш счёт.",
                [
                    [buyButton("⚡ Открыть премиум", source: .menu)],
                    [backButton(to: .adminPanel)],
                ]
            )
        }

        let token = await state.inviteToken(owner: invoker)
        var rows: Keyboard = []
        let text: String
        if let token {
            let link = "https://t.me/\(botUsername)?start=inv_\(token)"
            rows.row([InlineKeyboardButton(text: "📨 Открыть ссылку", url: link)])
            rows.row([menuButton("♻️ Перевыпустить (старая сгорит)", .tenant, "newinvite")])
            text = """
            <b>🔗 Ссылка-приглашение</b>

            <code>\(link)</code>

            Отправьте её кому угодно: он откроет ссылку, нажмёт «Начать» — и умные модели заработают у него за ваш счёт. Появится в списке «Гости премиума».
            """
        } else {
            rows.row([menuButton("➕ Создать ссылку", .tenant, "newinvite")])
            text = """
            <b>🔗 Ссылка-приглашение</b>

            Ссылки пока нет. Нажмите кнопку ниже — бот создаст вашу личную ссылку, по которой друзья и коллеги получат умные модели за ваш счёт.
            """
        }
        rows.row([backButton(to: .adminPanel)])
        return MenuScreen(text, rows)
    }
}
