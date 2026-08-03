import Foundation

// /ref: personal invite link, own stats and the super-admin knobs.

extension BotCommandHandler {
    // MARK: - Referral (roadmap step 10)

    /// `/ref` — personal invite link for everyone; super-admins additionally get
    /// the program switches, so it is controllable without the menu.
    func handleReferral(chatKey: ChatKey, argument: String, fromUser: TelegramUser?) async throws {
        let parts = argument.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let subcommand = (parts.first ?? "").lowercased()
        let isSuper = await isSuperAdmin(fromUser)

        if isSuper, !subcommand.isEmpty {
            var config = await state.referralConfig()
            switch subcommand {
            case "on", "off":
                config.enabled = subcommand == "on"
                await state.setReferralConfig(config)
                try await sendUserFeedback(chatKey: chatKey, text: "✓ Приглашения · <b>\(onOff(config.enabled))</b>")
                return

            case "reward", "friend", "bonus":
                // Integer parsing with an overflow check: `Int(Double)` traps
                // past `Int.max`, and this is a number typed into a chat.
                guard parts.count >= 2, let cents = FiatCurrency.minorUnits(from: parts[1]) else {
                    try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/ref \(subcommand) 1</code> — сумма в долларах, <code>0</code> — не платить.")
                    return
                }
                guard ReferralConfig.rewardRange.contains(cents) else {
                    try await sendUserFeedback(chatKey: chatKey, text: "⚠️ Максимум \(ReferralConfig.formatUsd(cents: ReferralConfig.rewardRange.upperBound)) за приглашение.")
                    return
                }
                switch subcommand {
                case "reward": config.inviterRewardCents = cents
                case "friend": config.inviteeRewardCents = cents
                default: config.payingFriendBonusCents = cents
                }
                await state.setReferralConfig(config)
                let applied = await state.referralConfig()
                try await sendUserFeedback(chatKey: chatKey, text: """
                    ✓ Награда · пригласившему <b>\(ReferralConfig.formatUsd(cents: applied.inviterRewardCents))</b> · другу <b>\(ReferralConfig.formatUsd(cents: applied.inviteeRewardCents))</b>
                    ✓ За оплату друга · <b>\(applied.payingFriendBonusCents > 0 ? ReferralConfig.formatUsd(cents: applied.payingFriendBonusCents) : "выключено")</b>
                    """)
                return

            case "cap":
                guard parts.count >= 2, let n = Int(parts[1]), ReferralConfig.capRange.contains(n) else {
                    try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/ref cap 20</code> — сколько приглашений одного человека оплачивается (0 — без лимита).")
                    return
                }
                config.maxRewardsPerInviter = n
                await state.setReferralConfig(config)
                try await sendUserFeedback(chatKey: chatKey, text: n == 0
                    ? "✓ Лимит наград снят (без лимита)."
                    : "✓ Лимит · <b>\(n)</b> оплаченных приглашений на человека.")
                return

            case "stats":
                let overview = await state.referralOverview(topLimit: 10)
                let report = await state.funnelReport()
                var lines = ["<b>🎁 Приглашения · статистика</b>", ""]
                lines.append("Статус · <b>\(onOff(config.enabled))</b> · награда \(ReferralConfig.formatUsd(cents: config.inviterRewardCents)) / \(ReferralConfig.formatUsd(cents: config.inviteeRewardCents)) · за оплату друга \(config.payingFriendBonusCents > 0 ? ReferralConfig.formatUsd(cents: config.payingFriendBonusCents) : "выкл") · лимит \(config.maxRewardsPerInviter > 0 ? "\(config.maxRewardsPerInviter)" : "нет")")
                lines.append("Друзья, которые оплатили · <b>\(overview.paidConversions)</b>")
                lines.append("Привязок · <b>\(overview.bound)</b> · выплачено пар · <b>\(overview.rewarded)</b> · ждут · <b>\(overview.pending)</b> · отклонено лимитом · <b>\(overview.blocked)</b>")
                lines.append("Выплачено всего · <b>\(overview.paidOut.formatted(fractionDigits: 2))</b> · пригласивших · <b>\(overview.inviters)</b>")
                lines.append("Переходов по ссылке · <b>\(report.count(.referralJoined))</b> · наград · <b>\(report.count(.referralRewarded))</b>")
                if overview.refusedTotal > 0 {
                    lines.append("Не засчитано переходов · <b>\(overview.refusedTotal)</b> · сам себя \(overview.refusedSelf) · уже приглашён \(overview.refusedRepeat) · не новый \(overview.refusedNotNew) · автор неизвестен \(overview.refusedUnknown)")
                }
                if !overview.top.isEmpty {
                    lines.append("")
                    lines.append("<b>Топ пригласивших</b>")
                    for (index, entry) in overview.top.enumerated() {
                        // The tally label already carries its own `@`.
                        lines.append(
                            "\(index + 1). \(entry.tally.username) · оплатили \(entry.tally.paidConversions)"
                            + " · наград \(entry.tally.rewarded) · \(entry.tally.earned.formatted(fractionDigits: 2))"
                            + " · привязок \(entry.tally.invited)"
                        )
                    }
                }
                lines.append("")
                lines.append("<i>Управление кнопками — /menu → 🛡 Супер-админ → 🎁 Приглашения</i>")
                try await sendUserFeedback(chatKey: chatKey, text: lines.joined(separator: "\n"))
                return

            case "help":
                try await sendUserFeedback(chatKey: chatKey, text: """
                    <b>🎁 Приглашения (реферальная программа)</b>

                    <code>/ref</code> — своя ссылка и личная статистика
                    <code>/ref stats</code> — цифры по всей программе
                    <code>/ref on|off</code> — включить/выключить
                    <code>/ref reward 1</code> — награда пригласившему, $
                    <code>/ref friend 1</code> — награда приглашённому, $
                    <code>/ref bonus 2</code> — бонус пригласившему, когда друг оплатил, $
                    <code>/ref cap 20</code> — лимит оплаченных приглашений на человека (0 — без лимита; на бонус за оплату не действует)

                    Очистка журнала привязок — только кнопкой: /menu → 🛡 Супер-админ → 🎁 Приглашения
                    """)
                return

            default:
                break
            }
        }

        guard let user = fromUser else { return }
        guard chatKey.chatID.isPrivate else {
            // Personal link in a shared chat would be meaningless — send them
            // to the DM instead.
            var rows: [[InlineKeyboardButton]] = []
            if !botUsername.isEmpty {
                // Plain bot link: their own referral link here would greet them
                // with "this is your own link".
                rows.append([InlineKeyboardButton(text: "🎁 Открыть бота", url: "https://t.me/\(botUsername)")])
            }
            _ = try await telegram.sendMessage(.init(
                chatID: chatKey.chatID,
                threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                replyTo: nil,
                text: "🎁 Ссылка-приглашение личная — откройте бота в личке и отправьте там /ref.",
                replyMarkup: rows.isEmpty ? nil : InlineKeyboardMarkup(inline_keyboard: rows)
            ))
            return
        }
        await menuHandler.sendReferral(chatKey: chatKey, userID: user.id)
    }
}
