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

        func formatUsd(_ value: Money) -> String { value.formatted() }

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
                    ? await state.creditBalance(username: target, amount: .usd(amount))
                    : await state.setBalanceAmount(username: target, amount: .usd(amount))
                try await sendUserFeedback(chatKey: chatKey, text: """
                    ✓ Баланс @\(target.lowercased()) · <b>\(formatUsd(wallet.balance))</b>
                    Потрачено: клиентская цена \(formatUsd(wallet.spentBilled)) · реально \(formatUsd(wallet.spentReal))
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
                    var totalBalance = Money.zero, totalBilled = Money.zero, totalReal = Money.zero
                    for entry in balances {
                        let w = entry.wallet
                        totalBalance += w.balance
                        totalBilled += w.spentBilled
                        totalReal += w.spentReal
                        lines.append("")
                        lines.append("• <b>\(entry.label)</b> · остаток <b>\(formatUsd(w.balance))</b>")
                        lines.append("  списано \(formatUsd(w.spentBilled)) · реально \(formatUsd(w.spentReal)) · маржа <b>\(formatUsd(w.margin))</b>")
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

        let status = wallet.balance.isPositive
            ? "🟢 Пока баланс не пуст, вам доступны любые модели"
            : "⛔ Баланс пуст — отвечают только бесплатные модели"
        var lines = ["<b>💰 Ваш баланс</b>", ""]
        lines.append("Остаток · <b>\(formatUsd(wallet.balance))</b>")
        lines.append("Потрачено всего · \(formatUsd(wallet.spentBilled))")
        lines.append(status)
        lines.append("")
        lines.append("<i>С баланса списывается стоимость каждого ответа — обычно доли цента. Сколько списалось, видно под самим ответом (включите показ: /show_cost).</i>")
        lines.append("<i>Пополнить — /buy. Бесплатно — пригласить друга: /ref.</i>")

        // The last few movements. Without them a shrinking balance is something
        // the user has to take on trust, and a disagreement about it has no
        // evidence on either side (§10.2).
        if let recent = try? await ledger.recentEntries(userKey: username, limit: 5), !recent.isEmpty {
            lines.append("")
            lines.append("<b>Последние движения</b>")
            let formatter = DateFormatter()
            formatter.dateFormat = "dd.MM HH:mm"
            for entry in recent {
                let sign = entry.amount.isPositive ? "+" : "−"
                lines.append(
                    "\(formatter.string(from: entry.createdAt)) · \(entry.kind.displayName)"
                    + " · <b>\(sign)$\(entry.amount.formattedAmount(fractionDigits: 4))</b>"
                )
            }
        }
        if isSuper {
            lines.append("<i>Реально потрачено (суперадмин): \(formatUsd(wallet.spentReal)) · маржа \(formatUsd(wallet.margin))</i>")
        }
        try await sendUserFeedback(chatKey: chatKey, text: lines.joined(separator: "\n"))
    }
}
