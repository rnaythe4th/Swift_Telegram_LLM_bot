import Foundation

// Super-admin panel: the callback dispatcher, the two money knobs that have no
// page of their own (markup, daily premium taste) and the panel itself. The
// other groups live next to their page: rosters/tenants/wallets in +Tenants,
// prices and free models in +PaymentSettings, ads in +Growth.

extension BotMenuHandler {
    /// Super-admin actions: prices, payment methods, tenants, wallets, ads.
    func processSuperAdminAction(
        route: MenuRoute,
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        switch route.command {
        case .sa:
            try await handleSuperAdminRosterAction(route: route, chatKey: chatKey, callback: callback, message: message)

        case .stenant:
            try await handleSuperTenantAction(route: route, chatKey: chatKey, callback: callback, message: message)

        case .sim:
            try await handleSimulationAction(route: route, chatKey: chatKey, callback: callback, message: message)

        case .sinspect:
            try await handleInspectChatAction(route: route, callback: callback, message: message)

        case .ads:
            try await handleAdCampaignAction(route: route, chatKey: chatKey, callback: callback, message: message)

        case .markup:
            try await handleMarkupAction(route: route, chatKey: chatKey, callback: callback, message: message)

        case .dailylimit:
            try await handleDailyLimitAction(route: route, chatKey: chatKey, callback: callback, message: message)

        case .stars:
            try await handleStarsAdminAction(route: route, chatKey: chatKey, callback: callback, message: message)

        case .freemodels:
            try await handleFreeModelsAdminAction(route: route, chatKey: chatKey, callback: callback, message: message)

        case .sbal:
            try await handleWalletAdminAction(route: route, chatKey: chatKey, callback: callback, message: message)

        case .crypto:
            guard await requireSuperAdmin(callback) else { return }
            try await handleCryptoAdminAction(route: route, chatKey: chatKey, callback: callback, message: message)
            return

        case .card:
            guard await requireSuperAdmin(callback) else { return }
            try await handleCardAdminAction(route: route, chatKey: chatKey, callback: callback, message: message)
            return

        case .extpay:
            try await handleExternalPayAdminAction(route: route, chatKey: chatKey, callback: callback, message: message)
            return

        default:
            break
        }
    }

    // MARK: - Markup and the daily premium taste

    private func handleMarkupAction(
        route: MenuRoute,
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard await requireSuperAdmin(callback) else { return }
        guard route.sub == "set" else { return }
        await state.setPending(.admin(.init(kind: .markupPercent)), menuMessageID: message.message_id, chatKey: chatKey)
        let currentPct = await state.markupPercent()
        let markupPrompt = """
        <b>💹 Наценка на цены моделей</b>

        Текущая: <b>\(currentPct)%</b>

        Отправьте число от <code>0</code> до <code>500</code> — процент наценки к ценам провайдера. Применяется ко всем ценам, которые видят пользователи (футер, меню, /model), и к списаниям с балансов.
        """
        let markupMarkup: Keyboard = [[cancelButton(to: .superAdmin)]]
        try await editOrAnswer(callback: callback, message: message, screen: MenuScreen(markupPrompt, markupMarkup))
    }

    private func handleDailyLimitAction(
        route: MenuRoute,
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard await requireSuperAdmin(callback) else { return }
        guard route.sub == "set" else { return }
        await state.setPending(.admin(.init(kind: .dailyPremiumLimit)), menuMessageID: message.message_id, chatKey: chatKey)
        let currentLimit = await state.dailyPremiumLimit()
        let limitPrompt = """
        <b>🎁 Дневной премиум-вкус (free-tier)</b>

        Текущий лимит: <b>\(currentLimit)</b> умных ответов в день.

        Отправьте число от <code>0</code> до <code>100</code> — сколько ответов платной модели в день получает бесплатный чат (в группе — общий на чат, в личке — на пользователя), прежде чем бот переключится на бесплатную модель и предложит премиум. <code>0</code> — совсем без премиум-вкуса. Бесплатные модели всегда без лимита.
        """
        let limitMarkup: Keyboard = [[cancelButton(to: .superAdmin)]]
        try await editOrAnswer(callback: callback, message: message, screen: MenuScreen(limitPrompt, limitMarkup))
    }

