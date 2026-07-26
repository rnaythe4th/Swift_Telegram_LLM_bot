import Foundation

// /balance: pay-as-you-go wallet, top-ups and super-admin adjustments.

extension BotCommandHandler {
    // MARK: - Balance (pay-as-you-go)

    func handleBalance(chatKey: ChatKey, argument: String, fromUser: TelegramUser?) async throws {
        let parts = argument.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let subcommand = (parts.first ?? "").lowercased()
        let isSuper = await isSuperAdmin(fromUser)

        func normalizeUsername(_ raw: String) -> String {
            raw.hasPrefix("@") ? String(raw.dropFirst()) : raw
        }

        func formatUsd(_ value: Double) -> String {
            String(format: "$%.4f", value)
        }

        // Super-admin management subcommands
        if isSuper {
            switch subcommand {
            case "add", "set":
                guard parts.count >= 3,
                      let amount = Double(parts[2].replacingOccurrences(of: ",", with: ".")) else {
                    try await sendUserFeedback(chatKey: chatKey, text: """
                        <i>Использование:</i>
                        <code>/balance add @username 5</code> — начислить $5 (минус — списать)
                        <code>/balance set @username 10</code> — установить баланс ровно $10
                        """)
                    return
                }
                let target = normalizeUsername(parts[1])
                guard !target.isEmpty else {
                    try await sendUserFeedback(chatKey: chatKey, text: "<i>Укажите @username.</i>")
                    return
                }
                let wallet = subcommand == "add"
                    ? await state.creditBalance(username: target, amountUsd: amount)
                    : await state.setBalanceAmount(username: target, amountUsd: amount)
                try await sendUserFeedback(chatKey: chatKey, text: """
                    ✓ Баланс @\(target.lowercased()) · <b>\(formatUsd(wallet.balanceUsd))</b>
                    Потрачено: клиентская цена \(formatUsd(wallet.spentBilledUsd)) · реально \(formatUsd(wallet.spentRealUsd))
                    """)
                return

            case "remove", "rm":
                guard parts.count >= 2 else {
                    try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/balance remove @username</code>")
                    return
                }
                let target = normalizeUsername(parts[1])
                let removed = await state.removeBalance(username: target)
                try await sendUserFeedback(chatKey: chatKey, text: removed
                    ? "✓ Кошелёк @\(target.lowercased()) удалён."
                    : "У @\(target.lowercased()) нет кошелька.")
                return

            case "list", "stats":
                let balances = await state.allBalances()
                let markup = await state.markupPercent()
                var lines = ["<b>💰 Балансы</b> (\(balances.count)) · наценка <b>\(markup)%</b>"]
                if balances.isEmpty {
                    lines.append("<i>кошельков нет</i>")
                } else {
                    var totalBalance = 0.0, totalBilled = 0.0, totalReal = 0.0
                    for entry in balances {
                        let w = entry.wallet
                        totalBalance += w.balanceUsd
                        totalBilled += w.spentBilledUsd
                        totalReal += w.spentRealUsd
                        let marginStr = formatUsd(w.spentBilledUsd - w.spentRealUsd)
                        lines.append("")
                        lines.append("• <b>\(entry.label)</b> · остаток <b>\(formatUsd(w.balanceUsd))</b>")
                        lines.append("  списано \(formatUsd(w.spentBilledUsd)) · реально \(formatUsd(w.spentRealUsd)) · маржа <b>\(marginStr)</b>")
                    }
                    lines.append("")
                    lines.append("<b>Итого</b> · остатки \(formatUsd(totalBalance)) · списано \(formatUsd(totalBilled)) · реально \(formatUsd(totalReal)) · маржа <b>\(formatUsd(totalBilled - totalReal))</b>")
                }
                lines.append("")
                lines.append("""
                    <code>/balance add @user 5</code> · <code>/balance set @user 10</code> · <code>/balance remove @user</code>
                    <code>/tenant markup 30</code> — наценка
                    """)
                try await sendUserFeedback(chatKey: chatKey, text: lines.joined(separator: "\n"))
                return

            default:
                break
            }
        }

        // Personal view (everyone, incl. superadmin without subcommand). The
        // wallet belongs to the account, so no @username is required.
        guard let userID = fromUser?.id else { return }
        let username = state.userKey(userID: userID)
        guard let wallet = await state.balance(username: username) else {
            var lines = [
                "<b>💰 Баланс</b>",
                "",
                "У вас пока нет баланса.",
                "",
                "Баланс — как счёт на телефоне: вы его пополняете, а с него списывается стоимость каждого ответа бота. Обычно это доли цента, так что $2 хватает надолго. Подписка при этом не нужна — платите только за то, чем пользуетесь.",
                ""
            ]
            if isSuper {
                lines.append("\n<i>Суперадмин:</i> <code>/balance add \(fromUser?.username.map { "@\($0)" } ?? username) 5</code> — начислить себе, <code>/balance list</code> — все кошельки.")
            } else {
                lines.append("Пополнить — /buy. Бесплатный способ: пригласить друга — /ref.")
            }
            try await sendUserFeedback(chatKey: chatKey, text: lines.joined(separator: "\n"))
            return
        }

        let status = wallet.balanceUsd > 0
            ? "🟢 Пока баланс не пуст, вам доступны любые модели"
            : "⛔ Баланс пуст — отвечают только бесплатные модели"
        var lines = ["<b>💰 Ваш баланс</b>", ""]
        lines.append("Остаток · <b>\(formatUsd(wallet.balanceUsd))</b>")
        lines.append("Потрачено всего · \(formatUsd(wallet.spentBilledUsd))")
        lines.append(status)
        lines.append("")
        lines.append("<i>С баланса списывается стоимость каждого ответа — обычно доли цента. Сколько списалось, видно под самим ответом (включите показ: /show_cost).</i>")
        lines.append("<i>Пополнить — /buy. Бесплатно — пригласить друга: /ref.</i>")
        if isSuper {
            lines.append("<i>Реально потрачено (суперадмин): \(formatUsd(wallet.spentRealUsd)) · маржа \(formatUsd(wallet.spentBilledUsd - wallet.spentRealUsd))</i>")
        }
        try await sendUserFeedback(chatKey: chatKey, text: lines.joined(separator: "\n"))
    }
}
