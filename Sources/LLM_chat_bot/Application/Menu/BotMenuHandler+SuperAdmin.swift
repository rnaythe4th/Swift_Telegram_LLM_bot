import Foundation

// Super-admin panel: the callback dispatcher, the two money knobs that have no
// page of their own (markup, daily premium taste) and the panel itself. The
// other groups live next to their page: rosters/tenants/wallets in +Tenants,
// prices and free models in +PaymentSettings, ads in +Growth.

extension BotMenuHandler {
    /// Super-admin actions: prices, payment methods, tenants, wallets, ads.
    func processSuperAdminAction(
        command: String,
        parts: [String],
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        switch command {
        case "sa":
            try await handleSuperAdminRosterAction(parts: parts, chatKey: chatKey, callback: callback, message: message)

        case "stenant":
            try await handleSuperTenantAction(parts: parts, chatKey: chatKey, callback: callback, message: message)

        case "sim":
            try await handleSimulationAction(parts: parts, chatKey: chatKey, callback: callback, message: message)

        case "sinspect":
            try await handleInspectChatAction(parts: parts, callback: callback, message: message)

        case "ads":
            try await handleAdCampaignAction(parts: parts, chatKey: chatKey, callback: callback, message: message)

        case "markup":
            try await handleMarkupAction(parts: parts, chatKey: chatKey, callback: callback, message: message)

        case "dailylimit":
            try await handleDailyLimitAction(parts: parts, chatKey: chatKey, callback: callback, message: message)

        case "stars":
            try await handleStarsAdminAction(parts: parts, chatKey: chatKey, callback: callback, message: message)

        case "freemodels":
            try await handleFreeModelsAdminAction(parts: parts, chatKey: chatKey, callback: callback, message: message)

        case "sbal":
            try await handleWalletAdminAction(parts: parts, chatKey: chatKey, callback: callback, message: message)

        case "crypto":
            guard await state.isSuperAdmin(username: invokerKey(callback)) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
                return
            }
            try await handleCryptoAdminAction(parts: parts, chatKey: chatKey, callback: callback, message: message)
            return

        case "card":
            guard await state.isSuperAdmin(username: invokerKey(callback)) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
                return
            }
            try await handleCardAdminAction(parts: parts, chatKey: chatKey, callback: callback, message: message)
            return

        default:
            break
        }
    }

    // MARK: - Markup and the daily premium taste

    private func handleMarkupAction(
        parts: [String],
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard await state.isSuperAdmin(username: invokerKey(callback)) else {
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
            return
        }
        guard parts.count >= 2, parts[1] == "set" else { return }
        await state.setAdminPendingInput(.init(kind: .markupPercent, menuMessageID: message.message_id, payload: nil), chatKey: chatKey)
        let currentPct = await state.markupPercent()
        let markupPrompt = """
        <b>💹 Наценка на цены моделей</b>

        Текущая: <b>\(currentPct)%</b>

        Отправьте число от <code>0</code> до <code>500</code> — процент наценки к ценам провайдера. Применяется ко всем ценам, которые видят пользователи (футер, меню, /model), и к списаниям с балансов.
        """
        let markupMarkup = InlineKeyboardMarkup(inline_keyboard: [[menuButton("❌ Отмена", action: "nav:superadmin")]])
        try await editOrAnswer(callback: callback, message: message, text: markupPrompt, markup: markupMarkup)
    }

    private func handleDailyLimitAction(
        parts: [String],
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard await state.isSuperAdmin(username: invokerKey(callback)) else {
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
            return
        }
        guard parts.count >= 2, parts[1] == "set" else { return }
        await state.setAdminPendingInput(.init(kind: .dailyPremiumLimit, menuMessageID: message.message_id, payload: nil), chatKey: chatKey)
        let currentLimit = await state.dailyPremiumLimit()
        let limitPrompt = """
        <b>🎁 Дневной премиум-вкус (free-tier)</b>

        Текущий лимит: <b>\(currentLimit)</b> умных ответов в день.

        Отправьте число от <code>0</code> до <code>100</code> — сколько ответов платной модели в день получает бесплатный чат (в группе — общий на чат, в личке — на пользователя), прежде чем бот переключится на бесплатную модель и предложит премиум. <code>0</code> — совсем без премиум-вкуса. Бесплатные модели всегда без лимита.
        """
        let limitMarkup = InlineKeyboardMarkup(inline_keyboard: [[menuButton("❌ Отмена", action: "nav:superadmin")]])
        try await editOrAnswer(callback: callback, message: message, text: limitPrompt, markup: limitMarkup)
    }

    func renderSuperAdmin(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
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

        let rows: [[InlineKeyboardButton]] = [
            [menuButton(starsButtonLabel, action: "nav:superstars")],
            [menuButton(cryptoButtonLabel, action: "nav:supercrypto")],
            [menuButton(cardButtonLabel, action: "nav:supercard")],
            [menuButton("🆓 Бесплатные модели · \(freeCount)", action: "nav:superfreemodels")],
            [menuButton("🏢 Тенанты и статистика · \(totalTenants)", action: "nav:supertenants")],
            [menuButton("👁 Чаты бота", action: "nav:superchats"),
             menuButton("📣 Реклама", action: "nav:superads")],
            [menuButton("🛡 Суперадмины", action: "nav:superadmins"),
             menuButton("🎭 Симуляция", action: "nav:supersim")],
            [menuButton("💰 Балансы · \(balances.count)", action: "nav:superbal"),
             menuButton("💹 Наценка · \(markupPct)%", action: "markup:set")],
            [menuButton("🎁 Премиум-лимит/день · \(dailyLimit)", action: "dailylimit:set")],
            [menuButton("⏳ Напоминания и winback · \(reminders.enabled ? "вкл" : "выкл")", action: "nav:superreminders")],
            [menuButton("💡 Примеры-запросы · \(onboarding.enabled ? "\(onboarding.enabledExamples.count)" : "выкл")", action: "nav:superonboarding")],
            [menuButton("🎁 Приглашения · \(referral.enabled ? ReferralConfig.formatUsd(cents: referral.inviterRewardCents) : "выкл")", action: "nav:superref")],
            [menuButton("📊 Воронка и аналитика", action: "nav:superfunnel"),
             menuButton("📈 Источники · \(traffic.campaigns)", action: "nav:supersrc")],
            [menuButton("🪙 Открытые счета · \(openInvoices.count)", action: "crypto:invoices")],
            [menuButton("📋 Общие заготовки · 🤖 Модели", action: "pm:model"),
             menuButton("🎭 Роли", action: "pm:role")],
            [menuButton("🌡 Стили ответа", action: "pm:temp"),
             menuButton("📝 Память", action: "pm:history")],
            [menuButton("ℹ️ Справка по командам", action: "nav:superadminhelp")],
            navButtons(),
        ]

        let text = """
        <b>🛡 Супер-админ</b>

        💫 Stars · \(starsLabel)
        🪙 Крипто · \(cryptoLabel) · режим <b>\(cryptoMode.displayName)</b>
        💳 Карта · \(cardLabel)
        💹 Наценка · <b>\(markupPct)%</b> · /tenant markup
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
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }
}
