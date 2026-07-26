import Foundation

// Renewal reminders, winback offers and wallet winback.

extension BotMenuHandler {
    // MARK: - Reminder / winback admin actions (roadmap step 8)

    func handleReminderAdminAction(
        parts: [String],
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard parts.count >= 2 else {
            try await showPage(.superReminders, chatKey: chatKey, callback: callback, message: message)
            return
        }
        var config = await state.reminderConfig()

        /// Asks for a value with the standard pending-input flow.
        func prompt(_ kind: AdminPendingInputKind, title: String, body: String) async throws {
            await state.setAdminPendingInput(.init(kind: kind, menuMessageID: message.message_id, payload: nil), chatKey: chatKey)
            let markup = InlineKeyboardMarkup(inline_keyboard: [[menuButton("❌ Отмена", action: "nav:superreminders")]])
            try await editOrAnswer(callback: callback, message: message, text: "<b>\(title)</b>\n\n\(body)", markup: markup)
        }

        switch parts[1] {
        case "toggle":
            config.enabled.toggle()
            await state.setReminderConfig(config)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: config.enabled ? "🟢 Включены" : "⚪️ Выключены")
            try await showPage(.superReminders, chatKey: chatKey, callback: callback, message: message)

        case "chats":
            config.notifyChats.toggle()
            await state.setReminderConfig(config)
            try? await telegram.answerCallback(
                callbackQueryID: callback.id,
                text: config.notifyChats ? "🟢 Чаты тоже получат" : "⚪️ Только личка спонсора"
            )
            try await showPage(.superReminders, chatKey: chatKey, callback: callback, message: message)

        case "days":
            try await prompt(
                .reminderDaysBefore,
                title: "⏳ За сколько дней напоминать",
                body: """
                Сейчас: <b>\(config.expiryReminderDays.isEmpty ? "выкл" : config.expiryReminderDays.map { "за \($0) дн." }.joined(separator: ", "))</b>

                Отправьте дни через запятую, например <code>3,1</code> — «за три дня» и «завтра» (до \(SubscriptionReminderConfig.maxExpiryWaves) волн, каждая \(SubscriptionReminderConfig.daysBeforeRange.lowerBound)–\(SubscriptionReminderConfig.daysBeforeRange.upperBound) дн.). <code>0</code> или <code>-</code> — не напоминать до истечения (winback останется).

                <i>Одно напоминание собирает тех, кто и так собирался продлить; второе, в последний день, — тех, кто собирался и забыл.</i>
                """
            )

        case "winback":
            try await prompt(
                .reminderWinbackDays,
                title: "🔁 Дни winback после истечения",
                body: """
                Сейчас: <b>\(config.winbackDays.isEmpty ? "выкл" : config.winbackDays.map { "+\($0)" }.joined(separator: ", "))</b>

                Отправьте дни через запятую, например <code>1,7</code> (до \(SubscriptionReminderConfig.maxWinbackWaves) волн, каждый день \(SubscriptionReminderConfig.winbackDayRange.lowerBound)–\(SubscriptionReminderConfig.winbackDayRange.upperBound)). <code>0</code> или <code>-</code> — выключить winback.
                """
            )

        case "discount":
            try await prompt(
                .reminderDiscount,
                title: "🎁 Скидка winback",
                body: """
                Сейчас: <b>\(config.winbackDiscountPercent)%</b>

                Отправьте число \(SubscriptionReminderConfig.discountRange.lowerBound)–\(SubscriptionReminderConfig.discountRange.upperBound) — процент скидки на подписку для вернувшихся. Действует на Stars, крипту и карту. <code>0</code> — без скидки, только напоминание.
                """
            )

        case "hours":
            try await prompt(
                .reminderOfferHours,
                title: "⌛ Срок действия скидки",
                body: """
                Сейчас: <b>\(config.winbackOfferHours) ч</b>

                Отправьте число часов \(SubscriptionReminderConfig.offerHoursRange.lowerBound)–\(SubscriptionReminderConfig.offerHoursRange.upperBound). Дедлайн виден пользователю — он и создаёт срочность.
                """
            )

        case "interval":
            try await prompt(
                .reminderInterval,
                title: "🔄 Интервал проверки",
                body: """
                Сейчас: <b>\(config.sweepIntervalMinutes) мин</b>

                Отправьте число минут \(SubscriptionReminderConfig.sweepIntervalRange.lowerBound)–\(SubscriptionReminderConfig.sweepIntervalRange.upperBound) — как часто бот сверяет подписки. Реже = меньше нагрузки, точность в пределах интервала.
                """
            )

        case "wallet":
            try await prompt(
                .reminderWalletDays,
                title: "💰 Возврат по балансу",
                body: """
                Сейчас: <b>\(config.walletWinbackDays > 0 ? "после \(config.walletWinbackDays) дн. тишины" : "выключен")</b>

                Отправьте число дней \(SubscriptionReminderConfig.walletWinbackRange.lowerBound)–\(SubscriptionReminderConfig.walletWinbackRange.upperBound). <code>0</code> — не писать.

                <i>Подписка истекает громко и получает winback; баланс просто заканчивается, и человек тихо уходит. Письмо получают только те, кто реально платил деньгами, у кого баланс на нуле и нет активной подписки — и ровно один раз до следующего пополнения.</i>
                """
            )

        case "run":
            guard let reminderService else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Сервис недоступен")
                return
            }
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔄 Проверяю…")
            let result = await reminderService.sweep()
            try await showPage(.superReminders, chatKey: chatKey, callback: callback, message: message)
            _ = try? await telegram.sendMessage(.init(
                chatID: chatKey.chatID,
                threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                replyTo: nil,
                text: "🔄 Проверка выполнена · \(result.summaryLine)",
                replyMarkup: nil
            ))

