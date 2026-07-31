import Foundation

// Referral: the user's own invite page and the super-admin controls.

extension BotMenuHandler {
    /// Posts the personal referral page as a fresh message (`/ref`). The userID
    /// comes from the sender, not from the chat, so it is correct even when the
    /// command is used somewhere unexpected.
    func sendReferral(chatKey: ChatKey, userID: Int) async {
        let screen = await renderReferral(chatKey: chatKey, userID: userID)
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

    /// Personal referral page (roadmap step 10). Private chats only — the link
    /// identifies its owner by userID and the rewards land on their wallet.
    func renderReferral(chatKey: ChatKey, userID: Int) async -> MenuScreen {
        let config = await state.referralConfig()
        let stats = await state.referralUserStats(userID: userID)
        let link = ReferralLink.url(botUsername: botUsername, userID: userID)

        var lines: [String] = ["<b>🎁 Пригласите друга</b>", ""]
        var rows: Keyboard = []

        guard config.enabled, !botUsername.isEmpty else {
            lines.append("Программа приглашений сейчас <b>выключена</b>.")
            rows.row(navButtons())
            return MenuScreen(lines.joined(separator: "\n"), rows)
        }

        if config.paysOnSignup {
            lines.append(String(
                format: "Друг открывает вашу ссылку и задаёт боту первый вопрос — в этот момент вам приходит <b>$%.2f</b>, а ему <b>$%.2f</b> на баланс.",
                config.inviterRewardUsd, config.inviteeRewardUsd
            ))
            if config.payingFriendBonusCents > 0 {
                lines.append(String(
                    format: "А если друг потом оформит оплату — вам придёт ещё <b>$%.2f</b>.",
                    config.payingFriendBonusUsd
                ))
            }
            lines.append("<i>Пока баланс не пуст, отвечают любые модели — подписка не нужна. С баланса списывается стоимость каждого ответа, обычно доли цента.</i>")
        } else if config.payingFriendBonusCents > 0 {
            lines.append(String(
                format: "Приведите друга: как только он оформит оплату, вам придёт <b>$%.2f</b> на баланс.",
                config.payingFriendBonusUsd
            ))
        } else {
            lines.append("Отправьте ссылку друзьям — бот сразу начнёт им отвечать в личке.")
        }
        lines.append("")
        lines.append("Ваша ссылка:")
        lines.append("<code>\(link)</code>")
        lines.append("")
        lines.append("Пришло по ссылке · <b>\(stats.invited)</b>")
        lines.append("Уже принесли бонус · <b>\(stats.rewarded)</b>")
        lines.append("Ждут первого вопроса · <b>\(stats.pending)</b>")
        if stats.paidConversions > 0 {
            lines.append("Из них оформили оплату · <b>\(stats.paidConversions)</b>")
        }
        if stats.earnedUsd > 0 {
            lines.append(String(format: "Заработано · <b>$%.2f</b>", stats.earnedUsd))
        }
        if let remaining = stats.capRemaining {
            lines.append("Осталось приглашений с бонусом · <b>\(remaining)</b>")
            // Say it plainly rather than keep showing an offer that will not
            // pay — the friend is told the same thing when they open the link.
            if remaining == 0, config.paysAnything {
                lines.append("")
                lines.append("ℹ️ Бонусы за приглашения у вас исчерпаны. Ссылка продолжает работать — друзья по ней придут, но начислений больше не будет.")
            }
        }
        if let incoming = stats.incoming, incoming.isPending {
            lines.append("")
            lines.append("ℹ️ Вас пригласил <b>\(incoming.inviterUsername)</b> — бонус придёт, как только вы зададите боту первый вопрос.")
        }
        lines.append("")
        lines.append("<i>Бонус даётся один раз за друга и только за тех, кто раньше боту не писал.</i>")

        // The share text is what the friend actually reads, so it carries the
        // reason to tap: a bare "заходи по ссылке" converts far worse than the
        // same line with the bonus in it.
        let shareText = config.inviteeRewardCents > 0
            ? "Умный ИИ прямо в Telegram — отвечает на текст, фото и голос. По моей ссылке тебе сразу зачислят \(ReferralConfig.formatUsd(cents: config.inviteeRewardCents)) на баланс:"
            : "Умный ИИ прямо в Telegram — отвечает на текст, фото и голос. Заходи по моей ссылке:"
        rows.row([InlineKeyboardButton(
            text: "📤 Поделиться ссылкой",
            url: ReferralLink.shareURL(link: link, text: shareText)
        )])
        // Wallets are keyed by account, not by nick — resolve through the
        // userID so someone without a @username still sees their balance.
        if await state.balance(username: state.userKey(userID: userID)) != nil {
            rows.row([buyButton("💰 Баланс и оплата", source: .referral)])
        }
        rows.row(navButtons())
        return MenuScreen(lines.joined(separator: "\n"), rows)
    }

    /// Referral control + monitoring for the super-admin (roadmap step 10):
    /// rewards, the anti-farming cap, live program numbers and the top inviters.
    func renderSuperReferrals(chatKey: ChatKey) async -> MenuScreen {
        let config = await state.referralConfig()
        let overview = await state.referralOverview()
        let report = await state.funnelReport()
        let joined = report.count(.referralJoined)
        let rewarded = report.count(.referralRewarded)

        func pct(_ num: Int, _ den: Int) -> String {
            guard den > 0 else { return "—" }
            return String(format: "%.0f%%", Double(num) / Double(den) * 100)
        }

        var rows: Keyboard = [
            [menuButton(config.enabled ? "🟢 Программа включена" : "⚪️ Программа выключена", .sref, "toggle")],
            [menuButton("👤 Пригласившему · \(ReferralConfig.formatUsd(cents: config.inviterRewardCents))", .sref, "inviter"),
             menuButton("🎁 Другу · \(ReferralConfig.formatUsd(cents: config.inviteeRewardCents))", .sref, "invitee")],
            [menuButton("💎 За оплату друга · \(config.payingFriendBonusCents > 0 ? ReferralConfig.formatUsd(cents: config.payingFriendBonusCents) : "выкл")", .sref, "paidbonus")],
            [menuButton(config.maxRewardsPerInviter > 0
                ? "🛡 Лимит наград · \(config.maxRewardsPerInviter)"
                : "🛡 Лимит наград · без лимита", .sref, "cap")],
        ]
        if overview.bound > 0 {
            rows.row([menuButton("🗑 Очистить журнал приглашений", .sref, "clear")])
        }
        rows.row([menuButton("📊 Воронка", page: .superFunnel),
                     backButton(to: .superAdmin)])

        var lines: [String] = [
            "<b>🎁 Приглашения (реферальная программа)</b>",
            "",
            "Статус · <b>\(config.enabled ? "включена" : "выключена")</b>",
            "Награда · пригласившему <b>\(ReferralConfig.formatUsd(cents: config.inviterRewardCents))</b> · другу <b>\(ReferralConfig.formatUsd(cents: config.inviteeRewardCents))</b>",
            "За оплату друга · <b>\(config.payingFriendBonusCents > 0 ? ReferralConfig.formatUsd(cents: config.payingFriendBonusCents) : "выключено")</b>",
            "Лимит на человека · <b>\(config.maxRewardsPerInviter > 0 ? "\(config.maxRewardsPerInviter) наград" : "без лимита")</b> <i>(на бонус за оплату не действует)</i>",
            "",
            "Привязок · <b>\(overview.bound)</b> · выплачено пар · <b>\(overview.rewarded)</b> · ждут первого сообщения · <b>\(overview.pending)</b>",
            "Отклонено лимитом · <b>\(overview.blocked)</b> · пригласивших · <b>\(overview.inviters)</b>",
            String(format: "Выплачено всего · <b>$%.2f</b>", overview.paidOutUsd),
            "Переходов по ссылке · <b>\(joined)</b> → наград · <b>\(rewarded)</b> · конверсия <b>\(pct(rewarded, joined))</b>",
            "🔑 <b>Друзья, которые оплатили · \(overview.paidConversions)</b> · из награждённых <b>\(pct(overview.paidConversions, overview.rewarded))</b> — это число решает, окупается ли программа",
        ]

        // Refused opens separate "ссылку никто не открывает" from "открывают, но
        // правила всех отсеивают" — разные проблемы с разными решениями.
        if overview.refusedTotal > 0 {
            lines.append("")
            lines.append("<b>Переходы, которые не засчитались · \(overview.refusedTotal)</b> из \(overview.opens)")
            if overview.refusedSelf > 0 { lines.append("• по своей же ссылке · \(overview.refusedSelf)") }
            if overview.refusedRepeat > 0 { lines.append("• уже был приглашён · \(overview.refusedRepeat)") }
            if overview.refusedNotNew > 0 { lines.append("• уже пользовался ботом · \(overview.refusedNotNew)") }
            if overview.refusedUnknown > 0 { lines.append("• автор ссылки боту не писал · \(overview.refusedUnknown)") }
        }

        if !overview.top.isEmpty {
            lines.append("")
            lines.append("<b>Топ пригласивших</b>")
            for (index, entry) in overview.top.enumerated() {
                lines.append(String(
                    format: "%d. %@ · оплатили <b>%d</b> · наград %d · $%.2f · привязок %d",
                    index + 1, entry.tally.username, entry.tally.paidConversions,
                    entry.tally.rewarded, entry.tally.earnedUsd, entry.tally.invited
                ))
            }
        }

        lines.append("")
        lines.append("""
            <i>Антифрод: награда только за нового пользователя (кто ещё не писал боту в личке, не имеет кошелька и лицензии), одна привязка на человека навсегда, деньги — лишь после его первого реального ответа в личке, самоприглашение отклоняется, плюс лимит наград на пригласившего. Награда привязана к аккаунту Telegram, а не к @username — смена ника её не теряет.</i>
            """)
        lines.append("<i>Команда — /ref (юзерам — своя ссылка, суперадмину — управление).</i>")

        return MenuScreen(lines.joined(separator: "\n"), rows)
    }

    // MARK: - Referral admin actions (roadmap step 10)

    func handleReferralAdminAction(
        route: MenuRoute,
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard !route.sub.isEmpty else {
            try await showPage(.superReferrals, chatKey: chatKey, callback: callback, message: message)
            return
        }
        var config = await state.referralConfig()

        /// Asks for a value; the answer is applied in `processTextInput`.
        func ask(kind: AdminPendingInputKind, text: String) async throws {
            await state.setPending(.admin(.init(kind: kind)), menuMessageID: message.message_id, chatKey: chatKey)
            let markup: Keyboard = [[cancelButton(to: .superReferrals)]]
            try await editOrAnswer(callback: callback, message: message, screen: MenuScreen(text, markup))
        }

        switch route.sub {
        case "toggle":
            config.enabled.toggle()
            await state.setReferralConfig(config)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: config.enabled ? "🟢 Включена" : "⚪️ Выключена")
            try await showPage(.superReferrals, chatKey: chatKey, callback: callback, message: message)

        case "inviter":
            try await ask(kind: .referralInviterReward, text: """
                <b>👤 Награда пригласившему</b>

                Сейчас · <b>\(ReferralConfig.formatUsd(cents: config.inviterRewardCents))</b>

                Отправьте сумму в долларах, например <code>1</code> или <code>0.50</code>. <code>0</code> — не платить пригласившему.
                Максимум — \(ReferralConfig.formatUsd(cents: ReferralConfig.rewardRange.upperBound)) за приглашение.
                """)

        case "invitee":
            try await ask(kind: .referralInviteeReward, text: """
                <b>🎁 Награда другу</b>

                Сейчас · <b>\(ReferralConfig.formatUsd(cents: config.inviteeRewardCents))</b>

                Отправьте сумму в долларах, например <code>1</code>. <code>0</code> — приглашённый ничего не получает.
                """)

        case "paidbonus":
            try await ask(kind: .referralPaidBonus, text: """
                <b>💎 Бонус за оплату друга</b>

                Сейчас · <b>\(config.payingFriendBonusCents > 0 ? ReferralConfig.formatUsd(cents: config.payingFriendBonusCents) : "выключен")</b>

                Отправьте сумму в долларах, например <code>2</code>. <code>0</code> — не платить.

                Пригласивший получает её один раз, когда его друг впервые оплатил подписку или пополнение — любым способом. Награда за регистрацию покупает регистрации, эта — покупает клиентов, поэтому лимит наград на неё не действует.
                """)

        case "cap":
            try await ask(kind: .referralCap, text: """
                <b>🛡 Лимит наград на человека</b>

                Сейчас · <b>\(config.maxRewardsPerInviter > 0 ? "\(config.maxRewardsPerInviter)" : "без лимита")</b>

                Отправьте число от <code>\(ReferralConfig.capRange.lowerBound)</code> до <code>\(ReferralConfig.capRange.upperBound)</code> — сколько приглашений одного человека может быть оплачено за всё время. <code>0</code> — без лимита.
                Сверх лимита приглашения продолжают привязываться, но выплат не будет (видно в счётчике «отклонено лимитом»).
                """)

        case "clear":
            // Destructive: confirm before forgetting who invited whom.
            let overview = await state.referralOverview()
            let text = """
                <b>🗑 Очистить журнал приглашений?</b>

                Будет удалено привязок · <b>\(overview.bound)</b> (в т.ч. ждущих награды · \(overview.pending)), статистика пригласивших, счётчики отказов и итог «выплачено всего» (\(String(format: "$%.2f", overview.paidOutUsd))).

                ⚠️ Уже начисленные балансы останутся, но защита «одна привязка на человека» обнулится: ранее приглашённые смогут быть привязаны заново, если ещё не писали боту. Счётчики воронки не меняются.
                """
            let markup: Keyboard = [
                [menuButton("🗑 Да, очистить", .sref, "clearyes")],
                [cancelButton(to: .superReferrals)],
            ]
            try await editOrAnswer(callback: callback, message: message, screen: MenuScreen(text, markup))

        case "clearyes":
            let removed = await state.clearReferralLedger()
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🗑 Удалено привязок: \(removed)")
            try await showPage(.superReferrals, chatKey: chatKey, callback: callback, message: message)

        default:
            try await showPage(.superReferrals, chatKey: chatKey, callback: callback, message: message)
        }
    }
}
