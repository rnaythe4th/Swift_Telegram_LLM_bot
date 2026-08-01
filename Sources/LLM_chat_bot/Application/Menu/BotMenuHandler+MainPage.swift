import Foundation

// The main menu page and the small formatters its lines share.

extension BotMenuHandler {
    // MARK: - Main page

    func renderMain(chatKey: ChatKey, username: String? = nil) async -> MenuScreen {
        let help = await state.fetchHelp(chatKey: chatKey)
        let provider = await state.provider(chatKey: chatKey)
        let gateway = try? gateways.gateway(for: provider)
        let reasoningSupported = gateway?.capabilities.supportsReasoning ?? false
        let reasoningLabel = help.reasoningEffort?.displayName ?? "выключено"
        let usage = help.cumulativeUsage
        let usageLine: String
        if usage.generationCount == 0 {
            usageLine = "📈 Запросов пока нет"
        } else {
            var parts: [String] = ["запросов <b>\(usage.generationCount)</b>"]
            if usage.totalTokens > 0 {
                parts.append("текста <b>\(ResponseFooterFormatter.formatTokenValue(usage.totalTokens))</b>")
            }
            let billedTotal = await state.billedCost(of: usage)
            if billedTotal.isPositive {
                parts.append("итого <b>$\(Self.formatCost(billedTotal.usdValue))</b>")
            }
            usageLine = "📈 " + parts.joined(separator: " · ")
        }

        // In a group the menu is one shared message: whoever taps, everyone
        // reads the result. So the page only ever states facts about the chat
        // itself — a personal wallet balance (or "your subscription runs until
        // …") would be published to every member (CLAUDE.md §13/§17).
        let isGroupChat = chatKey.chatID < 0

        // Pay-as-you-go users see their wallet right on the main page.
        let wallet = isGroupChat ? nil : await state.balance(username: username)
        var balanceLine = ""
        if let wallet {
            let status = wallet.balance.isPositive ? "" : " <i>(исчерпан)</i>"
            balanceLine = "\n💰 Баланс · <b>\(wallet.balance.formatted())</b>" + status
        }

        // Who pays for the smart models here — the sponsor's standing credit
        // (roadmap step 3) and the answer to "почему у меня платные модели".
        let access = await state.chatAccessStatus(
            chatID: chatKey.chatID,
            username: isGroupChat ? nil : username
        )
        // Free tier: show what is *left* today, not just the cap. A number that
        // visibly counts down is the whole point of the daily taste (step 6);
        // a static "5 в день" tells nobody where they stand.
        let dailyPremium: (remaining: Int, limit: Int) = access.isCovered
            ? (0, 0)
            : await state.remainingDailyPremium(
                chatID: chatKey.chatID,
                userID: chatKey.chatID > 0 ? chatKey.chatID : nil,
                isGroup: isGroupChat
            )
        let accessLine = Self.accessStatusLine(
            access,
            isGroup: isGroupChat,
            dailyPremiumLimit: dailyPremium.limit,
            dailyPremiumLeft: dailyPremium.remaining
        )

        // Reference modes (§ modes): the page leads with what the chat *is*,
        // not with six technical fields. The old summary listed "Сервис ИИ",
        // "Стиль ответа" and a raw model id — five lines nobody without an ML
        // background can act on.
        let modeConfig = await state.modeConfig()
        let activeMode = await state.activeMode(chatKey: chatKey)
        // In a group this decides which modes are shown as locked, and the menu
        // is one message everyone reads — so it must be a fact about the chat,
        // not about whoever tapped (CLAUDE.md §13). A member's own balance is
        // theirs to know.
        let hasFullAccess = await state.hasFullModelAccess(
            username: isGroupChat ? nil : username,
            chatID: chatKey.chatID
        )
        let modesOn = !modeConfig.activeModes.isEmpty

        var settingsSummary: String
        if modesOn {
            let name = activeMode?.title ?? "изменён вручную"
            let subtitle = activeMode.map { $0.subtitle.isEmpty ? "" : "\n<i>\($0.subtitle)</i>" }
                ?? "\n<i>\(help.model)</i>"
            settingsSummary = "Режим · <b>\(name)</b>\(subtitle)"
        } else {
            settingsSummary = """
            🤖 Модель · <b>\(help.model)</b>
            🌡 Стиль ответа · <b>\(Self.tempBucket(help.temp))</b>
            📝 Память · <b>\(help.maxHistory) сообщ.</b>\
            \(reasoningSupported ? "\n🧠 Обдумывание · <b>\(reasoningLabel)</b>" : "")
            """
        }

        let text = """
        <b>⚙️ Настройки чата</b>

        \(accessLine)

        \(settingsSummary)

        \(usageLine)\(balanceLine)
        🆔 <code>\(chatKey.chatID)</code>
        """

        var rows: Keyboard = []
        if modesOn {
            rows = modeRows(config: modeConfig, activeID: activeMode?.id, hasFullAccess: hasFullAccess)
            // "↺ Рабочий режим" only once the chat is actually off it —
            // otherwise it is a button that does nothing.
            let working = modeConfig.defaultMode
            let onWorkingMode = activeMode != nil && activeMode?.id == working?.id
            rows.row([
                menuButton("🎭 Роль", page: .role),
                onWorkingMode || working == nil
                    ? menuButton("↺ Сбросить", command: .reset)
                    : menuButton("↺ Рабочий режим", .mode, "reset"),
            ])
        } else {
            rows.row([menuButton("🤖 Модель", page: .model), menuButton("🎭 Роль", page: .role)])
            rows.row([menuButton("🌡 Стиль ответа", page: .temp), menuButton("📝 Память", page: .history)])
            rows.row([menuButton("↺ Сбросить", command: .reset)])
        }
        // The modes are a shortlist, not a cage: the model page lists every
        // free model with its price and lets anyone pick one. Without this a
        // free user has no way to see that the list exists.
        rows.row([menuButton("⚙️ Тонкая настройка", page: .tuning)])

        // Everything below is a different job — money and growth, not settings.
        // Telegram has no separators, so a dead button draws the line; without
        // it the page is fourteen buttons of equal weight and reads as noise.
        rows.row([menuButton("· · · · ·", command: .noop)])

        // Onboarding (roadmap step 9): a way back to the ready-made prompts
        // after the greeting has scrolled away.
        if !(await state.onboardingConfig().activeExamples(inGroup: chatKey.chatID < 0).isEmpty) {
            rows.row([menuButton("💡 Примеры-запросы", command: .examples)])
        }
        // Monetization entry point: shown whenever there is something to buy
        // or an existing subscription/wallet to inspect.
        let starsPrice = await state.starsPrice()
        let cryptoCents = await state.cryptoPriceUsdCents()
        var isTenant = false
        if let username, !isGroupChat {
            isTenant = await state.isTenant(username: username)
        }
        let card = await state.cardConfig()
        if (starsPrice ?? 0) > 0 || cryptoCents != nil || card.isEnabled || isTenant || wallet != nil {
            // "Продлить" would out the tapper as a paying customer in a group.
            let payLabel = isTenant ? "🔄 Продлить премиум" : "⚡ Премиум-доступ"
            rows.row([menuButton(payLabel, page: .pay)])
        }
        // Viral loop: one tap opens Telegram's group picker and adds the bot.
        if !botUsername.isEmpty {
            rows.row([InlineKeyboardButton(text: "➕ Добавить в свой чат", url: "https://t.me/\(botUsername)?startgroup=add")])
        }
        // Referral (roadmap step 10): personal link, so private chats only.
        let referral = await state.referralConfig()
        if referral.enabled, !botUsername.isEmpty, chatKey.chatID > 0 {
            let label = referral.inviterRewardCents > 0
                ? "🎁 Пригласить друга · +\(ReferralConfig.formatUsd(cents: referral.inviterRewardCents))"
                : "🎁 Пригласить друга"
            rows.row([menuButton(label, page: .referral)])
        }
        rows.row([menuButton("❓ Справка", page: .helpPage)])
        if await state.isSuperAdmin(username: username) {
            rows.row([
                menuButton("⚡ Мой премиум", page: .adminPanel),
                menuButton("🛡 Супер-админ", page: .superAdmin),
            ])
        } else if await state.isAdmin(username: username, chatID: chatKey.chatID) {
            rows.row([menuButton("⚡ Мой премиум", page: .adminPanel)])
        }
        rows.row([menuButton(Texts.close, command: .close)])

        return MenuScreen(text, rows)
    }

