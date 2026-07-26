import Foundation

// Tenant-owner panel: licensed chats, guests, defaults, invite link.

extension BotMenuHandler {
    /// Tenant-owner actions: licence, guests, defaults.
    func processAdminAction(
        command: String,
        parts: [String],
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        switch command {
        case "tenant":
            try await handleTenantAction(parts: parts, chatKey: chatKey, callback: callback, message: message)
            return

        case "wl":
            guard await state.isAdmin(username: invokerKey(callback), chatID: chatKey.chatID) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только администратор")
                return
            }
            guard parts.count >= 2 else { return }
            switch parts[1] {
            case "add":
                await state.setAdminPendingInput(.init(kind: .whitelistAdd, menuMessageID: message.message_id, payload: nil), chatKey: chatKey)
                let promptText = """
                <b>👤 Добавить гостя</b>

                Отправьте его номер в Telegram одним сообщением (целое число).

                <i>Ваш премиум заработает для него в этом чате. Свой номер человек узнаёт командой /chatid в личке с ботом.</i>
                """
                let markup = InlineKeyboardMarkup(inline_keyboard: [[menuButton("❌ Отмена", action: "nav:adminwl")]])
                try await editOrAnswer(callback: callback, message: message, text: promptText, markup: markup)
            case "remove":
                guard parts.count >= 3, let id = Int(parts[2]) else { return }
                await state.removeFromWhitelist(userID: id, chatID: chatKey.chatID)
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Убрано")
                try await showPage(.adminWhitelist, chatKey: chatKey, callback: callback, message: message)
            default:
                try await showPage(.adminWhitelist, chatKey: chatKey, callback: callback, message: message)
            }
            return

        case "def":
            guard await state.isAdmin(username: invokerKey(callback), chatID: chatKey.chatID) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только администратор")
                return
            }
            guard parts.count >= 2 else { return }
            let defs = await state.getDefaults(chatID: chatKey.chatID)
            let kind: AdminPendingInputKind
            let prompt: String
            switch parts[1] {
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
            await state.setAdminPendingInput(.init(kind: kind, menuMessageID: message.message_id, payload: nil), chatKey: chatKey)
            let markup = InlineKeyboardMarkup(inline_keyboard: [[menuButton("❌ Отмена", action: "nav:admindef")]])
            try await editOrAnswer(callback: callback, message: message, text: prompt, markup: markup)
            return

        default:
            break
        }
    }

    func renderAdminPanel(chatKey: ChatKey, username: String?) async -> (String, InlineKeyboardMarkup) {
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

        var rows: [[InlineKeyboardButton]] = []
        if isOwnChat {
            rows.append([menuButton("📌 Выключить премиум в этом чате", action: "tenant:release")])
        } else if chatOwner == nil {
            rows.append([menuButton("📌 Включить премиум в этом чате", action: "tenant:claim")])
        }
        rows.append([menuButton("🔗 Ссылка-приглашение", action: "nav:admininvite")])
        rows.append([
            menuButton("📋 Чаты с премиумом · \(licensedChats.count)", action: "nav:adminchats"),
            menuButton("👥 Гости премиума · \(licensedUsers.count)", action: "nav:adminusers"),
        ])
        rows.append([
            menuButton("⚙️ Новые чаты", action: "nav:admindef"),
            menuButton("👤 Гости этого чата · \(whitelist.count)", action: "nav:adminwl"),
        ])
        rows.append([menuButton("🤖 Заготовки моделей · \(globalModels)", action: "pm:model"),
                     menuButton("🎭 Ролей · \(globalRoles)", action: "pm:role")])
        rows.append([menuButton("🌡 Стилей · \(globalTemps)", action: "pm:temp"),
                     menuButton("📝 Памяти · \(globalHist)", action: "pm:history")])
        rows.append([menuButton("ℹ️ Справка", action: "nav:adminhelp")])
        rows.append(navButtons())

        let adminsLine = admins.isEmpty
            ? "<i>только вы</i>"
            : admins.map(\.label).joined(separator: ", ")

        let costStr = String(format: "$%.4f", await state.billedCost(of: usage))
        let usageLine = usage.generationCount == 0
            ? "📈 Запросов пока нет"
            : "📈 запросов <b>\(usage.generationCount)</b> · итого <b>\(costStr)</b>"

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
                rows.insert([menuButton(
                    optedOut ? "🔕 Напоминания о продлении: выкл" : "🔔 Напоминания о продлении: вкл",
                    action: "tenant:remtoggle"
                )], at: max(0, rows.count - 1))
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
        \(subscriptionLine)\(reminderLine.map { "\n" + $0 } ?? "")
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
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    func renderAdminChats(chatKey: ChatKey, username: String?) async -> (String, InlineKeyboardMarkup) {
        guard let invoker = await state.userKey(username: username) else {
            return (Self.unknownAccountNotice, InlineKeyboardMarkup(inline_keyboard: [[menuButton("← Назад", action: "nav:admin")]]))
        }
        let invokerLabel = await state.displayLabel(forKey: invoker)
        let chats = await state.chatsOwnedBy(invoker).sorted()

        var rows: [[InlineKeyboardButton]] = []
        var listLines: [String] = []
        // A bare `-1001234567890` says nothing about which chat it is: the
        // owner has to guess which of their groups they are switching off.
        for chatID in chats.prefix(40) {
            let kind = chatID < 0 ? "👥" : "👤"
            let label = await state.chatDisplayLabel(chatID: chatID)
            let named = label != String(chatID)
            rows.append([
                menuButton("\(kind) \(label)", action: "noop"),
                menuButton("🗑 Выключить", action: "tenant:rmchat:\(chatID)"),
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
            rows.append([menuButton("📌 Включить премиум здесь", action: "tenant:claim")])
        }
        rows.append([menuButton("📥 Добавить чат по номеру", action: "tenant:assignprompt")])
        rows.append([menuButton("← К моему премиуму", action: "nav:admin")])

        let listText = chats.isEmpty ? "<i>пока ни одного</i>" : listLines.joined(separator: "\n")
        let text = """
        <b>📋 Чаты с премиумом \(invokerLabel)</b> (\(chats.count))

        \(listText)

        <i>Чтобы премиум заработал ещё в одном чате — просто добавьте туда бота, он подхватит доступ сам. \
        Или откройте нужный чат и нажмите «Включить премиум здесь». Ещё можно ввести номер чата кнопкой ниже.</i>
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    func renderAdminWhitelist(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let ids = await state.listWhitelisted(chatID: chatKey.chatID).sorted()
        var rows: [[InlineKeyboardButton]] = [
            [menuButton("➕ Добавить гостя", action: "wl:add")],
        ]
        var listLines: [String] = []
        // Guests are stored by numeric ID, but the owner recognises people by
        // name — resolve it whenever the bot has ever seen them.
        for id in ids.prefix(40) {
            let label = await state.displayLabel(forUserID: id)
            let named = label != "id \(id)"
            rows.append([
                menuButton(label, action: "noop"),
                menuButton("🗑 Убрать", action: "wl:remove:\(id)"),
            ])
            listLines.append(named ? "• <b>\(label)</b> · <code>\(id)</code>" : "• <code>\(id)</code>")
        }
        if ids.count > 40 {
            listLines.append("<i>…и ещё \(ids.count - 40)</i>")
        }
        rows.append([menuButton("← К моему премиуму", action: "nav:admin")])

        let listText = ids.isEmpty ? "<i>пусто</i>" : listLines.joined(separator: "\n")
        let text = """
        <b>👤 Гости этого чата</b> (\(ids.count))

        \(listText)

        <i>Люди, которым вы открыли умные модели в этом чате бесплатно. Добавляются по номеру пользователя в Telegram — его можно узнать, переслав сюда его сообщение любому ID-боту.</i>
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    func renderAdminDefaults(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let defs = await state.getDefaults(chatID: chatKey.chatID)
        let rows: [[InlineKeyboardButton]] = [
            [menuButton("✏️ Модель", action: "def:model")],
            [menuButton("✏️ Память", action: "def:hist")],
            [menuButton("✏️ Роль", action: "def:role")],
            [menuButton("← К моему премиуму", action: "nav:admin")],
        ]
        let text = """
        <b>⚙️ Что включается в новых чатах</b>

        🤖 Модель · <code>\(defs.model)</code>
        📝 Память · <b>\(defs.historyLength) сообщ.</b>
        🎭 Роль:
        <blockquote expandable>\(defs.role)</blockquote>

        <i>С этими настройками бот стартует в каждом новом чате. Они же возвращаются по команде /reset.</i>
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    func renderAdminUsers(chatKey: ChatKey, username: String?) async -> (String, InlineKeyboardMarkup) {
        guard let invoker = await state.userKey(username: username) else {
            return (Self.unknownAccountNotice, InlineKeyboardMarkup(inline_keyboard: [[menuButton("← Назад", action: "nav:admin")]]))
        }
        let invokerLabel = await state.displayLabel(forKey: invoker)
        let users = await state.licensedUsers(ownerUsername: invoker)

        var rows: [[InlineKeyboardButton]] = [
            [menuButton("🔗 Ссылка-приглашение", action: "nav:admininvite")],
            [menuButton("➕ Добавить по @username", action: "tenant:adduserprompt")],
        ]
        for (i, user) in users.prefix(40).enumerated() {
            rows.append([
                menuButton(user.label, action: "noop"),
                menuButton("🗑 Удалить", action: "tenant:rmuser:\(i)"),
            ])
        }
        rows.append([menuButton("← К моему премиуму", action: "nav:admin")])

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
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    func renderAdminInvite(chatKey: ChatKey, username: String?) async -> (String, InlineKeyboardMarkup) {
        // The invite is filed under the caller's storage key, like every other
        // per-person record — a raw handle would miss anyone without one.
        guard let invoker = await state.userKey(username: username) else {
            return (Self.unknownAccountNotice, InlineKeyboardMarkup(inline_keyboard: [[menuButton("← Назад", action: "nav:admin")]]))
        }
        guard await state.isTenant(username: invoker) else {
            return (
                "🔗 <b>Ссылка-приглашение</b>\n\nОна появится, как только у вас будет активный премиум: по ссылке умные модели работают за ваш счёт.",
                InlineKeyboardMarkup(inline_keyboard: [
                    [menuButton("⚡ Открыть премиум", action: "nav:pay:\(PurchaseSource.menu.rawValue)")],
                    [menuButton("← К моему премиуму", action: "nav:admin")],
                ])
            )
        }

        let token = await state.inviteToken(owner: invoker)
        var rows: [[InlineKeyboardButton]] = []
        let text: String
        if let token {
            let link = "https://t.me/\(botUsername)?start=inv_\(token)"
            rows.append([InlineKeyboardButton(text: "📨 Открыть ссылку", url: link)])
            rows.append([menuButton("♻️ Перевыпустить (старая сгорит)", action: "tenant:newinvite")])
            text = """
            <b>🔗 Ссылка-приглашение</b>

            <code>\(link)</code>

            Отправьте её кому угодно: он откроет ссылку, нажмёт «Начать» — и умные модели заработают у него за ваш счёт. Появится в списке «Гости премиума».
            """
        } else {
            rows.append([menuButton("➕ Создать ссылку", action: "tenant:newinvite")])
            text = """
            <b>🔗 Ссылка-приглашение</b>

            Ссылки пока нет. Нажмите кнопку ниже — бот создаст вашу личную ссылку, по которой друзья и коллеги получат умные модели за ваш счёт.
            """
        }
        rows.append([menuButton("← К моему премиуму", action: "nav:admin")])
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }
}
