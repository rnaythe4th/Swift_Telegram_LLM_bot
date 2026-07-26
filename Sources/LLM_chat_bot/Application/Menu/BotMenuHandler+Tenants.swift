import Foundation

// Super-admin view of tenants, wallets, admins, chats and role simulation.

extension BotMenuHandler {
    func handleTenantAction(
        parts: [String],
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard parts.count >= 2 else { return }
        // Storage key, not the raw handle: everything below compares against
        // stored owners, which are keyed by userID.
        let invoker = invokerKey(callback)
        let isSuper = await state.isSuperAdmin(username: invoker)
        let isAdmin = await state.isAdmin(username: invoker, chatID: chatKey.chatID)
        guard isAdmin || isSuper else {
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только админ")
            return
        }

        switch parts[1] {
        case "claim":
            let ok = await state.assignChat(chatID: chatKey.chatID, to: invoker)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: ok ? "✓ Чат привязан" : "Премиум неактивен")
            try await showPage(.adminPanel, chatKey: chatKey, callback: callback, message: message)

        case "release":
            let owner = await state.chatOwner(chatID: chatKey.chatID)
            if !isSuper, owner != invoker {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Не ваш чат")
                return
            }
            _ = await state.unassignChat(chatID: chatKey.chatID)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Чат отвязан")
            try await showPage(.adminPanel, chatKey: chatKey, callback: callback, message: message)

        case "remtoggle":
            // Sponsor's own opt-out from renewal reminders (roadmap step 8).
            let wasOptedOut = await state.remindersOptOut(username: invoker)
            let changed = await state.setRemindersOptOut(username: invoker, optOut: !wasOptedOut)
            try? await telegram.answerCallback(
                callbackQueryID: callback.id,
                text: !changed ? "Нет подписки" : (wasOptedOut ? "🔔 Буду напоминать" : "🔕 Напоминать не буду")
            )
            try await showPage(.adminPanel, chatKey: chatKey, callback: callback, message: message)

        case "rmchat":
            guard parts.count >= 3, let chatID = Int(parts[2]) else { return }
            let owner = await state.chatOwner(chatID: chatID)
            if !isSuper, owner != invoker {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Не ваш чат")
                return
            }
            _ = await state.unassignChat(chatID: chatID)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Отвязан")
            try await showPage(.adminChats, chatKey: chatKey, callback: callback, message: message)

        case "assignprompt":
            await state.setAdminPendingInput(.init(kind: .tenantAssignChat, menuMessageID: message.message_id, payload: invoker), chatKey: chatKey)
            let prompt = """
            <b>📥 Привязать чат по ID</b>

            Отправьте chatID одним сообщением (целое число; для групп — отрицательное).
            """
            let markup = InlineKeyboardMarkup(inline_keyboard: [[menuButton("❌ Отмена", action: "nav:adminchats")]])
            try await editOrAnswer(callback: callback, message: message, text: prompt, markup: markup)
            return

        case "adduserprompt":
            await state.setAdminPendingInput(.init(kind: .tenantAddUser, menuMessageID: message.message_id, payload: invoker), chatKey: chatKey)
            let prompt = "<b>➕ Добавить гостя премиума</b>\n\nОтправьте @username одним сообщением — этот человек будет пользоваться умными моделями за ваш счёт."
            let markup = InlineKeyboardMarkup(inline_keyboard: [[menuButton("❌ Отмена", action: "nav:adminusers")]])
            try await editOrAnswer(callback: callback, message: message, text: prompt, markup: markup)
            return

        case "rmuser":
            guard parts.count >= 3, let index = Int(parts[2]) else { return }
            let users = await state.licensedUsers(ownerUsername: invoker)
            guard index >= 0, index < users.count else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Не найдено")
                return
            }
            _ = await state.removeLicensedUser(ownerUsername: invoker, target: users[index].key)
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

