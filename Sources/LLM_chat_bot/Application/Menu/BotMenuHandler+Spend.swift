import Foundation

// The spending ceilings page (§4.1).
//
// Everything else the owner can tune from inside the bot; a cap on money was
// the one thing that needed a redeploy — which is to say, it did not exist.
// Both ceilings are off by default, so switching one on is a decision rather
// than a surprise, and the page states what happens when either is reached.

extension BotMenuHandler {
    func renderSpendPolicy() async -> MenuScreen {
        let policy = await state.spendPolicy()
        let spend = await state.spendToday()

        func amount(_ money: Money) -> String {
            money.isPositive ? money.formatted(fractionDigits: 2) : "без лимита"
        }

        var rows: Keyboard = [
            [menuButton("🌍 Общий лимит/день · \(amount(policy.dailyGlobalCap))", .spend, "global")],
            [menuButton("🏢 Лимит на тенанта/день · \(amount(policy.dailyPerTenantCap))", .spend, "tenant")],
        ]
        if policy.hasTenantCap {
            rows.row([menuButton(
                "При достижении · \(policy.onTenantCap.displayName)",
                .spend, "response"
            )])
        }
        rows.row([backButton(to: .superAdmin)])

        let today = spend.total.formatted(fractionDigits: 2)
        let heaviest = spend.topTenants.prefix(5).map { entry in
            "• \(entry.label) · <b>\(entry.spent.formatted(fractionDigits: 2))</b>"
        }

        var lines = [
            "<b>💸 Лимиты расходов</b>",
            "",
            "Это единственный потолок, который действует на уже заплативших. Подписка — фиксированная цена, и она не может покупать неограниченный расход: группа на 500 человек на дорогой модели сжигает месячную оплату за вечер, а узнать об этом иначе можно только из счёта провайдера.",
            "",
            "Потрачено сегодня · <b>\(today)</b>",
        ]
        if policy.hasGlobalCap {
            lines.append("Общий лимит · <b>\(policy.dailyGlobalCap.formatted(fractionDigits: 2))</b> — при достижении умные модели выключаются до полуночи UTC, вам приходит уведомление.")
        }
        if policy.hasTenantCap {
            lines.append("Лимит на тенанта · <b>\(policy.dailyPerTenantCap.formatted(fractionDigits: 2))</b> · при достижении: <b>\(policy.onTenantCap.displayName)</b>. Спонсор видит свой расход на странице «⚡ Мой премиум».")
        }
        if !policy.isEnabled {
            lines.append("")
            lines.append("<i>Сейчас лимитов нет: расход ничем не ограничен.</i>")
        }
        if !heaviest.isEmpty {
            lines.append("")
            lines.append("<b>Кто тратит сегодня</b>")
            lines.append(contentsOf: heaviest)
        }
        lines.append("")
        lines.append("<i>Бесплатные модели не считаются и никогда не отключаются: лимит на расход не должен превращаться в простой бота.</i>")
        return MenuScreen(lines.joined(separator: "\n"), rows)
    }

    /// `spend:<action>` — the three knobs of the page.
    func processSpendAction(
        route: MenuRoute,
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard await requireSuperAdmin(callback) else { return }

        switch route.arg(1) {
        case "global":
            try await askForAmount(
                callback: callback, message: message, chatKey: chatKey,
                kind: .spendGlobalCap,
                title: "🌍 Общий дневной лимит расходов",
                detail: "Сколько бот может потратить у провайдеров за сутки. Достигнут — умные модели переключаются на бесплатные до полуночи UTC."
            )
        case "tenant":
            try await askForAmount(
                callback: callback, message: message, chatKey: chatKey,
                kind: .spendTenantCap,
                title: "🏢 Дневной лимит на одного тенанта",
                detail: "Сколько может потратить за сутки один подписчик со всеми своими чатами."
            )
        case "response":
            // Two options, so a button that cycles is clearer than a page.
            let policy = await state.spendPolicy()
            let next: SpendPolicy.CapResponse = policy.onTenantCap == .downgradeToFree ? .refuse : .downgradeToFree
            var updated = policy
            updated.onTenantCap = next
            await applySpendPolicy(updated)
            try await showPage(.superSpend, chatKey: chatKey, callback: callback, message: message)
        default:
            break
        }
    }

    private func askForAmount(
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage,
        chatKey: ChatKey,
        kind: AdminPendingInputKind,
        title: String,
        detail: String
    ) async throws {
        await state.setPending(.admin(.init(kind: kind)), menuMessageID: message.message_id, chatKey: chatKey)
        let prompt = """
        <b>\(title)</b>

        \(detail)

        Пришлите сумму в долларах, например <code>25</code> или <code>4.50</code>.
        <code>0</code> — снять лимит.
        """
        try await editOrAnswer(
            callback: callback,
            message: message,
            screen: MenuScreen(prompt, [[cancelButton(to: .superSpend)]])
        )
    }

    /// Writes the policy through the store so the change is persisted, and
    /// clears any alert the previous ceiling had raised — a limit that was
    /// just raised is no longer an incident.
    func applySpendPolicy(_ policy: SpendPolicy) async {
        await state.setSpendPolicy(policy)
    }
}