    func renderSuperAdmin(chatKey: ChatKey) async -> MenuScreen {
        let starsPrice = await state.starsPrice()
        let starsLabel = starsPrice.map { "<b>\($0) ⭐</b>" } ?? "<b>отключена</b>"

        let cryptoCents = await state.cryptoPriceUsdCents()
        let cryptoLabel = cryptoCents.map { String(format: "<b>$%.2f</b>", Double($0) / 100.0) } ?? "<b>отключена</b>"
        let cryptoMode = await state.cryptoMatchMode()
        let openInvoices = await state.openCryptoInvoices()

        let freeModels = await state.freeModelIDs()
        let freeCount = freeModels.count

        let globalRoles = await state.rolePresets(chatID: chatKey.chatID).count
        let globalModels = await state.modelPresets(chatID: chatKey.chatID).count
        let globalTemps = await state.tempPresets(chatID: chatKey.chatID).count
        let globalHist = await state.historyLengthPresets(chatID: chatKey.chatID).count

        let starsButtonLabel = starsPrice.map { "💫 Stars · \($0) ⭐" } ?? "💫 Stars · откл"
        let cryptoButtonLabel = cryptoCents.map { String(format: "🪙 Крипто · $%.2f", Double($0) / 100.0) } ?? "🪙 Крипто · откл"

        let external = await state.externalPaymentConfig()
        let card = await state.cardConfig()
        let cardLabel = card.isEnabled ? "<b>\(card.priceLabel ?? "")</b>\(card.isTestToken ? " · тест" : "")" : "<b>отключена</b>"
        let cardButtonLabel = card.isEnabled ? "💳 Карта · \(card.priceLabel ?? "")" : "💳 Карта · откл"

        let tenantStats = await state.tenantStats()
        let totalTenants = tenantStats.count

        let markupPct = await state.markupPercent()
        let dailyLimit = await state.dailyPremiumLimit()
        let reminders = await state.reminderConfig()
        let onboarding = await state.onboardingConfig()
        let referral = await state.referralConfig()
        let referralOverview = await state.referralOverview(topLimit: 1)
        let traffic = await state.trafficSourceOverview()
        let lifecycle = await state.subscriptionLifecycleStats()
        let balances = await state.allBalances()
        let balancesTotal = balances.reduce(0.0) { $0 + $1.wallet.balanceUsd }
        let marginTotal = balances.reduce(0.0) { $0 + ($1.wallet.spentBilledUsd - $1.wallet.spentRealUsd) }

        let modes = await state.modeConfig()
        let freeModeCount = modes.activeModes.filter { $0.tier == .free }.count

        let rows: Keyboard = [
            [menuButton("🎛 Режимы бота · \(modes.enabled ? "\(modes.activeModes.count)" : "выкл")", page: .superModes)],
            [menuButton(starsButtonLabel, page: .superStars)],
            [menuButton(cryptoButtonLabel, page: .superCrypto)],
            [menuButton(cardButtonLabel, page: .superCard)],
            [menuButton(
                external.isEnabled || external.creditsEnabled
                    ? "🏦 Внешняя касса · \(external.priceLabel ?? external.usdRateLabel ?? "вкл")"
                    : "🏦 Внешняя касса · откл",
                page: .superExternalPay
            )],
            [menuButton("🆓 Бесплатные модели · \(freeCount)", page: .superFreeModels)],
            [menuButton("🏢 Тенанты и статистика · \(totalTenants)", page: .superTenants)],
            [menuButton("👁 Чаты бота", page: .superChats),
             menuButton("📣 Реклама", page: .superAds)],
            [menuButton("🛡 Суперадмины", page: .superAdmins),
             menuButton("🎭 Симуляция", page: .superSimulate)],
            [menuButton("💰 Балансы · \(balances.count)", page: .superBalances),
             menuButton("💹 Наценка · \(markupPct)%", .markup, "set")],
            [menuButton("🎁 Премиум-лимит/день · \(dailyLimit)", .dailylimit, "set")],
            [menuButton("⏳ Напоминания и winback · \(reminders.enabled ? "вкл" : "выкл")", page: .superReminders)],
            [menuButton("💡 Примеры-запросы · \(onboarding.enabled ? "\(onboarding.enabledExamples.count)" : "выкл")", page: .superOnboarding)],
            [menuButton("🎁 Приглашения · \(referral.enabled ? ReferralConfig.formatUsd(cents: referral.inviterRewardCents) : "выкл")", page: .superReferrals)],
            [menuButton("📊 Воронка и аналитика", page: .superFunnel),
             menuButton("📈 Источники · \(traffic.campaigns)", page: .superTraffic)],
            [menuButton("🪙 Открытые счета · \(openInvoices.count)", .crypto, "invoices")],
            [menuButton("📋 Общие заготовки · 🤖 Модели", .pm, "model"),
             menuButton("🎭 Роли", .pm, "role")],
            [menuButton("🌡 Стили ответа", .pm, "temp"),
             menuButton("📝 Память", .pm, "history")],
            [menuButton("ℹ️ Справка по командам", page: .superAdminHelp)],
            navButtons(),
        ]

        let text = """
        <b>🛡 Супер-админ</b>

        💫 Stars · \(starsLabel)
        🪙 Крипто · \(cryptoLabel) · режим <b>\(cryptoMode.displayName)</b>
        💳 Карта · \(cardLabel)
        🏦 Внешняя касса · \(external.vendor.displayName) · \(external.isEnabled ? "<b>\(external.priceLabel ?? "")</b>" : "<b>откл</b>")\(external.creditsEnabled ? " · пополнения вкл" : "")
        💹 Наценка · <b>\(markupPct)%</b> · /tenant markup
        🎛 Режимы · <b>\(modes.enabled ? "вкл" : "выкл")</b> · всего <b>\(modes.activeModes.count)</b> · бесплатных <b>\(freeModeCount)</b> · рабочий <b>\(modes.defaultMode?.title ?? "—")</b>
        🎁 Премиум-вкус · <b>\(dailyLimit)</b> умных ответов/день бесплатным
        💡 Примеры-запросы · <b>\(onboarding.enabled ? "вкл" : "выкл")</b> · в личке <b>\(onboarding.activeExamples(inGroup: false).count)</b> · в группах <b>\(onboarding.showInGroups ? onboarding.activeExamples(inGroup: true).count : 0)</b>
        ⏳ Напоминания · <b>\(reminders.enabled ? "вкл" : "выкл")</b> · скоро истекут <b>\(lifecycle.expiringSoon.count)</b> · winback-офферов <b>\(lifecycle.activeDiscounts.count)</b>
        🎁 Приглашения · <b>\(referral.enabled ? "вкл" : "выкл")</b> · выплачено пар <b>\(referralOverview.rewarded)</b> · \(String(format: "$%.2f", referralOverview.paidOutUsd)) · ждут <b>\(referralOverview.pending)</b>
        📈 Источники рекламы · кампаний <b>\(traffic.campaigns)</b> · пришло <b>\(traffic.joined)</b> · оплатили <b>\(traffic.payers)</b>
        💰 Балансов · <b>\(balances.count)</b> · остатки \(String(format: "$%.2f", balancesTotal)) · маржа <b>\(String(format: "$%.4f", marginTotal))</b> · /balance list
        🆓 Бесплатных моделей · <b>\(freeCount)</b>
        🪙 Открытых счетов · <b>\(openInvoices.count)</b>

        <b>Общие заготовки</b> <i>(кнопки во всех чатах)</i>
        🤖 Моделей · <b>\(globalModels)</b> · 🎭 Ролей · <b>\(globalRoles)</b>
        🌡 Стилей ответа · <b>\(globalTemps)</b> · 📝 Памяти · <b>\(globalHist)</b>
        """
        return MenuScreen(text, rows)
    }
}
