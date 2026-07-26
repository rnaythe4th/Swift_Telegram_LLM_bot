import Foundation

// Growth analytics: funnel by period, self-promo and paid-traffic sources.

extension BotMenuHandler {
    /// Growth & retention: funnel, self-promo, reminders, onboarding, referral, traffic.
    func processGrowthAction(
        command: String,
        parts: [String],
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        switch command {
        case "funnel":
            // Period switcher on the analytics page (roadmap step 7).
            guard await state.isSuperAdmin(username: invokerKey(callback)) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
                return
            }
            guard parts.count >= 3, parts[1] == "p" else { return }
            let period = FunnelPeriod(rawValue: parts[2]) ?? .week
            let (funnelText, funnelMarkup) = await renderSuperFunnel(chatKey: chatKey, period: period)
            try await editOrAnswer(callback: callback, message: message, text: funnelText, markup: funnelMarkup)
            return

        case "promo":
            // Built-in self-promo that fills the free ad slot (roadmap step 5).
            guard await state.isSuperAdmin(username: invokerKey(callback)) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
                return
            }
            guard parts.count >= 2 else { return }
            switch parts[1] {
            case "toggle":
                var promo = await state.selfPromoConfig()
                promo.enabled.toggle()
                await state.setSelfPromoConfig(promo)
                try? await telegram.answerCallback(
                    callbackQueryID: callback.id,
                    text: promo.enabled ? "▶️ Само-реклама включена" : "⏸ Само-реклама выключена"
                )
                try await showPage(.superAds, chatKey: chatKey, callback: callback, message: message)
            case "text":
                await state.setAdminPendingInput(.init(kind: .selfPromoText, menuMessageID: message.message_id, payload: nil), chatKey: chatKey)
                let current = await state.selfPromoConfig()
                let prompt = """
                <b>📣 Текст само-рекламы</b>

                Показывается в бесплатных чатах, когда нет ни одной активной кампании. Под текстом бот сам добавляет кнопку «⚡ Открыть премиум».

                Сейчас:
                <blockquote expandable>\(current.text)</blockquote>

                Отправьте новый текст одним сообщением (HTML разрешён, до \(SelfPromoConfig.maxTextLength) символов). Счётчик показов сохранится.
                """
                let markup = InlineKeyboardMarkup(inline_keyboard: [[menuButton("❌ Отмена", action: "nav:superads")]])
                try await editOrAnswer(callback: callback, message: message, text: prompt, markup: markup)
            case "every":
                await state.setAdminPendingInput(.init(kind: .selfPromoEvery, menuMessageID: message.message_id, payload: nil), chatKey: chatKey)
                let current = await state.selfPromoConfig()
                let prompt = """
                <b>📣 Частота само-рекламы</b>

                Сейчас: раз в <b>\(current.everyNReplies)</b> ответов бота в чате.

                Отправьте число от <code>\(SelfPromoConfig.repliesRange.lowerBound)</code> до <code>\(SelfPromoConfig.repliesRange.upperBound)</code>. Пауза между показами настраивается отдельно и действует одновременно с частотой.
                """
                let markup = InlineKeyboardMarkup(inline_keyboard: [[menuButton("❌ Отмена", action: "nav:superads")]])
                try await editOrAnswer(callback: callback, message: message, text: prompt, markup: markup)
            case "pause":
                await state.setAdminPendingInput(.init(kind: .selfPromoPause, menuMessageID: message.message_id, payload: nil), chatKey: chatKey)
                let current = await state.selfPromoConfig()
                let prompt = """
                <b>📣 Пауза между показами</b>

                Сейчас: <b>\(current.minIntervalSeconds / 60)</b> мин минимум между само-рекламой в одном чате.

                Отправьте число минут от <code>0</code> до <code>\(SelfPromoConfig.pauseMinutesRange.upperBound)</code>.
                """
                let markup = InlineKeyboardMarkup(inline_keyboard: [[menuButton("❌ Отмена", action: "nav:superads")]])
                try await editOrAnswer(callback: callback, message: message, text: prompt, markup: markup)
            case "reset":
                await state.resetSelfPromoStats()
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🗑 Счётчик показов обнулён")
                try await showPage(.superAds, chatKey: chatKey, callback: callback, message: message)
            case "default":
                var promo = await state.selfPromoConfig()
                promo.text = SelfPromoConfig.defaultText
                await state.setSelfPromoConfig(promo)
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "↺ Текст по умолчанию")
                try await showPage(.superAds, chatKey: chatKey, callback: callback, message: message)
            default:
                try await showPage(.superAds, chatKey: chatKey, callback: callback, message: message)
            }
            return

        case "rem":
            guard await state.isSuperAdmin(username: invokerKey(callback)) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
                return
            }
            try await handleReminderAdminAction(parts: parts, chatKey: chatKey, callback: callback, message: message)
            return

        case "examples":
            // Open to everyone: posts the example buttons as a fresh message so
            // the settings menu stays where it is (roadmap step 9).
            let onboarding = await state.onboardingConfig()
            let exampleRows = OnboardingPresenter.exampleRows(onboarding, inGroup: chatKey.chatID < 0)
            guard !exampleRows.isEmpty else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Примеров сейчас нет")
                return
            }
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: nil)
            _ = try? await telegram.sendMessage(.init(
                chatID: chatKey.chatID,
                threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                replyTo: nil,
                text: OnboardingPresenter.invitation,
                replyMarkup: InlineKeyboardMarkup(inline_keyboard: exampleRows)
            ))
            await state.bumpFunnel(.onboardingShown)
            return

        case "onb":
            guard await state.isSuperAdmin(username: invokerKey(callback)) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
                return
            }
            try await handleOnboardingAdminAction(parts: parts, chatKey: chatKey, callback: callback, message: message)
            return

        case "sref":
            guard await state.isSuperAdmin(username: invokerKey(callback)) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
                return
            }
            try await handleReferralAdminAction(parts: parts, chatKey: chatKey, callback: callback, message: message)
            return

        case "strf":
            guard await state.isSuperAdmin(username: invokerKey(callback)) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
                return
            }
            try await handleTrafficAdminAction(parts: parts, chatKey: chatKey, callback: callback, message: message)
            return

        default:
            break
        }
    }

    /// Conversion-funnel analytics page (roadmap step 7): every stage over a
    /// selectable period (all-time totals in grey next to it), step-to-step
    /// conversion, where the purchase opens come from, retention and sponsor
    /// tallies. A total alone says how big something is; only the window says
    /// whether it is getting better — which is what the numbers are for.
    func renderSuperFunnel(
        chatKey: ChatKey,
        period: FunnelPeriod = .week
    ) async -> (String, InlineKeyboardMarkup) {
        let report = await state.funnelReport()
        func n(_ e: FunnelEvent) -> Int { report.count(e, in: period) }
        func total(_ e: FunnelEvent) -> Int { report.count(e) }
        func pct(_ num: Int, _ den: Int) -> String {
            guard den > 0 else { return "—" }
            return String(format: "%.0f%%", Double(num) / Double(den) * 100)
        }
        /// "42 · всего 1203" — the period number leads, the lifetime total
        /// stays visible so a quiet week doesn't read as an empty product.
        func value(_ e: FunnelEvent) -> String {
            period == .all ? "<b>\(total(e))</b>" : "<b>\(n(e))</b> <i>· всего \(total(e))</i>"
        }

        let start = n(.start)
        let firstMsg = n(.firstMessage)
        let openPurchase = n(.openPurchase)
        let invoiceSent = n(.invoiceSent)
        let paid = n(.paid)
        let converted = paid + n(.creditTopup)

        // The timestamp is also what keeps a repeated tap on the active period
        // (or on «Обновить») from failing as "message is not modified" and
        // posting the whole page again as a new message.
        let clock = DateFormatter(); clock.dateFormat = "dd.MM HH:mm:ss"
        var lines: [String] = [
            "<b>📊 Воронка конверсии</b> · \(period.label)",
            "<i>данные на \(clock.string(from: Date()))</i>",
            "",
            "1️⃣ Старт (/start) · \(value(.start))",
            "➕ Добавлен в группы · \(value(.addedToGroup)) · вирусный рост",
            "💡 Примеры показаны · \(value(.onboardingShown)) · тапов \(value(.exampleTapped)) · вовлечение \(pct(n(.exampleTapped), n(.onboardingShown)))",
            "2️⃣ Первое сообщение · \(value(.firstMessage)) · активация \(pct(firstMsg, start))",
            "3️⃣ Упёрлись в лимит · \(value(.capHit)) · предупреждений \(value(.capWarned))",
            "📣 Само-реклама показана · \(value(.promoShown)) · 💸 баланс закончился · \(value(.balanceEmpty))",
            "4️⃣ Открыли покупку · \(value(.openPurchase))",
            "5️⃣ Счёт выставлен · \(value(.invoiceSent)) · из открывших \(pct(invoiceSent, openPurchase))",
            "6️⃣ Оплатили · \(value(.paid)) · из счетов \(pct(paid, invoiceSent))",
            "",
            "🔄 Продлений · \(value(.renewed)) · renewal \(pct(n(.renewed), paid))",
            "💰 Пополнений баланса · \(value(.creditTopup))",
            "",
            "🎯 Конверсия в оплату (от активации) · <b>\(pct(converted, firstMsg))</b>",
        ]

        // Which surface actually sells: the pain-point upsells (лимит,
        // само-реклама, пустой баланс) against the plain menu button.
        let sources = PurchaseSource.allCases
            .map { ($0, report.count(source: $0, in: period)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
        if !sources.isEmpty {
            lines.append("")
            lines.append("<b>Откуда открывают покупку</b>")
            for (source, count) in sources {
                lines.append("· \(source.label) · <b>\(count)</b> · \(pct(count, openPurchase))")
            }
        }

        let retention = report.retention
        lines.append(contentsOf: [
            "",
            "<b>Возвращаемость</b> <i>(по всем, кого бот видел)</i>",
            "🔁 Вернулись через сутки+ · <b>\(retention.returnedD1)</b> из \(retention.cohortD1) · \(retention.d1Label)",
            "🔁 Активны через неделю+ · <b>\(retention.returnedD7)</b> из \(retention.cohortD7) · \(retention.d7Label)",
            "",
            "<b>Спонсоры (по подпискам)</b>",
            "✅ Активных · <b>\(report.sponsorsActive)</b> · ⛔ истёкших (отток) · <b>\(report.sponsorsExpired)</b>"
                + (report.sponsorsUnlimited > 0 ? " · ♾ <b>\(report.sponsorsUnlimited)</b>" : ""),
            "⏳ Скоро истекают · <b>\(report.sponsorsExpiringSoon)</b> · 🎁 живых winback-скидок · <b>\(report.winbackOffersActive)</b>",
            "",
            "<b>Удержание и возврат</b>",
            "🔔 Напоминаний отправлено · \(value(.expiryReminder))",
            "🔁 Winback-офферов · \(value(.winbackSent)) · вернулись · \(value(.winbackRedeemed)) · возврат \(pct(n(.winbackRedeemed), n(.winbackSent)))",
            "",
            "<i>Счётчики событий (не уникальные юзеры), переживают рестарт; по дням хранятся \(FunnelDailyLog.windowDays) суток. Возвращаемость — «видели ли человека спустя сутки/неделю после первой встречи», не когортный D1/D7. Те же числа — в /metrics.</i>",
        ])

        // Period switcher: the active one is marked, so the buttons double as
        // the "what am I looking at" indicator.
        let periodRow = FunnelPeriod.allCases.map { option in
            menuButton(
                (option == period ? "· " : "") + option.buttonLabel + (option == period ? " ·" : ""),
                action: "funnel:p:\(option.rawValue)"
            )
        }
        let rows: [[InlineKeyboardButton]] = [
            Array(periodRow.prefix(2)),
            Array(periodRow.suffix(from: 2)),
            [menuButton("🔄 Обновить", action: "funnel:p:\(period.rawValue)")],
            [menuButton("⏳ Напоминания и winback", action: "nav:superreminders")],
            [menuButton("💡 Примеры-запросы", action: "nav:superonboarding"),
             menuButton("📣 Реклама", action: "nav:superads")],
            [menuButton("📈 Источники трафика", action: "nav:supersrc")],
            // Every other super* page goes back to the super menu; "← Назад"
            // here used to drop the reader into the chat settings instead.
            [menuButton("← К супер-админу", action: "nav:superadmin"),
             menuButton("✕ Закрыть", action: "close")],
        ]
        return (lines.joined(separator: "\n"), InlineKeyboardMarkup(inline_keyboard: rows))
    }

    // MARK: - Paid-traffic sources (`src_` deep links)

    /// Where the ad money went. Reading this page is the whole point of the
    /// `src_` links: spend ÷ payers is CAC, and without a per-campaign number
    /// the budget goes to whichever channel *felt* like it worked.
    func renderSuperTraffic(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let overview = await state.trafficSourceOverview()

        var rows: [[InlineKeyboardButton]] = []
        if overview.campaigns > 0 {
            rows.append([menuButton("🗑 Очистить статистику источников", action: "strf:clear")])
        }
        rows.append([menuButton("📊 Воронка", action: "nav:superfunnel"),
                     menuButton("← К супер-админу", action: "nav:superadmin")])

        var lines: [String] = ["<b>📈 Источники трафика (реклама)</b>", ""]

        if overview.campaigns == 0 {
            lines.append("Пока ни одного перехода по рекламной ссылке.")
        } else {
            lines.append("Кампаний · <b>\(overview.campaigns)</b> · пришло <b>\(overview.joined)</b> · написали <b>\(overview.activated)</b> · оплатили <b>\(overview.payers)</b>")
            lines.append("Всего оплат · <b>\(overview.payments)</b> <i>(с повторными)</i>")
            lines.append("")
            lines.append("<b>Кампании</b> <i>(пришло → написали → оплатили)</i>")
            // Up to `TrafficSourceLedger.maxTags` campaigns can exist; the page
            // must stay inside one Telegram message, so show the top slice.
            let listLimit = 25
            for (index, row) in overview.rows.prefix(listLimit).enumerated() {
                lines.append(String(
                    format: "%d. <code>%@</code> · %d → %d → <b>%d</b> · конверсия %.1f%%",
                    index + 1, row.tag, row.tally.joined, row.tally.activated,
                    row.tally.payers, row.tally.conversionPercent
                ))
            }
            if overview.rows.count > listLimit {
                lines.append("<i>…и ещё \(overview.rows.count - listLimit) кампаний с меньшим числом оплативших</i>")
            }
        }

        // Opens that produced no attribution: without them "рекламу никто не
        // видит" is indistinguishable from "видят, но это уже наши люди".
        if overview.repeatOpens > 0 || overview.knownUserOpens > 0 {
            lines.append("")
            lines.append("<b>Переходы без засчёта</b> из \(overview.opens) всего")
            if overview.repeatOpens > 0 { lines.append("• уже пришли раньше по рекламе · \(overview.repeatOpens)") }
            if overview.knownUserOpens > 0 { lines.append("• уже пользовались ботом · \(overview.knownUserOpens)") }
        }

        lines.append("")
        if botUsername.isEmpty {
            lines.append("Ссылка для рекламы: <code>?start=src_метка</code>")
        } else {
            lines.append("<b>Как поставить метку.</b> В каждое объявление ставьте свою ссылку:")
            // Latin on purpose: `sanitize` drops everything outside [a-z0-9_-],
            // so a Cyrillic example would teach a tag that silently vanishes.
            lines.append("<code>\(TrafficSourceLink.url(botUsername: botUsername, tag: "ai_channel"))</code>")
        }
        lines.append("""
            <i>Метка — латиница, цифры, «_» и «-», до \(TrafficSourceLink.maxTagLength) символов. Своя метка на каждый канал: тогда «потратил ÷ оплатили» и есть цена клиента (CAC) этого канала. Засчитывается первый переход человека — канал не может присвоить клиента, которого привёл другой; те, кто уже пользовался ботом, в «пришло» не попадают.</i>
            """)

        return (lines.joined(separator: "\n"), InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func handleTrafficAdminAction(
        parts: [String],
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        switch parts.count >= 2 ? parts[1] : "" {
        case "clear":
            let overview = await state.trafficSourceOverview()
            let text = """
                <b>🗑 Очистить статистику источников?</b>

                Будет удалено кампаний · <b>\(overview.campaigns)</b> · переходов <b>\(overview.joined)</b> · оплативших <b>\(overview.payers)</b>.

                ⚠️ Цифры уже закупленной рекламы восстановить будет нельзя. Счётчики воронки и деньги пользователей не меняются.
                """
            let markup = InlineKeyboardMarkup(inline_keyboard: [
                [menuButton("🗑 Да, очистить", action: "strf:clearyes")],
                [menuButton("❌ Отмена", action: "nav:supersrc")],
            ])
            try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)

        case "clearyes":
            await state.clearTrafficSources()
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🗑 Статистика источников очищена")
            try await showPage(.superTraffic, chatKey: chatKey, callback: callback, message: message)

        default:
            try await showPage(.superTraffic, chatKey: chatKey, callback: callback, message: message)
        }
    }

    /// `ads:*` — paid campaigns (the self-promo knobs sit under `promo:*`).
    func handleAdCampaignAction(
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
            await state.setAdminPendingInput(.init(kind: .adAddText, menuMessageID: message.message_id, payload: nil), chatKey: chatKey)
            let prompt = """
            <b>📣 Новое объявление</b>

            Отправьте текст объявления одним сообщением (HTML разрешён).
            Частота по умолчанию: каждые 10 ответов, пауза 60 минут. Настроить точнее — /ads.
            """
            let markup = InlineKeyboardMarkup(inline_keyboard: [[menuButton("❌ Отмена", action: "nav:superads")]])
            try await editOrAnswer(callback: callback, message: message, text: prompt, markup: markup)
        case "toggle":
            guard parts.count >= 3 else { return }
            let id = parts[2]
            let enabled = await state.adCampaign(id: id)?.enabled ?? false
            _ = await state.setAdCampaignEnabled(id: id, enabled: !enabled)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: enabled ? "⏸ Выключена" : "▶️ Включена")
            try await showPage(.superAds, chatKey: chatKey, callback: callback, message: message)
        case "rm":
            guard parts.count >= 3 else { return }
            _ = await state.removeAdCampaign(id: parts[2])
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🗑 Удалена")
            try await showPage(.superAds, chatKey: chatKey, callback: callback, message: message)
        default:
            try await showPage(.superAds, chatKey: chatKey, callback: callback, message: message)
        }
    }

    func renderSuperAds(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let campaigns = await state.adCampaigns()

        var lines = ["<b>📣 Реклама</b> (\(campaigns.count))", ""]
        if campaigns.isEmpty {
            lines.append("<i>Кампаний нет. Реклама показывается в чатах без активной платной лицензии — после ответа бота, с настраиваемой частотой и лимитом показов.</i>")
        } else {
            for c in campaigns {
                let status = c.enabled ? (c.isRunning() ? "🟢" : "🟡 (вне окна/лимита)") : "⚪ выкл"
                var line = "\(status) <b>\(c.id)</b> · каждые \(c.everyNReplies) отв. · пауза \(c.minIntervalSeconds / 60) мин"
                if let target = c.totalImpressionsTarget {
                    line += " · \(c.impressionsUsed)/\(target)"
                } else {
                    line += " · показов \(c.impressionsUsed)"
                }
                lines.append(line)
                let preview = c.text.count > 100 ? String(c.text.prefix(100)) + "…" : c.text
                lines.append("<blockquote expandable>\(preview)</blockquote>")
            }
        }
        // The built-in self-promo is a real ad slot occupant, so it gets the
        // same controls and the same visible numbers as a paid campaign —
        // otherwise the super-admin is looking at a page that lies by omission.
        let promo = await state.selfPromoConfig()
        let anyRunning = campaigns.contains { $0.isRunning() }
        let promoState: String
        if !promo.enabled {
            promoState = "⚪ выключена — свободный слот просто не используется"
        } else if anyRunning {
            promoState = "🟡 ждёт — сейчас слот занят платной кампанией"
        } else {
            promoState = "🟢 показывается — активных кампаний нет"
        }
        lines.append("")
        lines.append("<b>📣 Само-реклама премиума</b> (роадмап 5)")
        lines.append(promoState)
        lines.append("Частота · раз в <b>\(promo.everyNReplies)</b> ответов · пауза <b>\(promo.minIntervalSeconds / 60)</b> мин · показов <b>\(promo.impressions)</b>")
        lines.append("<blockquote expandable>\(promo.text)</blockquote>")
        lines.append("<i>Под текстом бот сам добавляет кнопку «⚡ Открыть премиум» (в личке — ещё и приглашение друга). Тапы по ней видно в «📊 Воронка» → «Откуда открывают покупку».</i>")
        lines.append("")
        lines.append("<i>Тонкая настройка кампаний — команда /ads (частота, лимиты с пейсингом, кнопка-ссылка). Проверить показ: /simulate user и написать боту.</i>")

        var rows: [[InlineKeyboardButton]] = [[menuButton("➕ Новое объявление", action: "ads:add")]]
        for c in campaigns.prefix(15) {
            rows.append([
                menuButton("\(c.enabled ? "⏸" : "▶️") \(c.id)", action: "ads:toggle:\(c.id)"),
                menuButton("🗑 \(c.id)", action: "ads:rm:\(c.id)"),
            ])
        }
        rows.append([menuButton(promo.enabled ? "🟢 Само-реклама включена" : "⚪️ Само-реклама выключена", action: "promo:toggle")])
        rows.append([
            menuButton("✏️ Текст", action: "promo:text"),
            menuButton("✏️ Раз в \(promo.everyNReplies) отв.", action: "promo:every"),
        ])
        rows.append([
            menuButton("✏️ Пауза · \(promo.minIntervalSeconds / 60) мин", action: "promo:pause"),
            menuButton("↺ Текст по умолчанию", action: "promo:default"),
        ])
        if promo.impressions > 0 {
            rows.append([menuButton("🗑 Обнулить показы · \(promo.impressions)", action: "promo:reset")])
        }
        rows.append([menuButton("📊 Воронка", action: "nav:superfunnel"),
                     menuButton("← К супер-админу", action: "nav:superadmin")])
        return (lines.joined(separator: "\n"), InlineKeyboardMarkup(inline_keyboard: rows))
    }
}
