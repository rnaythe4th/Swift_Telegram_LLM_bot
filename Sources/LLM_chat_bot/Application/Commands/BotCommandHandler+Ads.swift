import Foundation

// /ads: campaigns and the built-in self-promo.

extension BotCommandHandler {
    // MARK: - Ads (superadmin)

    private static let adsDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy"
        return f
    }()

    private func adSummaryLines(_ c: AdCampaign) -> [String] {
        var lines: [String] = []
        let status = c.enabled ? (c.isRunning() ? "🟢" : "🟡") : "⚪"
        var limits = "каждые \(c.everyNReplies) отв. · пауза \(c.minIntervalSeconds / 60) мин"
        if let target = c.totalImpressionsTarget {
            limits += " · показы \(c.impressionsUsed)/\(target)"
        } else {
            limits += " · показов \(c.impressionsUsed)"
        }
        if let endAt = c.endAt {
            limits += " · до \(Self.adsDateFormatter.string(from: endAt))"
        }
        lines.append("\(status) <b>\(c.id)</b> · \(limits)")
        let preview = c.text.count > 120 ? String(c.text.prefix(120)) + "…" : c.text
        lines.append("<blockquote expandable>\(preview)</blockquote>")
        if let bt = c.buttonText, let url = c.buttonURL {
            lines.append("🔗 [\(bt)] → \(url)")
        }
        return lines
    }

    func handleAds(chatKey: ChatKey, argument: String) async throws {
        let parts = argument.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        let subcommand = (parts.first ?? "").lowercased()
        let rest = parts.count > 1 ? parts[1] : ""

        switch subcommand {
        case "add":
            let text = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/ads add &lt;текст объявления&gt;</code> (HTML разрешён)")
                return
            }
            let campaign = AdCampaign.new(text: text)
            await state.upsertAdCampaign(campaign)
            try await sendUserFeedback(chatKey: chatKey, text: """
                ✓ Кампания <b>\(campaign.id)</b> создана и включена.
                По умолчанию: каждые 10 ответов, пауза 60 мин, без лимита показов.

                Настроить:
                <code>/ads freq \(campaign.id) 10 60</code> — каждые N ответов, пауза в минутах
                <code>/ads limit \(campaign.id) 1000 30</code> — 1000 показов, размазанных на 30 дней
                <code>/ads button \(campaign.id) Открыть | https://example.com</code>
                """)

        case "remove", "rm":
            let id = rest.trimmingCharacters(in: .whitespaces)
            let removed = await state.removeAdCampaign(id: id)
            try await sendUserFeedback(chatKey: chatKey, text: removed ? "✓ Кампания \(id) удалена." : "Кампания \(id) не найдена.")

        case "on", "off":
            let id = rest.trimmingCharacters(in: .whitespaces)
            let ok = await state.setAdCampaignEnabled(id: id, enabled: subcommand == "on")
            try await sendUserFeedback(chatKey: chatKey, text: ok
                ? "✓ Кампания \(id) · \(subcommand == "on" ? "включена" : "выключена")."
                : "Кампания \(id) не найдена.")

        case "freq":
            let args = rest.split(separator: " ").map(String.init)
            guard args.count >= 2, let everyN = Int(args[1]), everyN >= 1,
                  var campaign = await state.adCampaign(id: args[0]) else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/ads freq &lt;id&gt; &lt;каждые_N_ответов&gt; [пауза_минут]</code>")
                return
            }
            campaign.everyNReplies = everyN
            if args.count >= 3, let minutes = Int(args[2]), minutes >= 0 {
                campaign.minIntervalSeconds = minutes * 60
            }
            await state.upsertAdCampaign(campaign)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ \(campaign.id): каждые <b>\(campaign.everyNReplies)</b> ответов · пауза <b>\(campaign.minIntervalSeconds / 60) мин</b>.")

        case "limit":
            let args = rest.split(separator: " ").map(String.init)
            guard let id = args.first, var campaign = await state.adCampaign(id: id) else {
                try await sendUserFeedback(chatKey: chatKey, text: """
                    <i>Использование:</i>
                    <code>/ads limit &lt;id&gt; &lt;показов&gt; [дней]</code> — лимит, равномерно на период
                    <code>/ads limit &lt;id&gt; off</code> — снять лимит
                    """)
                return
            }
            if args.count >= 2, args[1].lowercased() == "off" {
                campaign.totalImpressionsTarget = nil
                campaign.endAt = nil
                await state.upsertAdCampaign(campaign)
                try await sendUserFeedback(chatKey: chatKey, text: "✓ \(campaign.id): лимит показов снят.")
                return
            }
            guard args.count >= 2, let target = Int(args[1]), target > 0 else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/ads limit &lt;id&gt; &lt;показов&gt; [дней]</code>")
                return
            }
            campaign.totalImpressionsTarget = target
            campaign.startAt = Date()
            campaign.impressionsUsed = 0
            if args.count >= 3, let days = Int(args[2]), days > 0 {
                campaign.endAt = Date().addingTimeInterval(TimeInterval(days) * 86_400)
            } else {
                campaign.endAt = nil
            }
            await state.upsertAdCampaign(campaign)
            let window = campaign.endAt.map { " до \(Self.adsDateFormatter.string(from: $0)) (показы размазаны равномерно)" } ?? " (без даты окончания)"
            try await sendUserFeedback(chatKey: chatKey, text: "✓ \(campaign.id): <b>\(target)</b> показов\(window). Счётчик обнулён.")

        case "button":
            let args = rest.split(separator: " ", maxSplits: 1).map(String.init)
            guard let id = args.first, var campaign = await state.adCampaign(id: id) else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/ads button &lt;id&gt; &lt;текст&gt; | &lt;url&gt;</code> или <code>/ads button &lt;id&gt; off</code>")
                return
            }
            let value = args.count > 1 ? args[1] : ""
            if value.lowercased() == "off" || value.isEmpty {
                campaign.buttonText = nil
                campaign.buttonURL = nil
                await state.upsertAdCampaign(campaign)
                try await sendUserFeedback(chatKey: chatKey, text: "✓ \(campaign.id): кнопка убрана.")
                return
            }
            let buttonParts = value.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard buttonParts.count == 2, !buttonParts[0].isEmpty, buttonParts[1].hasPrefix("http") else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/ads button &lt;id&gt; Открыть сайт | https://example.com</code>")
                return
            }
            campaign.buttonText = buttonParts[0]
            campaign.buttonURL = buttonParts[1]
            await state.upsertAdCampaign(campaign)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ \(campaign.id): кнопка «\(buttonParts[0])» → \(buttonParts[1])")

        case "text":
            let args = rest.split(separator: " ", maxSplits: 1).map(String.init)
            guard args.count == 2, var campaign = await state.adCampaign(id: args[0]) else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/ads text &lt;id&gt; &lt;новый текст&gt;</code>")
                return
            }
            campaign.text = args[1]
            await state.upsertAdCampaign(campaign)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ \(campaign.id): текст обновлён.")

        // Built-in self-promo (roadmap step 5) — same knobs as the menu page,
        // nothing about the pitch is hardcoded.
        case "promo":
            let args = rest.split(separator: " ", maxSplits: 1).map(String.init)
            let action = (args.first ?? "").lowercased()
            let value = args.count > 1 ? args[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            var promo = await state.selfPromoConfig()
            switch action {
            case "on", "off":
                promo.enabled = action == "on"
                await state.setSelfPromoConfig(promo)
                try await sendUserFeedback(chatKey: chatKey, text: promo.enabled
                    ? "✓ Само-реклама включена — займёт свободный рекламный слот."
                    : "✓ Само-реклама выключена — свободный слот останется пустым.")
            case "text":
                guard !value.isEmpty else {
                    try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/ads promo text &lt;новый текст&gt;</code>")
                    return
                }
                promo.text = value
                await state.setSelfPromoConfig(promo)
                try await sendUserFeedback(chatKey: chatKey, text: "✓ Текст само-рекламы обновлён (показы сохранены).")
            case "freq":
                let nums = value.split(separator: " ").map(String.init)
                guard let everyN = nums.first.flatMap(Int.init), SelfPromoConfig.repliesRange.contains(everyN) else {
                    try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/ads promo freq &lt;каждые_N_ответов&gt; [пауза_минут]</code>")
                    return
                }
                promo.everyNReplies = everyN
                if nums.count >= 2, let minutes = Int(nums[1]), SelfPromoConfig.pauseMinutesRange.contains(minutes) {
                    promo.minIntervalSeconds = minutes * 60
                }
                await state.setSelfPromoConfig(promo)
                let saved = await state.selfPromoConfig()
                try await sendUserFeedback(chatKey: chatKey, text: "✓ Само-реклама: каждые <b>\(saved.everyNReplies)</b> ответов · пауза <b>\(saved.minIntervalSeconds / 60) мин</b>.")
            case "reset":
                await state.resetSelfPromoStats()
                try await sendUserFeedback(chatKey: chatKey, text: "✓ Счётчик показов само-рекламы обнулён.")
            default:
                try await sendUserFeedback(chatKey: chatKey, text: """
                    <b>📣 Само-реклама премиума</b> · \(promo.enabled ? "включена" : "выключена")
                    Каждые <b>\(promo.everyNReplies)</b> ответов · пауза <b>\(promo.minIntervalSeconds / 60)</b> мин · показов <b>\(promo.impressions)</b>
                    <blockquote expandable>\(promo.text)</blockquote>
                    Занимает рекламный слот в бесплатных чатах, когда нет активной кампании. Кнопку «⚡ Открыть премиум» бот добавляет сам.

                    <code>/ads promo on|off</code> · <code>/ads promo text &lt;текст&gt;</code>
                    <code>/ads promo freq &lt;N&gt; [мин]</code> · <code>/ads promo reset</code>
                    """)
            }

        case "list", "stats", "":
            let campaigns = await state.adCampaigns()
            var lines = ["<b>📣 Рекламные кампании</b> (\(campaigns.count))"]
            if campaigns.isEmpty {
                lines.append("<i>нет</i>")
            } else {
                for c in campaigns {
                    lines.append("")
                    lines.append(contentsOf: adSummaryLines(c))
                }
            }
            let promo = await state.selfPromoConfig()
            lines.append("")
            lines.append("<b>Само-реклама премиума</b> · \(promo.enabled ? "вкл" : "выкл") · каждые \(promo.everyNReplies) отв. · пауза \(promo.minIntervalSeconds / 60) мин · показов \(promo.impressions)")
            lines.append("<i>Занимает слот, когда активных кампаний нет. Настройка — /ads promo</i>")
            lines.append("")
            lines.append("""
                <code>/ads add &lt;текст&gt;</code> — создать
                <code>/ads freq &lt;id&gt; &lt;N&gt; [мин]</code> — частота: каждые N ответов, пауза
                <code>/ads limit &lt;id&gt; &lt;показов&gt; [дней]</code> — лимит с равномерным пейсингом
                <code>/ads button &lt;id&gt; &lt;текст&gt; | &lt;url&gt;</code> — кнопка-ссылка
                <code>/ads text &lt;id&gt; &lt;текст&gt;</code> · <code>on|off|remove &lt;id&gt;</code>
                <code>/ads promo</code> — само-реклама премиума

                <i>Показы — только в чатах без активной платной лицензии, после ответа бота. Проверить самому: /simulate user, затем написать боту.</i>
                """)
            try await sendUserFeedback(chatKey: chatKey, text: lines.joined(separator: "\n"))

        default:
            try await sendUserFeedback(chatKey: chatKey, text: "<i>Неизвестная подкоманда.</i> Список: <code>/ads</code>")
        }
    }
}