    func renderSuperTenants(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
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
                let realStr = String(format: "$%.4f", row.usage.totalCost)
                let billedStr = String(format: "$%.4f", await state.billedCost(of: row.usage))
                let tokens = Int(row.usage.totalTokens)
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

        var buttons: [[InlineKeyboardButton]] = [[menuButton("➕ Зарегистрировать тенанта", action: "stenant:add")]]
        for row in rows.prefix(pageLimit) {
            var btnRow = [menuButton("\(row.isSuperAdmin ? "🛡" : "🛠") \(row.label)", action: "stenant:info:\(row.username)")]
            if !row.isSuperAdmin {
                btnRow.append(menuButton("🗑", action: "stenant:rm:\(row.username)"))
            }
            buttons.append(btnRow)
        }
        buttons.append([menuButton("🛡 Суперадмины", action: "nav:superadmins")])
        buttons.append([menuButton("← К супер-админу", action: "nav:superadmin")])

        return (lines.joined(separator: "\n"), InlineKeyboardMarkup(inline_keyboard: buttons))
    }

    func renderSuperTenantInfo(username: String) async -> (String, InlineKeyboardMarkup) {
        let target = username.lowercased()
        guard let row = await state.tenantStats().first(where: { $0.username == target }) else {
            return (
                "Тенант @\(target) не найден.",
                InlineKeyboardMarkup(inline_keyboard: [[menuButton("← К тенантам", action: "nav:supertenants")]])
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
        let realStr = String(format: "$%.4f", row.usage.totalCost)
        let billedStr = String(format: "$%.4f", await state.billedCost(of: row.usage))

        let text = """
        <b>🏢 Тенант \(row.label)</b>\(row.isSuperAdmin ? " · 🛡 суперадмин" : "")

        \(subLine)
        Чатов · <b>\(row.chatCount)</b> · юзеров · <b>\(row.licensedUserCount)</b>
        📈 запросов <b>\(row.usage.generationCount)</b> · токенов <b>\(Int(row.usage.totalTokens))</b>
        💵 реально <b>\(realStr)</b> · клиентам <b>\(billedStr)</b>
        """

        var buttons: [[InlineKeyboardButton]] = [
            [menuButton("⏳ Продлить +\(ChatContextStore.subscriptionDays) дн.", action: "stenant:ext:\(row.username)")],
            [menuButton("♾ Бессрочно", action: "stenant:unlim:\(row.username)"),
             menuButton("⛔ Истечь сейчас", action: "stenant:exp:\(row.username)")],
        ]
        if !row.isSuperAdmin {
            buttons.append([menuButton("🗑 Удалить тенанта", action: "stenant:rm:\(row.username)")])
        }
        buttons.append([menuButton("← К тенантам", action: "nav:supertenants")])
        return (text, InlineKeyboardMarkup(inline_keyboard: buttons))
    }

    func renderSuperBalances(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let balances = await state.allBalances()
        let markupPct = await state.markupPercent()
        func usd(_ v: Double) -> String { String(format: "$%.4f", v) }

        var lines = ["<b>💰 Балансы (pay-as-you-go)</b> (\(balances.count)) · наценка <b>\(markupPct)%</b>", ""]
        if balances.isEmpty {
            lines.append("<i>Кошельков нет. Баланс — оплата платных моделей по факту, без подписки: начислите сумму, бот списывает стоимость каждого ответа с наценкой.</i>")
        } else {
            var totalBalance = 0.0, totalBilled = 0.0, totalReal = 0.0
            // Totals cover everyone; the per-wallet list is capped so the page
            // is never silently trimmed by Telegram's length limit.
            let listLimit = 20
            for (index, entry) in balances.enumerated() {
                let w = entry.wallet
                totalBalance += w.balanceUsd
                totalBilled += w.spentBilledUsd
                totalReal += w.spentRealUsd
                guard index < listLimit else { continue }
                lines.append("• <b>\(entry.label)</b> · остаток <b>\(usd(w.balanceUsd))</b>")
                lines.append("  списано \(usd(w.spentBilledUsd)) · реально \(usd(w.spentRealUsd)) · маржа <b>\(usd(w.spentBilledUsd - w.spentRealUsd))</b>")
            }
            if balances.count > listLimit {
                lines.append("<i>…и ещё \(balances.count - listLimit) — полный список /balance list</i>")
            }
            lines.append("")
            lines.append("<b>Итого</b> · остатки \(usd(totalBalance)) · маржа <b>\(usd(totalBilled - totalReal))</b>")
        }

        var buttons: [[InlineKeyboardButton]] = [[menuButton("➕ Начислить / списать", action: "sbal:add")]]
        for entry in balances.prefix(30) {
            buttons.append([
                menuButton("\(entry.label) · \(usd(entry.wallet.balanceUsd))", action: "noop"),
                menuButton("🗑", action: "sbal:rm:\(entry.key)"),
            ])
        }
        buttons.append([menuButton("💹 Наценка · \(markupPct)%", action: "markup:set")])
        buttons.append([menuButton("← К супер-админу", action: "nav:superadmin")])
        return (lines.joined(separator: "\n"), InlineKeyboardMarkup(inline_keyboard: buttons))
    }

    func renderSuperAdmins(chatKey: ChatKey, username: String?) async -> (String, InlineKeyboardMarkup) {
        let supers = await state.listSuperAdmins()
        let isRoot = await state.isRootSuperAdmin(username: username)

        var rows: [[InlineKeyboardButton]] = []
        if isRoot {
            rows.append([menuButton("➕ Добавить @username", action: "sa:add")])
            for admin in supers {
                rows.append([
                    menuButton(admin.label, action: "noop"),
                    menuButton("🗑 Удалить", action: "sa:rm:\(admin.key)"),
                ])
            }
        }
        rows.append([menuButton("← К супер-админу", action: "nav:superadmin")])

        let listText = supers.isEmpty ? "<i>нет</i>" : supers.map { "• \($0.label)" }.joined(separator: "\n")
        let footer = isRoot
            ? ""
            : "\n\n<i>Только главный суперадмин может изменять список.</i>"
        let text = """
        <b>🛡 Суперадмины</b> (\(supers.count))

        \(listText)\(footer)
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    func renderSuperSimulate(chatKey: ChatKey, username: String?) async -> (String, InlineKeyboardMarkup) {
        let role = await state.simulatedRole(username: username)
        let label: String
        switch role {
        case .admin: label = "админ"
        case .regularUser: label = "обычный пользователь"
        case nil: label = "выкл (суперадмин)"
        }

        let rows: [[InlineKeyboardButton]] = [
            [menuButton((role == .admin ? "✓ " : "") + "🛠 Админ", action: "sim:admin")],
            [menuButton((role == .regularUser ? "✓ " : "") + "👤 Обычный пользователь", action: "sim:user")],
            [menuButton((role == nil ? "✓ " : "") + "⛔ Выключить", action: "sim:off")],
            [menuButton("🧪 Тест покупки", action: "sim:buy")],
            [menuButton("← К супер-админу", action: "nav:superadmin")],
        ]

        let text = """
        <b>🎭 Симуляция роли</b>

        Текущий режим · <b>\(label)</b>

        <i>Только в текущем процессе бота, не сохраняется при рестарте.</i>
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    func renderSuperChats(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let groups = await state.groupChats()
        let privates = await state.privateChats()
        let uniqueGroupIDs = Array(Set(groups.map(\.chatID))).sorted()
        let uniquePrivateIDs = Array(Set(privates.map(\.chatID))).sorted()

        var rows: [[InlineKeyboardButton]] = []
        for chatID in uniqueGroupIDs.prefix(20) {
            let label = await state.chatDisplayLabel(chatID: chatID)
            rows.append([menuButton("👥 \(label)", action: "sinspect:\(chatID)")])
        }
        for chatID in uniquePrivateIDs.prefix(20) {
            let label = await state.chatDisplayLabel(chatID: chatID)
            rows.append([menuButton("👤 \(label)", action: "sinspect:\(chatID)")])
        }
        rows.append([menuButton("← К супер-админу", action: "nav:superadmin")])

        let truncated = uniqueGroupIDs.count > 20 || uniquePrivateIDs.count > 20
        let text = """
        <b>👁 Чаты бота</b>

        Группы · <b>\(uniqueGroupIDs.count)</b> · личные · <b>\(uniquePrivateIDs.count)</b>

        Нажмите на чат — откроются его настройки, роль и статистика.\(truncated ? "\nПоказаны первые 20 каждого типа; полный список — /chats, детали — /inspect <chatID>." : "")
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    func renderInspect(chatID: Int) async -> (String, InlineKeyboardMarkup) {
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
            let realStr = String(format: "$%.4f", help.cumulativeUsage.totalCost)
            let billedStr = String(format: "$%.4f", await state.billedCost(of: help.cumulativeUsage))
            lines.append("📈 запросов \(help.cumulativeUsage.generationCount) · токенов \(Int(help.cumulativeUsage.totalTokens)) · реально \(realStr) · клиентам \(billedStr)")
            let rolePreview = help.role.count > 250 ? String(help.role.prefix(250)) + "…" : help.role
            lines.append("🎭 <blockquote expandable>\(rolePreview)</blockquote>")
        }
        if keys.count > 5 {
            lines.append("\n<i>…и ещё \(keys.count - 5) топиков — /inspect \(chatID)</i>")
        }

        let rows: [[InlineKeyboardButton]] = [
            [menuButton("← К списку чатов", action: "nav:superchats")],
        ]
        return (lines.joined(separator: "\n"), InlineKeyboardMarkup(inline_keyboard: rows))
    }

    // MARK: - Actions behind the buttons on those pages

    /// `sa:*` — the super-admin roster. Only root adds or removes.
    func handleSuperAdminRosterAction(
        parts: [String],
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard await state.isSuperAdmin(username: invokerKey(callback)) else {
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
            return
        }
        guard parts.count >= 2 else { return }
        switch parts[1] {
        case "add":
            guard await state.isRootSuperAdmin(username: invokerKey(callback)) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только главный суперадмин")
                return
            }
            await state.setAdminPendingInput(.init(kind: .superAdminAdd, menuMessageID: message.message_id, payload: nil), chatKey: chatKey)
            let prompt = "<b>🛡 Добавить суперадмина</b>\n\nОтправьте @username одним сообщением."
            let markup = InlineKeyboardMarkup(inline_keyboard: [[menuButton("❌ Отмена", action: "nav:superadmins")]])
            try await editOrAnswer(callback: callback, message: message, text: prompt, markup: markup)
        case "rm":
            guard await state.isRootSuperAdmin(username: invokerKey(callback)) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только главный суперадмин")
                return
            }
            guard parts.count >= 3 else { return }
            let target = parts[2]
            let ok = await state.removeSuperAdmin(target: target)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: ok ? "✓ Удалён" : "Не удалось")
            try await showPage(.superAdmins, chatKey: chatKey, callback: callback, message: message)
        default:
            try await showPage(.superAdmins, chatKey: chatKey, callback: callback, message: message)
        }
    }

    /// `stenant:*` — tenant list, one tenant's card and its subscription.
    func handleSuperTenantAction(
        parts: [String],
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard await state.isSuperAdmin(username: invokerKey(callback)) else {
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
            return
        }
        guard parts.count >= 2 else { return }
        switch parts[1] {
        case "add":
            await state.setAdminPendingInput(.init(kind: .tenantRegister, menuMessageID: message.message_id, payload: nil), chatKey: chatKey)
            let prompt = "<b>🏢 Зарегистрировать тенанта</b>\n\nОтправьте @username одним сообщением."
            let markup = InlineKeyboardMarkup(inline_keyboard: [[menuButton("❌ Отмена", action: "nav:supertenants")]])
            try await editOrAnswer(callback: callback, message: message, text: prompt, markup: markup)
        case "rm":
            // Deleting a tenant throws away a paid subscription, their
            // chats and their guest list — a mis-tap in a list of names
            // must not be able to do that silently.
            guard parts.count >= 3 else { return }
            let target = parts[2]
            let label = await state.displayLabel(forKey: target)
            let row = await state.tenantStats().first { $0.username == target }
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
            let confirmMarkup = InlineKeyboardMarkup(inline_keyboard: [
                [menuButton("🗑 Да, удалить", action: "stenant:rmyes:\(target)")],
                [menuButton("❌ Отмена", action: "nav:supertenants")],
            ])
            try await editOrAnswer(callback: callback, message: message, text: confirmText, markup: confirmMarkup)
        case "rmyes":
            guard parts.count >= 3 else { return }
            let removed = await state.removeTenant(username: parts[2])
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: removed ? "✓ Удалён" : "Нельзя удалить")
            try await showPage(.superTenants, chatKey: chatKey, callback: callback, message: message)
        case "info":
            guard parts.count >= 3 else { return }
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: nil)
            let (text, markup) = await renderSuperTenantInfo(username: parts[2])
            try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)
        case "ext":
            guard parts.count >= 3 else { return }
            if let until = await state.extendTenantSubscription(username: parts[2], days: ChatContextStore.subscriptionDays) {
                let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy"
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Продлена до \(f.string(from: until))")
            } else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Тенант не найден")
            }
            let (text, markup) = await renderSuperTenantInfo(username: parts[2])
            try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)
        case "unlim":
            guard parts.count >= 3 else { return }
            let ok = await state.setTenantUnlimited(username: parts[2])
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: ok ? "✓ Подписка бессрочная" : "Тенант не найден")
            let (text, markup) = await renderSuperTenantInfo(username: parts[2])
            try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)
        case "exp":
            guard parts.count >= 3 else { return }
            let ok = await state.expireTenantSubscription(username: parts[2])
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: ok ? "⛔ Подписка завершена" : "Тенант не найден")
            let (text, markup) = await renderSuperTenantInfo(username: parts[2])
            try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)
        default:
            try await showPage(.superTenants, chatKey: chatKey, callback: callback, message: message)
        }
    }

    /// `sim:*` — pretend to be an admin or a regular user (CLAUDE.md §6).
    func handleSimulationAction(
        parts: [String],
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard await state.isActuallySuperAdmin(username: invokerKey(callback)) else {
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
            return
        }
        guard parts.count >= 2 else { return }
        // Simulation is filed under the same key as the role it shadows.
        let username = invokerKey(callback)
        switch parts[1] {
        case "admin":
            _ = await state.setSimulatedRole(username: username, role: .admin)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Симуляция: админ")
        case "user":
            _ = await state.setSimulatedRole(username: username, role: .regularUser)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Симуляция: юзер")
        case "off":
            _ = await state.setSimulatedRole(username: username, role: nil)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Симуляция выкл")
        case "buy":
            let activation = await state.activatePaidSubscription(username: username)
            await state.assignChat(chatID: chatKey.chatID, to: username.lowercased())
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
        parts: [String],
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard await state.isSuperAdmin(username: invokerKey(callback)) else {
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
            return
        }
        guard parts.count >= 2, let targetChatID = Int(parts[1]) else { return }
        let (text, markup) = await renderInspect(chatID: targetChatID)
        try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)
    }

    /// `sbal:*` — wallets: top-up prompt and deletion (with confirmation).
    func handleWalletAdminAction(
        parts: [String],
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard await state.isSuperAdmin(username: invokerKey(callback)) else {
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
            return
        }
        guard parts.count >= 2 else { return }
        switch parts[1] {
        case "add":
            await state.setAdminPendingInput(.init(kind: .balanceTopUp, menuMessageID: message.message_id, payload: nil), chatKey: chatKey)
            let prompt = """
            <b>💰 Начислить / списать баланс</b>

            Отправьте одним сообщением: <code>@username сумма</code>

            <i>Пример:</i> <code>@user 5</code> — начислить $5
            Отрицательная сумма — списать. Кошелёк создаётся автоматически.
            """
            let markup = InlineKeyboardMarkup(inline_keyboard: [[menuButton("❌ Отмена", action: "nav:superbal")]])
            try await editOrAnswer(callback: callback, message: message, text: prompt, markup: markup)
        case "rm":
            // The wallet holds money the person paid for: confirm before
            // it disappears from a one-tap row in a list.
            guard parts.count >= 3 else { return }
            let target = parts[2]
            let label = await state.displayLabel(forKey: target)
            let wallet = await state.balance(username: target)
            let amount = wallet.map { String(format: "$%.4f", $0.balanceUsd) } ?? "—"
            let confirmText = """
            <b>🗑 Удалить кошелёк \(label)?</b>

            Остаток · <b>\(amount)</b>

            ⚠️ Остаток пропадёт вместе с историей списаний. Если человек пополнял баланс деньгами, это его деньги. Отменить нельзя.
            """
            let confirmMarkup = InlineKeyboardMarkup(inline_keyboard: [
                [menuButton("🗑 Да, удалить", action: "sbal:rmyes:\(target)")],
                [menuButton("❌ Отмена", action: "nav:superbal")],
            ])
            try await editOrAnswer(callback: callback, message: message, text: confirmText, markup: confirmMarkup)
        case "rmyes":
            guard parts.count >= 3 else { return }
            let removed = await state.removeBalance(username: parts[2])
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: removed ? "✓ Кошелёк удалён" : "Кошелёк не найден")
            try await showPage(.superBalances, chatKey: chatKey, callback: callback, message: message)
        default:
            try await showPage(.superBalances, chatKey: chatKey, callback: callback, message: message)
        }
    }
}
