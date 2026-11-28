import Foundation

// The main menu page and the small formatters its lines share.

extension BotMenuHandler {
    // MARK: - Main page

    func renderMain(chatKey: ChatKey, invoker: UserKey? = nil) async -> MenuScreen {
        let help = await state.fetchHelp(chatKey: chatKey)
        let provider = help.provider
        let capabilities = gateways.capabilities(for: provider)
        let reasoningSupported = capabilities?.supportsReasoning ?? false
        let web = provider == .deepseekWeb
        let providerStatus = capabilities == nil ? " · не настроен" : ""
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
        let isGroupChat = chatKey.chatID.isGroup

        // Pay-as-you-go users see their wallet right on the main page.
        let wallet = isGroupChat ? nil : await state.balance(invoker)
        var balanceLine = ""
        if let wallet {
            let status = wallet.balance.isPositive ? "" : " <i>(исчерпан)</i>"
            balanceLine = "\n💰 Баланс · <b>\(wallet.balance.formatted())</b>" + status
        }

        // Who pays for the smart models here — the sponsor's standing credit
        // (roadmap step 3) and the answer to "почему у меня платные модели".
        let access = await state.chatAccessStatus(
            chatID: chatKey.chatID,
            key: isGroupChat ? nil : invoker
        )
        // Free tier: show what is *left* today, not just the cap. A number that
        // visibly counts down is the whole point of the daily taste (step 6);
        // a static "5 в день" tells nobody where they stand.
        let dailyPremium: (remaining: Int, limit: Int) = access.isCovered
            ? (0, 0)
            : await state.remainingDailyPremium(
                chatID: chatKey.chatID,
                userID: chatKey.chatID.asUserID,
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
            key: isGroupChat ? nil : invoker,
            chatID: chatKey.chatID
        )
        let modesOn = !modeConfig.activeModes.isEmpty

        var settingsSummary: String
        if modesOn {
            // The name and the line under it are the super-admin's text on
            // the one page every user opens: escaped, or a stray `<` in a mode
            // title takes the settings page down for everybody.
            let name = activeMode?.escapedTitle ?? "изменён вручную"
            let subtitle = activeMode.map { $0.subtitle.isEmpty ? "" : "\n<i>\($0.escapedSubtitle)</i>" }
                ?? (web ? "" : "\n<i>\(help.escapedModel)</i>")
            settingsSummary = "Режим · <b>\(name)</b>\(subtitle)"
        } else {
            let historyUnit = web ? "пар" : "сообщ."
            settingsSummary = "📝 Память · <b>\(help.maxHistory) \(historyUnit)</b>"
            if !web {
                settingsSummary = """
                🤖 Модель · <b>\(help.escapedModel)</b>
                🌡 Стиль ответа · <b>\(Self.tempBucket(help.temp))</b>
                \(settingsSummary)
                """
                if reasoningSupported {
                    settingsSummary += "\n🧠 Размышления · <b>\(reasoningLabel)</b>"
                }
            }
        }
        if web && reasoningSupported {
            settingsSummary += "\n🧠 DeepThink · <b>\(help.webDeepThinkLabel)</b>"
        }

        let text = """
        <b>⚙️ Настройки чата</b>

        \(accessLine)

        🔌 <b>\(provider.rawValue)</b>\(providerStatus)
        \(settingsSummary)

        \(usageLine)\(balanceLine)
        🆔 <code>\(chatKey.chatID)</code>
        """

        let isSuperAdmin = await state.isSuperAdmin(invoker)
        let isAdmin = isSuperAdmin ? true : await state.isAdmin(invoker, chatID: chatKey.chatID)
        let audience: MainMenuAudience
        if isGroupChat {
            audience = .group
        } else if isSuperAdmin {
            audience = .superAdmin
        } else if isAdmin {
            audience = .admin
        } else {
            audience = hasFullAccess ? .premium : .regular
        }

        typealias Item = (MainMenuButton, InlineKeyboardButton)
        func pageButton(_ id: MainMenuButton, _ page: MenuPage, title: String? = nil) -> Item {
            (id, menuButton(title ?? id.label, page: page))
        }

        var available: [[Item]] = []
        let lock = hasFullAccess ? "" : " ⭐"
        if web {
            available.append([pageButton(.role, .role), pageButton(.history, .history)])
            available.append([
                pageButton(.reasoning, .reasoning, title: "🧠 DeepThink"),
                (.search, menuButton(help.webSearchEnabled ? "🌐 Поиск · вкл" : "🌐 Поиск · выкл",
                                     .websearch, help.webSearchEnabled ? "off" : "on"))
            ])
        } else {
            available.append([pageButton(.role, .role), pageButton(.model, .model)])
            available.append([pageButton(.style, .temp, title: MainMenuButton.style.label + lock), pageButton(.history, .history)])
            available.append([pageButton(.reasoning, .reasoning, title: "🧠 Размышления" + lock)])
        }
        // Listening is a group-chat feature; keep its existing access rules.
        if isGroupChat {
            let listening = await state.listening(chatKey: chatKey)
            available.append([pageButton(.listen, .listen, title: listening.isOn
                ? MainMenuButton.listen.label + " · 🟢" : MainMenuButton.listen.label
            )])
        }
        available.append([pageButton(.tuning, .tuning)])
        available.append([pageButton(.presets, .presets)])

        // Everything below is a different job — money and growth, not settings.
        // Telegram has no separators, so a dead button draws the line; without
        // it the page is fourteen buttons of equal weight and reads as noise.
        available.append([(.separator, menuButton("· · · · ·", command: .noop))])

        // Onboarding (roadmap step 9): a way back to the ready-made prompts
        // after the greeting has scrolled away.
        if !(await state.onboardingConfig().activeExamples(inGroup: isGroupChat).isEmpty) {
            available.append([(.examples, menuButton(MainMenuButton.examples.label, command: .examples))])
        }
        // Monetization entry point: shown whenever there is something to buy
        // or an existing subscription/wallet to inspect.
        let starsPrice = await state.starsPrice()
        let cryptoCents = await state.cryptoPriceUsdCents()
        var isTenant = false
        if let invoker, !isGroupChat {
            isTenant = await state.isTenant(invoker)
        }
        let card = await state.cardConfig()
        if (starsPrice ?? 0) > 0 || cryptoCents != nil || card.isEnabled || isTenant || wallet != nil {
            // "Продлить" would out the tapper as a paying customer in a group.
            let payLabel = isTenant ? "🔄 Продлить премиум" : "⚡ Премиум-доступ"
            available.append([pageButton(.purchase, .pay, title: payLabel)])
        }
        // Viral loop: one tap opens Telegram's group picker and adds the bot.
        if !botUsername.isEmpty {
            available.append([(.addToGroup, InlineKeyboardButton(text: MainMenuButton.addToGroup.label, url: "https://t.me/\(botUsername)?startgroup=add"))])
        }
        // Referral (roadmap step 10): personal link, so private chats only.
        let referral = await state.referralConfig()
        if referral.enabled, !botUsername.isEmpty, chatKey.chatID.isPrivate {
            let reward = referral.inviterRewardCents > 0
                ? " · +\(ReferralConfig.formatUsd(cents: referral.inviterRewardCents))" : ""
            available.append([pageButton(.referral, .referral, title: MainMenuButton.referral.label + reward)])
        }
        available.append([pageButton(.help, .helpPage)])
        if isSuperAdmin {
            available.append([pageButton(.admin, .adminPanel), pageButton(.superAdmin, .superAdmin)])
        } else if isAdmin {
            available.append([pageButton(.admin, .adminPanel)])
        }
        available.append([(.close, menuButton(Texts.close, command: .close))])

        // Keep buttons from an original row together while they are adjacent
        // in the configured order, including when their positions are swapped.
        var byID: [MainMenuButton: (row: Int, button: InlineKeyboardButton)] = [:]
        for (row, items) in available.enumerated() {
            for (id, button) in items { byID[id] = (row, button) }
        }
        var rows: Keyboard = []
        var lastRow: Int?
        for entry in await state.mainMenuEntries(for: audience) where entry.visible {
            guard let item = byID[entry.button] else { continue }
            if item.row == lastRow {
                rows.extendLastRow(with: item.button)
            } else {
                rows.row(item.button)
            }
            lastRow = item.row
        }

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
