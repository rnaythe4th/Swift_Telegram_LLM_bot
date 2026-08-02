import Foundation

// Super-admin view of tenants, wallets, admins, chats and role simulation.

extension BotMenuHandler {
    func handleTenantAction(
        route: MenuRoute,
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard !route.sub.isEmpty else { return }
        // Storage key, not the raw handle: everything below compares against
        // stored owners, which are keyed by userID.
        let invoker = invokerKey(callback)
        let isSuper = await state.isSuperAdmin(invoker)
        let isAdmin = await state.isAdmin(invoker, chatID: chatKey.chatID)
        guard isAdmin || isSuper else {
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: Texts.adminOnly)
            return
        }

        switch route.sub {
        case "claim":
            let ok = await state.assignChat(chatID: chatKey.chatID, to: invoker)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: ok ? "✓ Чат привязан" : "Премиум неактивен")
            try await showPage(.adminPanel, chatKey: chatKey, callback: callback, message: message)

        case "release":
            let owner = await state.chatOwner(chatID: chatKey.chatID)
            if !isSuper, owner != invoker {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: Texts.notYourChat)
                return
            }
            _ = await state.unassignChat(chatID: chatKey.chatID)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Чат отвязан")
            try await showPage(.adminPanel, chatKey: chatKey, callback: callback, message: message)

        case "remtoggle":
            // Sponsor's own opt-out from renewal reminders (roadmap step 8).
            let wasOptedOut = await state.remindersOptOut(invoker)
            let changed = await state.setRemindersOptOut(invoker, optOut: !wasOptedOut)
            try? await telegram.answerCallback(
                callbackQueryID: callback.id,
                text: !changed ? "Нет подписки" : (wasOptedOut ? "🔔 Буду напоминать" : "🔕 Напоминать не буду")
            )
            try await showPage(.adminPanel, chatKey: chatKey, callback: callback, message: message)

        case "rmchat":
            guard let chatID = route.chatID(2) else { return }
            let owner = await state.chatOwner(chatID: chatID)
            if !isSuper, owner != invoker {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: Texts.notYourChat)
                return
            }
            _ = await state.unassignChat(chatID: chatID)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Отвязан")
            try await showPage(.adminChats, chatKey: chatKey, callback: callback, message: message)

        case "assignprompt":
            await state.setPending(.admin(.init(kind: .tenantAssignChat, payload: invoker.storageValue)), menuMessageID: message.message_id, chatKey: chatKey)
            let prompt = """
            <b>📥 Привязать чат по ID</b>

            Отправьте chatID одним сообщением (целое число; для групп — отрицательное).
            """
            let markup: Keyboard = [[cancelButton(to: .adminChats)]]
            try await editOrAnswer(callback: callback, message: message, screen: MenuScreen(prompt, markup))
            return

        case "adduserprompt":
            await state.setPending(.admin(.init(kind: .tenantAddUser, payload: invoker.storageValue)), menuMessageID: message.message_id, chatKey: chatKey)
            let prompt = "<b>➕ Добавить гостя премиума</b>\n\nОтправьте @username одним сообщением — этот человек будет пользоваться умными моделями за ваш счёт."
            let markup: Keyboard = [[cancelButton(to: .adminUsers)]]
            try await editOrAnswer(callback: callback, message: message, screen: MenuScreen(prompt, markup))
            return

        case "rmuser":
            guard let index = route.int(2) else { return }
            let users = await state.licensedUsers(ownerKey: invoker)
            guard index >= 0, index < users.count else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Не найдено")
                return
            }
            _ = await state.removeLicensedUser(ownerKey: invoker, target: users[index].key)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Удалён")
            try await showPage(.adminUsers, chatKey: chatKey, callback: callback, message: message)

        case "newinvite":
            if await state.regenerateInviteToken(owner: invoker) != nil {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Новая ссылка создана")
            } else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Премиум неактивен — /buy")
            }
            try await showPage(.adminInvite, chatKey: chatKey, callback: callback, message: message)

        default:
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: nil)
        }
    }

    func renderSuperTenants(chatKey: ChatKey) async -> MenuScreen {
        let rows = await state.tenantStats()

        // A message Telegram cannot fit is trimmed without a word, so the tail
        // of a long list would simply vanish: cap it and say so out loud.
        let pageLimit = 20
        var lines: [String] = ["<b>🏢 Тенанты — владельцы премиума</b> (\(rows.count))"]
        if rows.isEmpty {
            lines.append("<i>нет</i>")
        } else {
            for row in rows.prefix(pageLimit) {
                let mark = row.isSuperAdmin ? "🛡" : "🛠"
                let realStr = row.usage.totalCost.formatted()
                let billedStr = await state.billedCost(of: row.usage).formatted()
                let tokens = ResponseFooterFormatter.formatTokenValue(row.usage.totalTokens)
                lines.append("\n\(mark) <b>\(row.label)</b>")
                lines.append("  чатов <b>\(row.chatCount)</b> · юзеров <b>\(row.licensedUserCount)</b> · запросов <b>\(row.usage.generationCount)</b> · ток. <b>\(tokens)</b>")
                lines.append("  💵 реально <b>\(realStr)</b> · клиентам <b>\(billedStr)</b>")
            }
        }

        if rows.count > pageLimit {
            lines.append("\n<i>Показаны первые \(pageLimit) из \(rows.count). Полный список — /tenant stats.</i>")
        }
        if !rows.isEmpty {
            lines.append("\n<i>Нажмите на тенанта — подписка и управление.</i>")
        }

        var buttons: Keyboard = [[menuButton("➕ Зарегистрировать тенанта", .stenant, "add")]]
        for row in rows.prefix(pageLimit) {
            var btnRow = [menuButton("\(row.isSuperAdmin ? "🛡" : "🛠") \(row.label)", .stenant, "info", "\(row.key.storageValue)")]
            if !row.isSuperAdmin {
                btnRow.append(menuButton("🗑", .stenant, "rm", "\(row.key.storageValue)"))
            }
            buttons.row(btnRow)
        }
        buttons.row([menuButton("🛡 Суперадмины", page: .superAdmins)])
        buttons.row([backButton(to: .superAdmin)])

        return MenuScreen(lines.joined(separator: "\n"), buttons)
    }

    func renderSuperTenantInfo(invoker target: UserKey) async -> MenuScreen {
        guard let row = await state.tenantStats().first(where: { $0.key == target }) else {
            return MenuScreen(
                "Тенант @\(target) не найден.",
                [[backButton(to: .superTenants)]]
            )
        }

        let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy"
        let subLine: String
        if let until = row.paidUntil {
            subLine = row.isActive
                ? "💳 Подписка · до <b>\(f.string(from: until))</b>"
                : "💳 Подписка · <b>⛔ истекла \(f.string(from: until))</b>"
        } else {
            subLine = "💳 Подписка · <b>бессрочная</b>"
        }
        let realStr = row.usage.totalCost.formatted()
        let billedStr = await state.billedCost(of: row.usage).formatted()

        let text = """
        <b>🏢 Тенант \(row.label)</b>\(row.isSuperAdmin ? " · 🛡 суперадмин" : "")

        \(subLine)
        Чатов · <b>\(row.chatCount)</b> · юзеров · <b>\(row.licensedUserCount)</b>
        📈 запросов <b>\(row.usage.generationCount)</b> · токенов <b>\(ResponseFooterFormatter.formatTokenValue(row.usage.totalTokens))</b>
        💵 реально <b>\(realStr)</b> · клиентам <b>\(billedStr)</b>
        """

        var buttons: Keyboard = [
            [menuButton("⏳ Продлить +\(ChatContextStore.subscriptionDays) дн.", .stenant, "ext", "\(row.key.storageValue)")],
            [menuButton("♾ Бессрочно", .stenant, "unlim", "\(row.key.storageValue)"),
             menuButton("⛔ Истечь сейчас", .stenant, "exp", "\(row.key.storageValue)")],
        ]
        if !row.isSuperAdmin {
            buttons.row([menuButton("🗑 Удалить тенанта", .stenant, "rm", "\(row.key.storageValue)")])
        }
        buttons.row([backButton(to: .superTenants)])
        return MenuScreen(text, buttons)
    }

    func renderSuperBalances(chatKey: ChatKey) async -> MenuScreen {
        let balances = await state.allBalances()
        let markupPct = await state.markupPercent()
        func usd(_ v: Money) -> String { v.formatted() }

        var lines = ["<b>💰 Балансы (pay-as-you-go)</b> (\(balances.count)) · наценка <b>\(markupPct)%</b>", ""]
        if balances.isEmpty {
            lines.append("<i>Кошельков нет. Баланс — оплата платных моделей по факту, без подписки: начислите сумму, бот списывает стоимость каждого ответа с наценкой.</i>")
        } else {
            var totalBalance = Money.zero, totalBilled = Money.zero, totalReal = Money.zero
            // Totals cover everyone; the per-wallet list is capped so the page
            // is never silently trimmed by Telegram's length limit.
            let listLimit = 20
            for (index, entry) in balances.enumerated() {
                let w = entry.wallet
                totalBalance += w.balance
                totalBilled += w.spentBilled
                totalReal += w.spentReal
                guard index < listLimit else { continue }
                lines.append("• <b>\(entry.label)</b> · остаток <b>\(usd(w.balance))</b>")
                lines.append("  списано \(usd(w.spentBilled)) · реально \(usd(w.spentReal)) · маржа <b>\(usd(w.margin))</b>")
            }
            if balances.count > listLimit {
                lines.append("<i>…и ещё \(balances.count - listLimit) — полный список /balance list</i>")
            }
            lines.append("")
            lines.append("<b>Итого</b> · остатки \(usd(totalBalance)) · маржа <b>\(usd(totalBilled - totalReal))</b>")
        }

        var buttons: Keyboard = [[menuButton("➕ Начислить / списать", .sbal, "add")]]
        for entry in balances.prefix(30) {
            buttons.row([
                menuButton("\(entry.label) · \(usd(entry.wallet.balance))", command: .noop),
                menuButton("🗑", .sbal, "rm", "\(entry.key)"),
            ])
        }
        buttons.row([menuButton("💹 Наценка · \(markupPct)%", .markup, "set")])
        buttons.row([backButton(to: .superAdmin)])
        return MenuScreen(lines.joined(separator: "\n"), buttons)
    }

    func renderSuperAdmins(chatKey: ChatKey, invoker: UserKey?) async -> MenuScreen {
        let supers = await state.listSuperAdmins()
        let isRoot = await state.isRootSuperAdmin(invoker)

        var rows: Keyboard = []
        if isRoot {
            rows.row([menuButton("➕ Добавить @username", .sa, "add")])
            for admin in supers {
                rows.row([
                    menuButton(admin.label, command: .noop),
                    menuButton("🗑 Удалить", .sa, "rm", "\(admin.key)"),
                ])
            }
        }
        rows.row([backButton(to: .superAdmin)])

        let listText = supers.isEmpty ? "<i>нет</i>" : supers.map { "• \($0.label)" }.joined(separator: "\n")
        let footer = isRoot
            ? ""
            : "\n\n<i>Только главный суперадмин может изменять список.</i>"
        let text = """
        <b>🛡 Суперадмины</b> (\(supers.count))

        \(listText)\(footer)
        """
        return MenuScreen(text, rows)
    }

    func renderSuperSimulate(chatKey: ChatKey, invoker: UserKey?) async -> MenuScreen {
        let role = await state.simulatedRole(invoker)
        let label: String
        switch role {
        case .admin: label = "админ"
        case .regularUser: label = "обычный пользователь"
        case nil: label = "выкл (суперадмин)"
        }

        let rows: Keyboard = [
            [menuButton((role == .admin ? "✓ " : "") + "🛠 Админ", .sim, "admin")],
            [menuButton((role == .regularUser ? "✓ " : "") + "👤 Обычный пользователь", .sim, "user")],
            [menuButton((role == nil ? "✓ " : "") + "⛔ Выключить", .sim, "off")],
            [menuButton("🧪 Тест покупки", .sim, "buy")],
            [backButton(to: .superAdmin)],
        ]

        let text = """
        <b>🎭 Симуляция роли</b>

        Текущий режим · <b>\(label)</b>

        <i>Только в текущем процессе бота, не сохраняется при рестарте.</i>
        """
        return MenuScreen(text, rows)
    }

    func renderSuperChats(chatKey: ChatKey) async -> MenuScreen {
        let groups = await state.groupChats()
        let privates = await state.privateChats()
        let uniqueGroupIDs = Array(Set(groups.map(\.chatID))).sorted()
        let uniquePrivateIDs = Array(Set(privates.map(\.chatID))).sorted()

        var rows: Keyboard = []
        for chatID in uniqueGroupIDs.prefix(20) {
            let label = await state.chatDisplayLabel(chatID: chatID)
            rows.row([menuButton("👥 \(label)", .sinspect, "\(chatID)")])
        }
        for chatID in uniquePrivateIDs.prefix(20) {
            let label = await state.chatDisplayLabel(chatID: chatID)
            rows.row([menuButton("👤 \(label)", .sinspect, "\(chatID)")])
        }
        rows.row([backButton(to: .superAdmin)])

        let truncated = uniqueGroupIDs.count > 20 || uniquePrivateIDs.count > 20
        let text = """
        <b>👁 Чаты бота</b>

        Группы · <b>\(uniqueGroupIDs.count)</b> · личные · <b>\(uniquePrivateIDs.count)</b>

        Нажмите на чат — откроются его настройки, роль и статистика.\(truncated ? "\nПоказаны первые 20 каждого типа; полный список — /chats, детали — /inspect <chatID>." : "")
        """
        return MenuScreen(text, rows)
    }

    func renderInspect(chatID: ChatID) async -> MenuScreen {
        let label = await state.chatDisplayLabel(chatID: chatID)
        let owner = await state.chatOwnerLabel(chatID: chatID)
        let keys = await state.existingContextKeys(chatID: chatID)

        var lines = ["<b>👁 \(label)</b> · <code>\(chatID)</code>"]
        lines.append(owner.map { "Премиум · \($0)" } ?? "Премиум · <i>нет (бесплатный)</i>")

        if keys.isEmpty {
            lines.append("\n<i>Контекст ещё не создан.</i>")
        }
        for key in keys.prefix(5) {
            guard let help = await state.peekHelp(chatKey: key) else { continue }
            lines.append("")
            lines.append(key.threadID == 0 ? "<b>Основной тред</b>" : "<b>Топик \(key.threadID)</b>")
            lines.append("🤖 <code>\(help.model)</code> · 🌡 \(Self.formatTemp(help.temp)) · 📝 \(help.maxHistory)")
            let realStr = help.cumulativeUsage.totalCost.formatted()
            let billedStr = await state.billedCost(of: help.cumulativeUsage).formatted()
            lines.append("📈 запросов \(help.cumulativeUsage.generationCount) · токенов \(ResponseFooterFormatter.formatTokenValue(help.cumulativeUsage.totalTokens)) · реально \(realStr) · клиентам \(billedStr)")
            let rolePreview = help.role.count > 250 ? String(help.role.prefix(250)) + "…" : help.role
            lines.append("🎭 <blockquote expandable>\(rolePreview)</blockquote>")
        }
        if keys.count > 5 {
            lines.append("\n<i>…и ещё \(keys.count - 5) топиков — /inspect \(chatID)</i>")
        }

        let rows: Keyboard = [
            [backButton(to: .superChats)],
        ]
        return MenuScreen(lines.joined(separator: "\n"), rows)
    }

    // MARK: - Actions behind the buttons on those pages

    /// `sa:*` — the super-admin roster. Only root adds or removes.
    func handleSuperAdminRosterAction(
        route: MenuRoute,
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard await requireSuperAdmin(callback) else { return }
        guard !route.sub.isEmpty else { return }
        switch route.sub {
        case "add":
            guard await requireRootSuperAdmin(callback) else { return }
            await state.setPending(.admin(.init(kind: .superAdminAdd)), menuMessageID: message.message_id, chatKey: chatKey)
            let prompt = "<b>🛡 Добавить суперадмина</b>\n\nОтправьте @username одним сообщением."
            let markup: Keyboard = [[cancelButton(to: .superAdmins)]]
            try await editOrAnswer(callback: callback, message: message, screen: MenuScreen(prompt, markup))
        case "rm":
            guard await requireRootSuperAdmin(callback) else { return }
            guard let target = route.userKey(2) else { return }
            let ok = await state.removeSuperAdmin(target)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: ok ? "✓ Удалён" : "Не удалось")
            try await showPage(.superAdmins, chatKey: chatKey, callback: callback, message: message)
        default:
            try await showPage(.superAdmins, chatKey: chatKey, callback: callback, message: message)
        }
    }

    /// `stenant:*` — tenant list, one tenant's card and its subscription.
    func handleSuperTenantAction(
        route: MenuRoute,
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard await requireSuperAdmin(callback) else { return }
        guard !route.sub.isEmpty else { return }
        switch route.sub {
        case "add":
            await state.setPending(.admin(.init(kind: .tenantRegister)), menuMessageID: message.message_id, chatKey: chatKey)
            let prompt = "<b>🏢 Зарегистрировать тенанта</b>\n\nОтправьте @username одним сообщением."
            let markup: Keyboard = [[cancelButton(to: .superTenants)]]
            try await editOrAnswer(callback: callback, message: message, screen: MenuScreen(prompt, markup))
        case "rm":
            // Deleting a tenant throws away a paid subscription, their
            // chats and their guest list — a mis-tap in a list of names
            // must not be able to do that silently.
            guard let target = route.userKey(2) else { return }
            let label = await state.displayLabel(forKey: target)
            let row = await state.tenantStats().first { $0.key == target }
            let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy"
            let subLine: String
            if let row {
                subLine = row.paidUntil.map { "Подписка до <b>\(f.string(from: $0))</b> · чатов <b>\(row.chatCount)</b> · гостей <b>\(row.licensedUserCount)</b>" }
                    ?? "Подписка <b>бессрочная</b> · чатов <b>\(row.chatCount)</b> · гостей <b>\(row.licensedUserCount)</b>"
            } else {
                subLine = "<i>данных нет</i>"
            }
            let confirmText = """
            <b>🗑 Удалить тенанта \(label)?</b>

            \(subLine)

            ⚠️ Подписка, привязанные чаты и список гостей пропадут. Их чаты вернутся на бесплатные модели. Отменить нельзя — только оформить заново.
            """
            let confirmMarkup: Keyboard = [
                [menuButton("🗑 Да, удалить", .stenant, "rmyes", "\(target)")],
                [cancelButton(to: .superTenants)],
            ]
            try await editOrAnswer(callback: callback, message: message, screen: MenuScreen(confirmText, confirmMarkup))
        case "rmyes":
            guard let target = route.userKey(2) else { return }
            let removed = await state.removeTenant(target)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: removed ? "✓ Удалён" : Texts.cannotRemove)
            try await showPage(.superTenants, chatKey: chatKey, callback: callback, message: message)
        case "info":
            guard let target = route.userKey(2) else { return }
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: nil)
            try await editOrAnswer(callback: callback, message: message, screen: await renderSuperTenantInfo(invoker: target))
        case "ext":
            guard let target = route.userKey(2) else { return }
            switch await extendSubscription(key: target, days: ChatContextStore.subscriptionDays) {
            case .extended(let until):
                let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy"
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Продлена до \(f.string(from: until))")
            case .alreadyUnlimited:
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: Texts.subscriptionAlreadyUnlimited)
            case .unknownTenant:
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: Texts.tenantNotFound)
            }
            try await editOrAnswer(callback: callback, message: message, screen: await renderSuperTenantInfo(invoker: target))
        case "unlim":
            guard let target = route.userKey(2) else { return }
            let ok = await setSubscriptionUnlimited(key: target)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: ok ? "✓ Подписка бессрочная" : Texts.tenantNotFound)
            try await editOrAnswer(callback: callback, message: message, screen: await renderSuperTenantInfo(invoker: target))
        case "exp":
            guard let target = route.userKey(2) else { return }
            let ok = await expireSubscription(key: target)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: ok ? "⛔ Подписка завершена" : Texts.tenantNotFound)
            try await editOrAnswer(callback: callback, message: message, screen: await renderSuperTenantInfo(invoker: target))
        default:
            try await showPage(.superTenants, chatKey: chatKey, callback: callback, message: message)
        }
    }

    /// `sim:*` — pretend to be an admin or a regular user (CLAUDE.md §6).
    func handleSimulationAction(
        route: MenuRoute,
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard await state.isActuallySuperAdmin(invokerKey(callback)) else {
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: Texts.superAdminOnly)
            return
        }
        guard !route.sub.isEmpty else { return }
        // Simulation is filed under the same key as the role it shadows.
        let invoker = invokerKey(callback)
        switch route.sub {
        case "admin":
            _ = await state.setSimulatedRole(invoker, role: .admin)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Симуляция: админ")
        case "user":
            _ = await state.setSimulatedRole(invoker, role: .regularUser)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Симуляция: юзер")
        case "off":
            _ = await state.setSimulatedRole(invoker, role: nil)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Симуляция выкл")
        case "buy":
            let activation = await state.activatePaidSubscription(invoker)
            await state.assignChat(chatID: chatKey.chatID, to: invoker)
            let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy"
            let note: String
            switch activation {
            case .started(let until): note = "🧪 Tenant создан, подписка до \(f.string(from: until))"
            case .extended(let until): note = "🧪 Подписка продлена до \(f.string(from: until))"
            case .alreadyUnlimited: note = "🧪 У вас бессрочный доступ"
            }
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: note)
        default:
            break
        }
        try await showPage(.superSimulate, chatKey: chatKey, callback: callback, message: message)
    }

    /// `sinspect:<chatID>` — one chat's settings and usage.
    func handleInspectChatAction(
        route: MenuRoute,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard await requireSuperAdmin(callback) else { return }
        guard let targetChatID = route.chatID(1) else { return }
        try await editOrAnswer(callback: callback, message: message, screen: await renderInspect(chatID: targetChatID))
    }

    /// `sbal:*` — wallets: top-up prompt and deletion (with confirmation).
    func handleWalletAdminAction(
        route: MenuRoute,
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard await requireSuperAdmin(callback) else { return }
        guard !route.sub.isEmpty else { return }
        switch route.sub {
        case "add":
            await state.setPending(.admin(.init(kind: .balanceTopUp)), menuMessageID: message.message_id, chatKey: chatKey)
            let prompt = """
            <b>💰 Начислить / списать баланс</b>

            Отправьте одним сообщением: <code>@username сумма</code>

            <i>Пример:</i> <code>@user 5</code> — начислить $5
            Отрицательная сумма — списать. Кошелёк создаётся автоматически.
            """
            let markup: Keyboard = [[cancelButton(to: .superBalances)]]
            try await editOrAnswer(callback: callback, message: message, screen: MenuScreen(prompt, markup))
        case "rm":
            // The wallet holds money the person paid for: confirm before
            // it disappears from a one-tap row in a list.
            guard let target = route.userKey(2) else { return }
            let label = await state.displayLabel(forKey: target)
            let wallet = await state.balance(target)
            let amount = wallet.map { $0.balance.formatted() } ?? "—"
            let confirmText = """
            <b>🗑 Удалить кошелёк \(label)?</b>

            Остаток · <b>\(amount)</b>

            ⚠️ Остаток пропадёт вместе с историей списаний. Если человек пополнял баланс деньгами, это его деньги. Отменить нельзя.
            """
            let confirmMarkup: Keyboard = [
                [menuButton("🗑 Да, удалить", .sbal, "rmyes", "\(target)")],
                [cancelButton(to: .superBalances)],
            ]
            try await editOrAnswer(callback: callback, message: message, screen: MenuScreen(confirmText, confirmMarkup))
        case "rmyes":
            guard let target = route.userKey(2) else { return }
            let removed = await state.removeBalance(target)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: removed ? "✓ Кошелёк удалён" : "Кошелёк не найден")
            try await showPage(.superBalances, chatKey: chatKey, callback: callback, message: message)
        default:
            try await showPage(.superBalances, chatKey: chatKey, callback: callback, message: message)
        }
    }
}
