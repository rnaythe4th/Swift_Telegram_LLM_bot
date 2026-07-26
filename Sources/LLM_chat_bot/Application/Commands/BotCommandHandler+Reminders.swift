import Foundation

// /reminders: renewal reminders, winback offers and wallet winback.

extension BotCommandHandler {
    // MARK: - Renewal reminders & winback (superadmin, roadmap step 8)

    func handleReminders(chatKey: ChatKey, argument: String, fromUser: TelegramUser?) async throws {
        let parts = argument.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        let subcommand = (parts.first ?? "").lowercased()
        let rest = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        var config = await state.reminderConfig()

        switch subcommand {
        case "":
            try await sendUserFeedback(chatKey: chatKey, text: await remindersStatusText(config: config))

        case "on", "off":
            config.enabled = subcommand == "on"
            await state.setReminderConfig(config)
            try await sendUserFeedback(chatKey: chatKey, text: config.enabled
                ? "✓ Напоминания и winback включены."
                : "✓ Напоминания и winback выключены.")

        case "chats":
            let value = rest.lowercased()
            guard value == "on" || value == "off" else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/reminders chats on|off</code>")
                return
            }
            config.notifyChats = value == "on"
            await state.setReminderConfig(config)
            try await sendUserFeedback(chatKey: chatKey, text: config.notifyChats
                ? "✓ Уведомления пойдут и в чаты спонсора (продлить сможет любой участник)."
                : "✓ Уведомления только в личку спонсора.")

        case "days":
            if rest == "-" || rest == "0" || rest.lowercased() == "off" {
                config.expiryReminderDays = []
                await state.setReminderConfig(config)
                try await sendUserFeedback(chatKey: chatKey, text: "✓ Напоминания до истечения выключены (winback остался).")
                return
            }
            let parsedDays = rest
                .split(whereSeparator: { ",; ".contains($0) })
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                .filter { SubscriptionReminderConfig.daysBeforeRange.contains($0) }
            guard !parsedDays.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/reminders days 3,1</code> — за сколько дней напомнить (до \(SubscriptionReminderConfig.maxExpiryWaves) волн, \(SubscriptionReminderConfig.daysBeforeRange.lowerBound)–\(SubscriptionReminderConfig.daysBeforeRange.upperBound) дн.) · <code>/reminders days off</code> — не напоминать")
                return
            }
            config.expiryReminderDays = parsedDays
            await state.setReminderConfig(config)
            let appliedDays = await state.reminderConfig().expiryReminderDays
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Напоминания: " + appliedDays.map { "за \($0) дн." }.joined(separator: ", "))