        case "preview":
            guard let reminderService else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Сервис недоступен")
                return
            }
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: nil)
            // Renders the real texts with real prices; sends nothing to sponsors.
            for preview in await reminderService.previewTexts(username: invokerKey(callback)) {
                _ = try? await telegram.sendMessage(.init(
                    chatID: chatKey.chatID,
                    threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                    replyTo: nil,
                    text: "👁 <i>Предпросмотр (никому не отправлено)</i>\n\n" + preview.text,
                    replyMarkup: preview.markup
                ))
            }

        case "cleardiscounts":
            let cleared = await state.clearAllWinbackDiscounts()
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🗑 Снято скидок: \(cleared)")
            try await showPage(.superReminders, chatKey: chatKey, callback: callback, message: message)

        default:
            try await showPage(.superReminders, chatKey: chatKey, callback: callback, message: message)
        }
    }

    // MARK: - Onboarding examples (roadmap step 9)

    /// Renewal reminders & winback (roadmap step 8): the whole schedule is
    /// editable here, plus the monitoring the super-admin needs to trust it —
    /// who is about to lapse, who just did, live offers, last sweep result.
    func renderSuperReminders(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let config = await state.reminderConfig()
        let stats = await state.subscriptionLifecycleStats()
        let sweep = await reminderService?.status()

        let dateFormatter = DateFormatter(); dateFormatter.dateFormat = "dd.MM.yyyy"
        let timeFormatter = DateFormatter(); timeFormatter.dateFormat = "dd.MM HH:mm"

        let winbackLabel = config.winbackDays.isEmpty
            ? "выкл"
            : config.winbackDays.map { "+\($0)д" }.joined(separator: ", ")
        let expiryLabel = config.expiryReminderDays.isEmpty
            ? "выкл"
            : config.expiryReminderDays.map { "\($0)д" }.joined(separator: ", ")

        var rows: [[InlineKeyboardButton]] = [
            [menuButton(config.enabled ? "🟢 Напоминания включены" : "⚪️ Напоминания выключены", action: "rem:toggle")],
            [menuButton("✏️ До конца · \(expiryLabel)", action: "rem:days"),
             menuButton("✏️ Winback · \(winbackLabel)", action: "rem:winback")],
            [menuButton("✏️ Скидка · \(config.winbackDiscountPercent)%", action: "rem:discount"),
             menuButton("✏️ Срок скидки · \(config.winbackOfferHours) ч", action: "rem:hours")],
            [menuButton("✏️ Проверка каждые \(config.sweepIntervalMinutes) мин", action: "rem:interval")],
            [menuButton("💰 Возврат по балансу · \(config.walletWinbackDays > 0 ? "\(config.walletWinbackDays) дн." : "выкл")", action: "rem:wallet")],
            [menuButton(config.notifyChats ? "🟢 Уведомлять чаты спонсора" : "⚪️ Только личка спонсора", action: "rem:chats")],
            [menuButton("🔄 Проверить сейчас", action: "rem:run"),
             menuButton("👁 Предпросмотр", action: "rem:preview")],
            [menuButton("← К супер-админу", action: "nav:superadmin")],
        ]
        if !stats.activeDiscounts.isEmpty {
            rows.insert([menuButton("🗑 Снять все скидки · \(stats.activeDiscounts.count)", action: "rem:cleardiscounts")], at: rows.count - 1)
        }

        let sweepLine: String
        if let sweep, let last = sweep.last, let runAt = sweep.lastRunAt {
            sweepLine = "🕒 Последняя проверка · \(timeFormatter.string(from: runAt)) · \(last.summaryLine)"
        } else {
            sweepLine = "🕒 Проверок ещё не было (первая — через минуту после старта)"
        }

        var lines: [String] = [
            "<b>⏳ Напоминания и winback</b>",
            "",
            "Статус · <b>\(config.enabled ? "включены" : "выключены")</b>",
            "Напоминания о продлении · <b>\(config.expiryReminderDays.isEmpty ? "выключены" : config.expiryReminderDays.map { "за \($0) дн." }.joined(separator: ", "))</b>",
            "Winback после истечения · <b>\(winbackLabel)</b> · скидка <b>\(config.winbackDiscountPercent)%</b> на <b>\(config.winbackOfferHours) ч</b>",
            "Уведомлять чаты спонсора · <b>\(config.notifyChats ? "да" : "нет")</b>",
            "Проверка · каждые <b>\(config.sweepIntervalMinutes)</b> мин",
            sweepLine,
            "",
            "<b>Подписки под наблюдением</b>",
            "Спонсоров с подпиской · <b>\(stats.sponsors)</b> · без канала связи · <b>\(stats.unreachable)</b> · отписались · <b>\(stats.optedOut)</b>",
        ]

        let wallets = await state.lapsedWalletStats()
        lines.append(
            config.walletWinbackDays > 0
                ? "💰 Возврат по балансу · после <b>\(config.walletWinbackDays) дн.</b> тишины · платили <b>\(wallets.payers)</b> · готовы к отправке <b>\(wallets.due)</b> · уже написали <b>\(wallets.notified)</b>"
                : "💰 Возврат по балансу · <b>выключен</b> · платили деньгами · <b>\(wallets.payers)</b>"
        )

        if stats.expiringSoon.isEmpty {
            lines.append("⏳ Скоро истекают · <i>нет</i>")
        } else {
            lines.append("⏳ Скоро истекают · <b>\(stats.expiringSoon.count)</b>")
            for row in stats.expiringSoon.prefix(10) {
                let flags = (row.reachable ? "" : " · 🚫 нет канала") + (row.optedOut ? " · 🔕" : "")
                lines.append("• \(row.label) — \(dateFormatter.string(from: row.paidUntil))\(flags)")
            }
        }

        if !stats.recentlyExpired.isEmpty {
            lines.append("⛔ Недавно истекли · <b>\(stats.recentlyExpired.count)</b>")
            for row in stats.recentlyExpired.prefix(10) {
                let flags = (row.reachable ? "" : " · 🚫 нет канала") + (row.optedOut ? " · 🔕" : "")
                lines.append("• \(row.label) — \(dateFormatter.string(from: row.paidUntil))\(flags)")
            }
        }

        if !stats.activeDiscounts.isEmpty {
            lines.append("🎁 Живые скидки · <b>\(stats.activeDiscounts.count)</b>")
            for entry in stats.activeDiscounts.prefix(10) {
                lines.append("• \(entry.label) — −\(entry.discount.percent)% до \(timeFormatter.string(from: entry.discount.expiresAt))")
            }
        }

        lines.append("")
        lines.append("<i>Каждое напоминание уходит один раз за срок подписки: продление обнуляет отметки. Спонсор может отключить их у себя в «⚡ Мой премиум». Счётчики — на странице «📊 Воронка» и в /metrics.</i>")

        return (lines.joined(separator: "\n"), InlineKeyboardMarkup(inline_keyboard: rows))
    }
}