    /// One line naming who pays for smart models in this chat. Shown on the
    /// settings page and the purchase page so the sponsor gets public credit
    /// (roadmap step 3) and nobody is sold access they already have.
    static func accessStatusLine(
        _ access: ChatAccessStatus,
        isGroup: Bool,
        dailyPremiumLimit: Int = 0,
        dailyPremiumLeft: Int = 0
    ) -> String {
        switch access {
        case .ownSubscription(let until):
            guard let until else { return "⚡ Премиум · <b>бессрочный</b>" }
            let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy"
            return "⚡ Премиум · <b>ваш</b>, до \(f.string(from: until))"
        case .sponsored(let owner):
            return isGroup
                ? "⚡ Премиум для чата открыл <b>\(owner)</b> — спасибо!"
                : "⚡ Премиум · открыт по подписке <b>\(owner)</b>"
        case .guest(let owner):
            return "⚡ Премиум · вам открыл доступ <b>\(owner)</b>"
        case .balance(let remaining):
            return "💰 Оплата по факту · на балансе <b>\(remaining.formatted())</b>"
        case .free:
            // Only promise a daily taste of the smart models when one is
            // actually configured (the super-admin can set the cap to 0).
            let taste = dailyPremiumLimit > 0
                ? " · сегодня осталось умных ответов: <b>\(dailyPremiumLeft) из \(dailyPremiumLimit)</b>"
                : ""
            return isGroup
                ? "🆓 Бесплатный доступ\(taste) · премиум для всего чата откроет любой участник"
                : "🆓 Бесплатный доступ\(taste)"
        }
    }

    /// Toast tail for a free-tier user who picked a paid model on today's
    /// allowance: without the number the model silently falls back mid-day and
    /// reads as a bug rather than as the cap doing its job (roadmap step 6).
    static func dailyTasteToastSuffix(_ access: ChatContextStore.PaidModelAccess, isPaidModel: Bool) -> String {
        guard isPaidModel, case .dailyTaste(let remaining, let limit) = access else { return "" }
        return " · умных ответов сегодня: \(remaining) из \(limit)"
    }

    static func formatPriceM(_ perTokenPrice: Double) -> String {
        let perM = perTokenPrice * 1_000_000
        if perM == 0 { return "0" }
        if perM >= 1 { return String(format: "%.2f", perM) }
        if perM >= 0.01 { return String(format: "%.4f", perM) }
        return String(format: "%.6f", perM)
    }

    private static func formatCost(_ cost: Double) -> String {
        if cost == 0 { return "0" }
        if cost < 0.0001 { return String(format: "%.6f", cost) }
        if cost < 0.01 { return String(format: "%.5f", cost) }
        return String(format: "%.4f", cost)
    }
}