        case "winback":
            if rest == "-" || rest == "0" || rest.lowercased() == "off" {
                config.winbackDays = []
                await state.setReminderConfig(config)
                try await sendUserFeedback(chatKey: chatKey, text: "✓ Winback выключен.")
                return
            }
            let parsed = rest
                .split(whereSeparator: { ",; ".contains($0) })
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                .filter { SubscriptionReminderConfig.winbackDayRange.contains($0) }
            guard !parsed.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/reminders winback 1,7</code> · <code>/reminders winback off</code>")
                return
            }
            config.winbackDays = parsed
            await state.setReminderConfig(config)
            let applied = await state.reminderConfig().winbackDays
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Winback: " + applied.map { "+\($0)д" }.joined(separator: ", "))

        case "discount":
            guard let n = Int(rest), SubscriptionReminderConfig.discountRange.contains(n) else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/reminders discount \(SubscriptionReminderConfig.discountRange.lowerBound)-\(SubscriptionReminderConfig.discountRange.upperBound)</code>")
                return
            }
            config.winbackDiscountPercent = n
            await state.setReminderConfig(config)
            try await sendUserFeedback(chatKey: chatKey, text: n == 0
                ? "✓ Winback без скидки — только напоминание."
                : "✓ Скидка winback: <b>\(n)%</b> на подписку (Stars, крипта, карта).")

        case "hours":
            guard let n = Int(rest), SubscriptionReminderConfig.offerHoursRange.contains(n) else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/reminders hours \(SubscriptionReminderConfig.offerHoursRange.lowerBound)-\(SubscriptionReminderConfig.offerHoursRange.upperBound)</code>")
                return
            }
            config.winbackOfferHours = n
            await state.setReminderConfig(config)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Скидка действует <b>\(n) ч</b> после выдачи.")

        case "interval":
            guard let n = Int(rest), SubscriptionReminderConfig.sweepIntervalRange.contains(n) else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/reminders interval \(SubscriptionReminderConfig.sweepIntervalRange.lowerBound)-\(SubscriptionReminderConfig.sweepIntervalRange.upperBound)</code> (минуты)")
                return
            }
            config.sweepIntervalMinutes = n
            await state.setReminderConfig(config)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Проверка каждые <b>\(n) мин</b> (применится к следующему циклу).")

        case "wallet":
            guard let n = Int(rest), SubscriptionReminderConfig.walletWinbackRange.contains(n) else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/reminders wallet 7</code> — через сколько дней тишины написать тем, у кого закончился оплаченный баланс (\(SubscriptionReminderConfig.walletWinbackRange.lowerBound)–\(SubscriptionReminderConfig.walletWinbackRange.upperBound), 0 — не писать)")
                return
            }
            config.walletWinbackDays = n
            await state.setReminderConfig(config)
            try await sendUserFeedback(chatKey: chatKey, text: n == 0
                ? "✓ Возврат по балансу выключен."
                : "✓ Возврат по балансу — после <b>\(n) дн.</b> тишины. Пишем только тем, кто платил деньгами, и один раз до следующего пополнения.")

        case "run":
            guard let reminderService else {
                try await sendUserFeedback(chatKey: chatKey, text: "⚠️ Сервис напоминаний недоступен.")
                return
            }
            let result = await reminderService.sweep()
            try await sendUserFeedback(chatKey: chatKey, text: "🔄 Проверка выполнена · \(result.summaryLine)")

        case "test", "preview":
            guard let reminderService else {
                try await sendUserFeedback(chatKey: chatKey, text: "⚠️ Сервис напоминаний недоступен.")
                return
            }
            // Renders the real texts with real prices; nothing goes to sponsors.
            for preview in await reminderService.previewTexts(username: actorKey(fromUser)) {
                _ = try? await telegram.sendMessage(.init(
                    chatID: chatKey.chatID,
                    threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                    replyTo: nil,
                    text: "👁 <i>Предпросмотр (никому не отправлено)</i>\n\n" + preview.text,
                    replyMarkup: preview.markup
                ))
            }

        case "clear":
            let cleared = await state.clearAllWinbackDiscounts()
            try await sendUserFeedback(chatKey: chatKey, text: "🗑 Снято активных скидок: <b>\(cleared)</b>.")

        default:
            try await sendUserFeedback(chatKey: chatKey, text: """
                <b>⏳ Напоминания и winback</b>

                <code>/reminders</code> — статус и список подписок под наблюдением
                <code>/reminders on|off</code> — включить/выключить
                <code>/reminders days 3,1</code> — за сколько дней напомнить (<code>off</code> — не напоминать)
                <code>/reminders winback 1,7</code> — дни winback после истечения (<code>off</code> — выключить)
                <code>/reminders discount 30</code> — скидка winback, %
                <code>/reminders hours 48</code> — сколько действует скидка
                <code>/reminders interval 60</code> — как часто проверять, мин
                <code>/reminders wallet 7</code> — вернуть тех, у кого кончился оплаченный баланс (0 — не писать)
                <code>/reminders chats on|off</code> — уведомлять ли чаты спонсора
                <code>/reminders run</code> — проверить прямо сейчас
                <code>/reminders test</code> — предпросмотр текстов
                <code>/reminders clear</code> — снять все активные скидки

                Всё то же — в /menu → 🛡 Супер-админ → ⏳ Напоминания и winback.
                """)
        }
    }

    private func remindersStatusText(config: SubscriptionReminderConfig) async -> String {
        let stats = await state.subscriptionLifecycleStats()
        let sweep = await reminderService?.status()
        let dateFormatter = DateFormatter(); dateFormatter.dateFormat = "dd.MM.yyyy"
        let timeFormatter = DateFormatter(); timeFormatter.dateFormat = "dd.MM HH:mm"

        var lines = [
            "<b>⏳ Напоминания и winback</b>",
            "",
            "Статус · <b>\(config.enabled ? "включены" : "выключены")</b>",
            "До истечения · <b>\(config.expiryReminderDays.isEmpty ? "выкл" : config.expiryReminderDays.map { "за \($0) дн." }.joined(separator: ", "))</b>",
            "Winback · <b>\(config.winbackDays.isEmpty ? "выкл" : config.winbackDays.map { "+\($0)д" }.joined(separator: ", "))</b> · скидка <b>\(config.winbackDiscountPercent)%</b> на <b>\(config.winbackOfferHours) ч</b>",
            "Чаты спонсора · <b>\(config.notifyChats ? "уведомляем" : "нет")</b> · проверка каждые <b>\(config.sweepIntervalMinutes)</b> мин",
            "Возврат по балансу · <b>\(config.walletWinbackDays > 0 ? "после \(config.walletWinbackDays) дн. тишины" : "выкл")</b>",
        ]
        if let sweep, let last = sweep.last, let runAt = sweep.lastRunAt {
            lines.append("Последняя проверка · \(timeFormatter.string(from: runAt)) · \(last.summaryLine)")
        } else {
            lines.append("Последняя проверка · <i>ещё не было</i>")
        }
        lines.append("")
        lines.append("Спонсоров с подпиской · <b>\(stats.sponsors)</b> · без канала связи · <b>\(stats.unreachable)</b> · отписались · <b>\(stats.optedOut)</b>")
        if stats.expiringSoon.isEmpty {
            lines.append("⏳ Скоро истекают · <i>нет</i>")
        } else {
            lines.append("⏳ Скоро истекают:")
            for row in stats.expiringSoon.prefix(15) {
                lines.append("• \(row.label) — \(dateFormatter.string(from: row.paidUntil))" + (row.reachable ? "" : " · 🚫 нет канала") + (row.optedOut ? " · 🔕" : ""))
            }
        }
        if !stats.recentlyExpired.isEmpty {
            lines.append("⛔ Недавно истекли:")
            for row in stats.recentlyExpired.prefix(15) {
                lines.append("• \(row.label) — \(dateFormatter.string(from: row.paidUntil))" + (row.reachable ? "" : " · 🚫 нет канала") + (row.optedOut ? " · 🔕" : ""))
            }
        }
        if !stats.activeDiscounts.isEmpty {
            lines.append("🎁 Живые скидки:")
            for entry in stats.activeDiscounts.prefix(15) {
                lines.append("• \(entry.label) — −\(entry.discount.percent)% до \(timeFormatter.string(from: entry.discount.expiresAt))")
            }
        }
        lines.append("")
        lines.append("<i>Подсказка по подкомандам — /reminders help</i>")
        return lines.joined(separator: "\n")
    }
}
