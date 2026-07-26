import Foundation

// Super-admin panel: prices, payment methods, free models and ads.

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
            guard await state.isSuperAdmin(username: invokerKey(callback)) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
                return
            }
            guard parts.count >= 2 else { return }
            switch parts[1] {
            case "add":
                guard await state.isRootSuperAdmin(username: invokerKey(callback)) else {
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только главный суперадмин")
                    return
                }
                await state.setAdminPendingInput(.init(kind: .superAdminAdd, menuMessageID: message.message_id, payload: nil), chatKey: chatKey)
                let prompt = "<b>🛡 Добавить суперадмина</b>\n\nОтправьте @username одним сообщением."
                let markup = InlineKeyboardMarkup(inline_keyboard: [[menuButton("❌ Отмена", action: "nav:superadmins")]])
                try await editOrAnswer(callback: callback, message: message, text: prompt, markup: markup)
            case "rm":
                guard await state.isRootSuperAdmin(username: invokerKey(callback)) else {
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только главный суперадмин")
                    return
                }
                guard parts.count >= 3 else { return }
                let target = parts[2]
                let ok = await state.removeSuperAdmin(target: target)
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: ok ? "✓ Удалён" : "Не удалось")
                try await showPage(.superAdmins, chatKey: chatKey, callback: callback, message: message)
            default:
                try await showPage(.superAdmins, chatKey: chatKey, callback: callback, message: message)
            }
            return

        case "stenant":
            guard await state.isSuperAdmin(username: invokerKey(callback)) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
                return
            }
            guard parts.count >= 2 else { return }
            switch parts[1] {
            case "add":
                await state.setAdminPendingInput(.init(kind: .tenantRegister, menuMessageID: message.message_id, payload: nil), chatKey: chatKey)
                let prompt = "<b>🏢 Зарегистрировать тенанта</b>\n\nОтправьте @username одним сообщением."
                let markup = InlineKeyboardMarkup(inline_keyboard: [[menuButton("❌ Отмена", action: "nav:supertenants")]])
                try await editOrAnswer(callback: callback, message: message, text: prompt, markup: markup)
            case "rm":
                // Deleting a tenant throws away a paid subscription, their
                // chats and their guest list — a mis-tap in a list of names
                // must not be able to do that silently.
                guard parts.count >= 3 else { return }
                let target = parts[2]
                let label = await state.displayLabel(forKey: target)
                let row = await state.tenantStats().first { $0.username == target }
                let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy"
                let subLine: String
                if let row {
                    subLine = row.paidUntil.map { "Подписка до <b>\(f.string(from: $0))</b> · чатов <b>\(row.chatCount)</b> · гостей <b>\(row.licensedUserCount)</b>" }
                        ?? "Подписка <b>бессрочная</b> · чатов <b>\(row.chatCount)</b> · гостей <b>\(row.licensedUserCount)</b>"
                } else {
                    subLine = "<i>данных нет</i>"
                }
                let confirmText = """
                <b>🗑 Удалить тенанта \(label)?</b>

                \(subLine)

                ⚠️ Подписка, привязанные чаты и список гостей пропадут. Их чаты вернутся на бесплатные модели. Отменить нельзя — только оформить заново.
                """
                let confirmMarkup = InlineKeyboardMarkup(inline_keyboard: [
                    [menuButton("🗑 Да, удалить", action: "stenant:rmyes:\(target)")],
                    [menuButton("❌ Отмена", action: "nav:supertenants")],
                ])
                try await editOrAnswer(callback: callback, message: message, text: confirmText, markup: confirmMarkup)
            case "rmyes":
                guard parts.count >= 3 else { return }
                let removed = await state.removeTenant(username: parts[2])
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: removed ? "✓ Удалён" : "Нельзя удалить")
                try await showPage(.superTenants, chatKey: chatKey, callback: callback, message: message)
            case "info":
                guard parts.count >= 3 else { return }
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: nil)
                let (text, markup) = await renderSuperTenantInfo(username: parts[2])
                try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)
            case "ext":
                guard parts.count >= 3 else { return }
                if let until = await state.extendTenantSubscription(username: parts[2], days: ChatContextStore.subscriptionDays) {
                    let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy"
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Продлена до \(f.string(from: until))")
                } else {
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Тенант не найден")
                }
                let (text, markup) = await renderSuperTenantInfo(username: parts[2])
                try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)
            case "unlim":
                guard parts.count >= 3 else { return }
                let ok = await state.setTenantUnlimited(username: parts[2])
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: ok ? "✓ Подписка бессрочная" : "Тенант не найден")
                let (text, markup) = await renderSuperTenantInfo(username: parts[2])
                try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)
            case "exp":
                guard parts.count >= 3 else { return }
                let ok = await state.expireTenantSubscription(username: parts[2])
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: ok ? "⛔ Подписка завершена" : "Тенант не найден")
                let (text, markup) = await renderSuperTenantInfo(username: parts[2])
                try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)
            default:
                try await showPage(.superTenants, chatKey: chatKey, callback: callback, message: message)
            }
            return

        case "sim":
            guard await state.isActuallySuperAdmin(username: invokerKey(callback)) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
                return
            }
            guard parts.count >= 2 else { return }
            // Simulation is filed under the same key as the role it shadows.
            let username = invokerKey(callback)
            switch parts[1] {
            case "admin":
                _ = await state.setSimulatedRole(username: username, role: .admin)
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Симуляция: админ")
            case "user":
                _ = await state.setSimulatedRole(username: username, role: .regularUser)
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Симуляция: юзер")
            case "off":
                _ = await state.setSimulatedRole(username: username, role: nil)
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Симуляция выкл")
            case "buy":
                let activation = await state.activatePaidSubscription(username: username)
                await state.assignChat(chatID: chatKey.chatID, to: username.lowercased())
                let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy"
                let note: String
                switch activation {
                case .started(let until): note = "🧪 Tenant создан, подписка до \(f.string(from: until))"
                case .extended(let until): note = "🧪 Подписка продлена до \(f.string(from: until))"
                case .alreadyUnlimited: note = "🧪 У вас бессрочный доступ"
                }
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: note)
            default:
                break
            }
            try await showPage(.superSimulate, chatKey: chatKey, callback: callback, message: message)
            return

        case "sinspect":
            guard await state.isSuperAdmin(username: invokerKey(callback)) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
                return
            }
            guard parts.count >= 2, let targetChatID = Int(parts[1]) else { return }
            let (text, markup) = await renderInspect(chatID: targetChatID)
            try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)
            return

        case "ads":
            guard await state.isSuperAdmin(username: invokerKey(callback)) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
                return
            }
            guard parts.count >= 2 else { return }
            switch parts[1] {
            case "add":
                await state.setAdminPendingInput(.init(kind: .adAddText, menuMessageID: message.message_id, payload: nil), chatKey: chatKey)
                let prompt = """
                <b>📣 Новое объявление</b>

                Отправьте текст объявления одним сообщением (HTML разрешён).
                Частота по умолчанию: каждые 10 ответов, пауза 60 минут. Настроить точнее — /ads.
                """
                let markup = InlineKeyboardMarkup(inline_keyboard: [[menuButton("❌ Отмена", action: "nav:superads")]])
                try await editOrAnswer(callback: callback, message: message, text: prompt, markup: markup)
            case "toggle":
                guard parts.count >= 3 else { return }
                let id = parts[2]
                let enabled = await state.adCampaign(id: id)?.enabled ?? false
                _ = await state.setAdCampaignEnabled(id: id, enabled: !enabled)
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: enabled ? "⏸ Выключена" : "▶️ Включена")
                try await showPage(.superAds, chatKey: chatKey, callback: callback, message: message)
            case "rm":
                guard parts.count >= 3 else { return }
                _ = await state.removeAdCampaign(id: parts[2])
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🗑 Удалена")
                try await showPage(.superAds, chatKey: chatKey, callback: callback, message: message)
            default:
                try await showPage(.superAds, chatKey: chatKey, callback: callback, message: message)
            }
            return

        case "markup":
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
            return

        case "dailylimit":
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
            return

        case "stars":
            guard await state.isSuperAdmin(username: invokerKey(callback)) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
                return
            }
            if parts.count >= 2 {
                switch parts[1] {
                case "setprice":
                    await state.setPendingStarsPriceInput(menuMessageID: message.message_id, chatKey: chatKey)
                    let currentPrice = await state.starsPrice()
                    let currentLabel = currentPrice.map { "\($0) ⭐" } ?? "отключена"
                    let promptText = """
                    <b>💫 Установка цены доступа</b>

                    Текущая цена: <b>\(currentLabel)</b>

                    Введите количество Stars (целое число ≥ 1) или <b>0</b> для отключения продаж.
                    """
                    let markup = InlineKeyboardMarkup(inline_keyboard: [
                        [menuButton("❌ Отмена", action: "nav:superstars")]
                    ])
                    try await editOrAnswer(callback: callback, message: message, text: promptText, markup: markup)
                case "setrate":
                    await state.setPendingStarsPerUsdInput(menuMessageID: message.message_id, chatKey: chatKey)
                    let currentRate = await state.starsPerUsd()
                    let promptText = """
                    <b>💫 Курс кредитов — Stars за $1</b>

                    Текущий: <b>\(currentRate) ⭐ за $1</b>

                    Введите целое число ≥ 1. Ориентир <b>77</b>: Telegram платит разработчику ~$0.013/⭐, \
                    поэтому 77⭐/$ покрывает себестоимость ответа и оставляет маржу (30% сверху берётся при списании). \
                    Меньше — дешевле для покупателя, но режет маржу.
                    """
                    let markup = InlineKeyboardMarkup(inline_keyboard: [
                        [menuButton("❌ Отмена", action: "nav:superstars")]
                    ])
                    try await editOrAnswer(callback: callback, message: message, text: promptText, markup: markup)
                case "disable":
                    await state.setStarsPrice(nil)
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Продажи отключены")
                    try await showPage(.superStars, chatKey: chatKey, callback: callback, message: message)
                default:
                    try await showPage(.superStars, chatKey: chatKey, callback: callback, message: message)
                }
            } else {
                try await showPage(.superStars, chatKey: chatKey, callback: callback, message: message)
            }
            return

        case "freemodels":
            guard await state.isSuperAdmin(username: invokerKey(callback)) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
                return
            }
            if parts.count >= 2 {
                switch parts[1] {
                case "add":
                    await state.setPendingFreeModelInput(menuMessageID: message.message_id, chatKey: chatKey)
                    let promptText = """
                    <b>🆓 Добавить бесплатную модель</b>

                    Введите ID модели (например: <code>openai/gpt-4o-mini</code>)
                    """
                    let markup = InlineKeyboardMarkup(inline_keyboard: [
                        [menuButton("❌ Отмена", action: "nav:superfreemodels")]
                    ])
                    try await editOrAnswer(callback: callback, message: message, text: promptText, markup: markup)
                case "remove":
                    guard parts.count >= 3, let index = Int(parts[2]) else { return }
                    let ids = await state.freeModelIDs()
                    guard index >= 0, index < ids.count else {
                        try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Модель не найдена")
                        return
                    }
                    await state.removeFreeModel(ids[index])
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Удалено")
                    try await showPage(.superFreeModels, chatKey: chatKey, callback: callback, message: message)
                default:
                    try await showPage(.superFreeModels, chatKey: chatKey, callback: callback, message: message)
                }
            } else {
                try await showPage(.superFreeModels, chatKey: chatKey, callback: callback, message: message)
            }
            return

        case "sbal":
            guard await state.isSuperAdmin(username: invokerKey(callback)) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
                return
            }
            guard parts.count >= 2 else { return }
            switch parts[1] {
            case "add":
                await state.setAdminPendingInput(.init(kind: .balanceTopUp, menuMessageID: message.message_id, payload: nil), chatKey: chatKey)
                let prompt = """
                <b>💰 Начислить / списать баланс</b>

                Отправьте одним сообщением: <code>@username сумма</code>

                <i>Пример:</i> <code>@user 5</code> — начислить $5
                Отрицательная сумма — списать. Кошелёк создаётся автоматически.
                """
                let markup = InlineKeyboardMarkup(inline_keyboard: [[menuButton("❌ Отмена", action: "nav:superbal")]])
                try await editOrAnswer(callback: callback, message: message, text: prompt, markup: markup)
            case "rm":
                // The wallet holds money the person paid for: confirm before
                // it disappears from a one-tap row in a list.
                guard parts.count >= 3 else { return }
                let target = parts[2]
                let label = await state.displayLabel(forKey: target)
                let wallet = await state.balance(username: target)
                let amount = wallet.map { String(format: "$%.4f", $0.balanceUsd) } ?? "—"
                let confirmText = """
                <b>🗑 Удалить кошелёк \(label)?</b>

                Остаток · <b>\(amount)</b>

                ⚠️ Остаток пропадёт вместе с историей списаний. Если человек пополнял баланс деньгами, это его деньги. Отменить нельзя.
                """
                let confirmMarkup = InlineKeyboardMarkup(inline_keyboard: [
                    [menuButton("🗑 Да, удалить", action: "sbal:rmyes:\(target)")],
                    [menuButton("❌ Отмена", action: "nav:superbal")],
                ])
                try await editOrAnswer(callback: callback, message: message, text: confirmText, markup: confirmMarkup)
            case "rmyes":
                guard parts.count >= 3 else { return }
                let removed = await state.removeBalance(username: parts[2])
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: removed ? "✓ Кошелёк удалён" : "Кошелёк не найден")
                try await showPage(.superBalances, chatKey: chatKey, callback: callback, message: message)
            default:
                try await showPage(.superBalances, chatKey: chatKey, callback: callback, message: message)
            }
            return

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
