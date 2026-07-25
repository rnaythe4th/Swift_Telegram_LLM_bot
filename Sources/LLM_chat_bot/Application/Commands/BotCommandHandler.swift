import Foundation

final class BotCommandHandler: @unchecked Sendable {
    private let telegram: TelegramGatewayPort
    private let state: ChatContextStore
    private let gateways: ProviderGatewayRegistry
    private let botUsername: String
    private let formatOptions: String
    private let menuHandler: BotMenuHandler
    private let modelPriceMonitor: ModelPriceMonitor?
    private let cryptoService: CryptoPaymentService?
    private let reminderService: SubscriptionReminderService?

    init(
        telegram: TelegramGatewayPort,
        state: ChatContextStore,
        gateways: ProviderGatewayRegistry,
        botUsername: String,
        formatOptions: String,
        menuHandler: BotMenuHandler,
        modelPriceMonitor: ModelPriceMonitor? = nil,
        cryptoService: CryptoPaymentService? = nil,
        reminderService: SubscriptionReminderService? = nil
    ) {
        self.telegram = telegram
        self.state = state
        self.gateways = gateways
        self.botUsername = botUsername
        self.formatOptions = formatOptions
        self.menuHandler = menuHandler
        self.modelPriceMonitor = modelPriceMonitor
        self.cryptoService = cryptoService
        self.reminderService = reminderService
    }

    func handleIfCommand(text: String?, chatKey: ChatKey, fromUser: TelegramUser?, isPrivate: Bool) async throws -> Bool {
        guard let text else {
            return false
        }

        // The test-mode suffix disambiguates multiple bot copies inside one group.
        // Private chats only ever talk to a single copy, so commands must work
        // bare (`/menu`) regardless of any inherited default suffix.
        let suffix = isPrivate ? nil : await state.suffix(chatKey: chatKey)

        let parsed = ParsedBotCommand.parse(
            from: text,
            botUsername: botUsername,
            suffix: suffix
        )

        guard parsed.name != .unknown, parsed.name != .mention else {
            return false
        }

        try await handle(parsed, chatKey: chatKey, fromUser: fromUser)
        return true
    }

    private func isSuperAdmin(_ user: TelegramUser?) async -> Bool {
        await state.isSuperAdmin(username: user?.username)
    }

    private func isAdmin(_ user: TelegramUser?, chatID: Int) async -> Bool {
        await state.isAdmin(username: user?.username, chatID: chatID)
    }

    private func requireAdmin(_ user: TelegramUser?, chatKey: ChatKey) async throws -> Bool {
        guard await isAdmin(user, chatID: chatKey.chatID) else {
            try await sendUserFeedback(chatKey: chatKey, text: "🔒 Команда только для администратора.")
            return false
        }
        return true
    }

    private func handle(_ parsed: ParsedBotCommand, chatKey: ChatKey, fromUser: TelegramUser?) async throws {
        switch parsed.name {
        case .whitelist:
            guard try await requireAdmin(fromUser, chatKey: chatKey) else { return }
            try await handleWhitelist(chatKey: chatKey, argument: parsed.argument)

        case .defaults:
            guard try await requireAdmin(fromUser, chatKey: chatKey) else { return }
            try await handleDefaults(chatKey: chatKey, argument: parsed.argument)

        case .chats:
            guard try await requireAdmin(fromUser, chatKey: chatKey) else { return }
            try await handleChats(chatKey: chatKey, fromUser: fromUser)

        case .users:
            guard try await requireAdmin(fromUser, chatKey: chatKey) else { return }
            try await handleUsers(chatKey: chatKey, fromUser: fromUser)

        case .presets:
            guard try await requireAdmin(fromUser, chatKey: chatKey) else { return }
            try await handlePresets(chatKey: chatKey, argument: parsed.argument)

        case .tenant:
            guard await isAdmin(fromUser, chatID: chatKey.chatID) else {
                try await sendUserFeedback(chatKey: chatKey, text: "🔒 Команда только для администратора.")
                return
            }
            try await handleTenant(chatKey: chatKey, argument: parsed.argument, fromUser: fromUser)

        case .superadmin:
            guard await state.isRootSuperAdmin(username: fromUser?.username) else {
                try await sendUserFeedback(chatKey: chatKey, text: "🔒 Команда только для главного суперадмина.")
                return
            }
            try await handleSuperAdminCmd(chatKey: chatKey, argument: parsed.argument)

        case .buy:
            try await handleBuy(chatKey: chatKey, fromUser: fromUser)

        case .simulate:
            guard await state.isActuallySuperAdmin(username: fromUser?.username) else {
                try await sendUserFeedback(chatKey: chatKey, text: "🔒 Команда только для суперадминистратора.")
                return
            }
            try await handleSimulate(chatKey: chatKey, fromUser: fromUser, argument: parsed.argument)

        case .start:
            try await handleStart(chatKey: chatKey, argument: parsed.argument, fromUser: fromUser)

        case .chatid:
            try await handleChatID(chatKey: chatKey)

        case .inspect:
            guard await isSuperAdmin(fromUser) else {
                try await sendUserFeedback(chatKey: chatKey, text: "🔒 Команда только для суперадминистратора.")
                return
            }
            try await handleInspect(chatKey: chatKey, argument: parsed.argument)

        case .ads:
            guard await isSuperAdmin(fromUser) else {
                try await sendUserFeedback(chatKey: chatKey, text: "🔒 Команда только для суперадминистратора.")
                return
            }
            try await handleAds(chatKey: chatKey, argument: parsed.argument)

        case .balance:
            try await handleBalance(chatKey: chatKey, argument: parsed.argument, fromUser: fromUser)

        case .reminders:
            guard await isSuperAdmin(fromUser) else {
                try await sendUserFeedback(chatKey: chatKey, text: "🔒 Команда только для суперадминистратора.")
                return
            }
            try await handleReminders(chatKey: chatKey, argument: parsed.argument, fromUser: fromUser)

        case .examples:
            try await handleExamples(chatKey: chatKey, argument: parsed.argument, fromUser: fromUser)

        case .referral:
            try await handleReferral(chatKey: chatKey, argument: parsed.argument, fromUser: fromUser)

        case .setRole:
            let trimmed = parsed.argument.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: """
                    🎭 Опишите, кем должен быть бот.
                    <i>Пример:</i> <code>/setrole Ты — эксперт по математике, отвечай кратко.</code>
                    """)
                return
            }
            _ = await state.setRoleAndResetHistory(chatKey: chatKey, role: trimmed + formatOptions)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Роль обновлена. Переписка очищена.")

        case .clearHistory:
            await state.clearHistory(chatKey: chatKey)
            try await sendUserFeedback(chatKey: chatKey, text: "🧹 Переписка очищена — бот забыл, о чём был разговор.")

        case .setTemp:
            guard let temp = Float(parsed.argument), (0.0...2.0).contains(temp) else {
                let hint = "<i>Нужно число от 0.0 (строго по фактам) до 2.0 (творчески).</i>\n<i>Пример:</i> <code>/settemp 1.0</code>"
                try await sendUserFeedback(chatKey: chatKey, text: hint)
                return
            }
            await state.setTemperature(chatKey: chatKey, value: temp)
            let bucket = BotMenuHandler.tempBucket(temp)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Стиль ответа: <b>\(bucket)</b> (\(BotMenuHandler.formatTemp(temp)))")

        case .model:
            let trimmed = parsed.argument.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: """
                    🤖 Укажите название модели.
                    <i>Пример:</i> <code>/model openai/gpt-4o</code>
                    <i>Через конкретный сервис:</i> <code>/model deepseek/deepseek-v4-pro | deepseek</code>
                    Готовые варианты — /menu → 🤖 Модель
                    """)
                return
            }
            // Optional second part after "|": OpenRouter upstream provider pin.
            let modelParts = trimmed.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let modelID = modelParts[0]
            let providerRouting = modelParts.count > 1 && !modelParts[1].isEmpty ? modelParts[1] : nil
            guard !modelID.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "⚠️ Укажите модель перед <code>|</code>.")
                return
            }
            // A free-tier chat may still pick a paid model while today's premium
            // taste has units left — the cap enforces itself at generation time.
            let access = await state.paidModelAccess(username: fromUser?.username, userID: fromUser?.id, chatID: chatKey.chatID)
            let effectiveFree = await state.effectiveFreeModelIDs()
            let isPaidModel = effectiveFree.map { !$0.contains(modelID) } ?? false
            if isPaidModel, case .none = access {
                let price = await state.starsPrice()
                let buyHint = price.map { "\n\nОткрыть премиум для этого чата (\($0) ⭐) — /buy, или пополните баланс и платите за ответы — /balance" } ?? "\n\nОткрыть премиум для этого чата — /buy, или пополните баланс и платите за ответы — /balance"
                try await sendUserFeedback(chatKey: chatKey, text: "⭐ <b>\(modelID)</b> — платная модель.\(buyHint)")
                return
            }
            let changed = await state.setModelAndResetHistory(chatKey: chatKey, newModel: modelID, providerRouting: providerRouting)
            if modelPriceMonitor != nil {
                await modelPriceMonitor?.refreshPricesIfNeeded(for: modelID)
            }
            var priceNote = ""
            if let price = await state.openRouterModelPrice(for: modelID) {
                let multiplier = await state.priceMultiplier()
                let inP = BotMenuHandler.formatPriceM(price.inputPerToken * multiplier)
                let outP = BotMenuHandler.formatPriceM(price.outputPerToken * multiplier)
                priceNote = "\n⬇️$\(inP)/M · ⬆️$\(outP)/M"
            }
            let providerNote = providerRouting.map { "\nСервис: <code>\($0)</code>" } ?? ""
            // Say the daily ceiling out loud: on a free tier this model answers
            // N times today and then falls back on its own.
            var tasteNote = ""
            if isPaidModel, case .dailyTaste(let remaining, let limit) = access {
                tasteNote = "\n🚦 Умных ответов сегодня: <b>\(remaining) из \(limit)</b>, дальше отвечаю на бесплатной."
            }
            try await sendUserFeedback(chatKey: chatKey, text: """
                ✓ Модель: <code>\(changed.new)</code>\(providerNote)
                <i>Была:</i> <code>\(changed.old)</code>
                Переписка очищена.\(priceNote)\(tasteNote)
                """)

        case .showTokens:
            let new = await state.toggleShowStats(chatKey: chatKey)
            try await sendUserFeedback(chatKey: chatKey, text: "📊 Объём текста под ответом · <b>\(onOff(new))</b>")

        case .showCost:
            let new = await state.toggleShowCost(chatKey: chatKey)
            try await sendUserFeedback(chatKey: chatKey, text: "💵 Стоимость под ответом · <b>\(onOff(new))</b>")

        case .showModel:
            let new = await state.toggleShowModel(chatKey: chatKey)
            try await sendUserFeedback(chatKey: chatKey, text: "🤖 Название модели под ответом · <b>\(onOff(new))</b>")

        case .backupNotify:
            let new = await state.toggleBackupNotify(chatKey: chatKey)
            try await sendUserFeedback(chatKey: chatKey, text: "💾 Отчёты о сохранении · <b>\(onOff(new))</b>")

        case .help:
            let markup = InlineKeyboardMarkup(inline_keyboard: [
                [InlineKeyboardButton(text: "⚙️ Открыть меню", callback_data: BotCallbackAction.menu(action: "open").rawData)],
            ])
            _ = try await telegram.sendMessage(.init(
                chatID: chatKey.chatID,
                threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                replyTo: nil,
                text: BotCallbackHandler.faqText,
                replyMarkup: markup
            ))

        case .defaultRole:
            let defaultRole = await state.defaultRole(chatID: chatKey.chatID)
            _ = await state.setRoleAndResetHistory(chatKey: chatKey, role: defaultRole)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Роль сброшена к стандартной. Переписка очищена.")

        case .historyLength:
            guard let newMax = Int(parsed.argument), (1...50).contains(newMax) else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Нужно число от 1 до 50 — сколько прошлых сообщений бот держит в голове.</i>\n<i>Пример:</i> <code>/historylength 11</code>")
                return
            }
            await state.setMaxHistory(chatKey: chatKey, newMax: newMax)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Память: <b>\(newMax) сообщ.</b>")

        case .provider:
            if let provider = ServiceProvider.parse(parsed.argument) {
                let old = await state.changeProvider(chatKey: chatKey, newProvider: provider)
                var lines = ["✓ Сервис ИИ: <b>\(provider.commandValue)</b>"]
                if old != provider {
                    lines.append("<i>Был:</i> <b>\(old.commandValue)</b>")
                }

                let gateway = try gateways.gateway(for: provider)
                let reasoningEnabled = await state.reasoningEnabled(chatKey: chatKey)
                if reasoningEnabled, !gateway.capabilities.supportsReasoning {
                    await state.setReasoningEffort(chatKey: chatKey, effort: nil)
                    lines.append("<i>Обдумывание выключено — этот сервис его не умеет.</i>")
                }
                try await sendUserFeedback(chatKey: chatKey, text: lines.joined(separator: "\n"))
            } else {
                try await sendUserFeedback(chatKey: chatKey, text: "Неизвестный сервис. Доступны: <code>deepseek</code>, <code>openrouter</code>, <code>yandex</code>.")
            }

        case .testMode:
            let suffix = await state.toggleTestMode(chatKey: chatKey)
            if let suffix {
                try await sendUserFeedback(chatKey: chatKey, text: """
                    🧪 <b>Тест-режим включён.</b>
                    Суффикс · <code>\(suffix)</code>

                    Используйте суффикс с командами:
                    <code>/help\(suffix)</code>
                    <code>/setrole\(suffix) Ты — Дональд Трамп.</code>
                    """)
            } else {
                try await sendUserFeedback(chatKey: chatKey, text: "🧪 Тест-режим выключен.")
            }

        case .reasoning:
            let provider = await state.provider(chatKey: chatKey)
            let gateway = try gateways.gateway(for: provider)

            guard gateway.capabilities.supportsReasoning else {
                try await sendUserFeedback(
                    chatKey: chatKey,
                    text: "🧠 Сервис <b>\(provider.commandValue)</b> не умеет обдумывать ответ. Смените его в /menu → 🔌 Сервис ИИ."
                )
                return
            }

            let arg = parsed.argument.trimmingCharacters(in: .whitespaces).lowercased()
            if let effort = ReasoningEffort(userInput: arg) {
                await state.setReasoningEffort(chatKey: chatKey, effort: effort)
            } else if arg == "off" || arg == "выкл" {
                await state.setReasoningEffort(chatKey: chatKey, effort: nil)
            } else if arg.isEmpty {
                _ = await state.toggleReasoning(chatKey: chatKey)
            } else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Как пользоваться:</i> <code>/reasoning быстро|средне|глубоко|выкл</code>")
                return
            }
            let current = await state.reasoningEffort(chatKey: chatKey)
            try await sendUserFeedback(chatKey: chatKey, text: "🧠 Обдумывание · <b>\(current?.displayName ?? "выключено")</b>")

        case .menu:
            await menuHandler.sendMenu(chatKey: chatKey, userID: fromUser?.id, username: fromUser?.username)

        case .reset:
            await state.resetChat(chatKey: chatKey)
            try await sendUserFeedback(chatKey: chatKey, text: "↺ Настройки сброшены к стандартным.")

        case .resetStats:
            await state.resetUsage(chatKey: chatKey)
            try await sendUserFeedback(chatKey: chatKey, text: "🗑 Статистика этого чата сброшена.")

        case .history:
            try await handleHistory(chatKey: chatKey)

        case .mention, .unknown:
            return
        }
    }

    private func handleStart(chatKey: ChatKey, argument: String, fromUser: TelegramUser?) async throws {
        if chatKey.chatID > 0 {
            // Funnel: `.start` means a person opened the bot. A group hitting
            // /start is the `?startgroup=` link replaying the join, which the
            // funnel already counts as `.addedToGroup`.
            await state.bumpFunnel(.start)
        } else {
            // The `?startgroup=` replay carries the adder, so a paying sponsor
            // claims their new group even if the join event went missing.
            await state.autoAssignIfNeeded(
                chatID: chatKey.chatID,
                senderUsername: fromUser?.username,
                senderUserID: fromUser?.id
            )
        }
        // Deep-link invite: t.me/<bot>?start=inv_<token> — grants paid-model
        // access under the issuing admin's licence.
        let payload = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        if payload.hasPrefix("inv_") {
            try await handleInviteRedemption(token: String(payload.dropFirst(4)), chatKey: chatKey, fromUser: fromUser)
            return
        }
        // Two-sided referral: t.me/<bot>?start=ref_<userID> (roadmap step 10).
        if let inviterUserID = ReferralLink.inviterUserID(payload: payload) {
            try await handleReferralStart(inviterUserID: inviterUserID, chatKey: chatKey, fromUser: fromUser)
            return
        }
        try await sendStartGreeting(chatKey: chatKey)
    }

    /// Attributes a new user to their inviter, then greets as usual. Nothing is
    /// paid here — the reward lands after the invited user's first real answer
    /// (see `GenerationCoordinator`), which is what keeps farming pointless.
    private func handleReferralStart(inviterUserID: Int, chatKey: ChatKey, fromUser: TelegramUser?) async throws {
        // Referral links are personal: attribution only makes sense in the DM
        // the link opens.
        guard let user = fromUser, chatKey.chatID > 0 else {
            try await sendStartGreeting(chatKey: chatKey)
            return
        }

        let config = await state.referralConfig()
        let outcome = await state.bindReferral(
            invitedUserID: user.id,
            invitedUsername: user.username,
            inviterUserID: inviterUserID
        )

        var note: String?
        switch outcome {
        case .bound(let inviter, let inviteeReward):
            if config.paysAnything {
                note = String(
                    format: "🎁 <b>Вас пригласил %@.</b>\n\nЗадайте первый вопрос — и на ваш баланс придёт <b>$%.2f</b> (пригласившему — $%.2f).\n\nПока баланс не пуст, вам доступны любые модели без подписки: с него списывается стоимость каждого ответа, обычно доли цента.",
                    inviter, inviteeReward, config.inviterRewardUsd
                )
            } else {
                note = "🎁 Вы пришли по приглашению <b>\(inviter)</b>. Просто напишите вопрос — отвечу."
            }

        case .boundWithoutReward(let inviter):
            // Honest instead of silent: the attribution stands, but the
            // inviter is out of paid invites, so no money is promised.
            note = "🎁 Вы пришли по приглашению <b>\(inviter)</b>. Бонус за это приглашение уже исчерпан, но бот работает как обычно — просто напишите вопрос. Своя ссылка с бонусом — /ref"

        case .alreadyBound(let inviter):
            note = "ℹ️ Вас уже пригласил <b>\(inviter)</b> — бонус за приглашение даётся только один раз."

        case .selfInvite:
            note = "🙂 Это ваша собственная ссылка — себя пригласить нельзя. Отправьте её друзьям: /ref"

        case .notNewUser:
            note = "ℹ️ Бонус за приглашение получают только те, кто раньше боту не писал. Зато приглашать можете вы сами: /ref"

        case .unknownInviter:
            note = "⚠️ Ссылка не сработала: тот, кто её прислал, ещё ни разу не писал этому боту."

        case .disabled:
            note = nil
        }

        if let note {
            try await sendUserFeedback(chatKey: chatKey, text: note)
        }
        try await sendStartGreeting(chatKey: chatKey)
    }

    // MARK: - Referral (roadmap step 10)

    /// `/ref` — personal invite link for everyone; super-admins additionally get
    /// the program switches, so it is controllable without the menu.
    private func handleReferral(chatKey: ChatKey, argument: String, fromUser: TelegramUser?) async throws {
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
                guard parts.count >= 2,
                      let usd = Double(parts[1].replacingOccurrences(of: ",", with: ".")), usd >= 0 else {
                    try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/ref \(subcommand) 1</code> — сумма в долларах, <code>0</code> — не платить.")
                    return
                }
                let cents = Int((usd * 100).rounded())
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
                lines.append(String(format: "Выплачено всего · <b>$%.2f</b> · пригласивших · <b>%d</b>", overview.paidOutUsd, overview.inviters))
                lines.append("Переходов по ссылке · <b>\(report.count(.referralJoined))</b> · наград · <b>\(report.count(.referralRewarded))</b>")
                if overview.refusedTotal > 0 {
                    lines.append("Не засчитано переходов · <b>\(overview.refusedTotal)</b> · сам себя \(overview.refusedSelf) · уже приглашён \(overview.refusedRepeat) · не новый \(overview.refusedNotNew) · автор неизвестен \(overview.refusedUnknown)")
                }
                if !overview.top.isEmpty {
                    lines.append("")
                    lines.append("<b>Топ пригласивших</b>")
                    for (index, entry) in overview.top.enumerated() {
                        // The tally label already carries its own `@`.
                        lines.append(String(
                            format: "%d. %@ · оплатили %d · наград %d · $%.2f · привязок %d",
                            index + 1, entry.tally.username, entry.tally.paidConversions,
                            entry.tally.rewarded, entry.tally.earnedUsd, entry.tally.invited
                        ))
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
        guard chatKey.chatID > 0 else {
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

    private func handleInviteRedemption(token: String, chatKey: ChatKey, fromUser: TelegramUser?) async throws {
        guard let owner = await state.redeemInvite(token: token) else {
            try await sendUserFeedback(chatKey: chatKey, text: """
                ⚠️ Ссылка не работает — она устарела или премиум-доступ пригласившего уже закончился.
                Попросите у него новую.
                """)
            try await sendStartGreeting(chatKey: chatKey)
            return
        }

        let ownerLabel = await state.displayLabel(forKey: owner)
        if await state.userKey(username: fromUser?.username) == owner {
            try await sendUserFeedback(chatKey: chatKey, text: "ℹ️ Это ваша собственная пригласительная ссылка — доступ у вас и так есть.")
            return
        }

        var grantedLines: [String] = []
        if let visitorID = fromUser?.id {
            // Filed under the visitor's account, so the grant survives a rename
            // and works for someone who never set a @username.
            _ = await state.addLicensedUser(ownerUsername: owner, target: state.userKey(userID: visitorID))
            grantedLines.append("• платные модели доступны вам во всех чатах с этим ботом")
        }
        // Private chat: attach it to the inviter's licence too, so access holds
        // even if the guest list is later cleared.
        if chatKey.chatID > 0, await state.chatOwner(chatID: chatKey.chatID) == nil {
            _ = await state.assignChat(chatID: chatKey.chatID, to: owner)
            grantedLines.append("• в этом чате премиум работает за счёт \(ownerLabel)")
        }

        guard !grantedLines.isEmpty else {
            try await sendUserFeedback(chatKey: chatKey, text: """
                ⚠️ Приглашение не сработало: в этом чате премиум уже открыт другим спонсором.
                Откройте ссылку в личке с ботом.
                """)
            return
        }

        try await sendUserFeedback(chatKey: chatKey, text: """
            🎟 <b>Приглашение от \(ownerLabel) активировано!</b>

            \(grantedLines.joined(separator: "\n"))

            Просто напишите сообщение — бот ответит. Настройки: /menu
            """)
    }

    private func handleChatID(chatKey: ChatKey) async throws {
        let ownerLabel = await state.chatOwnerLabel(chatID: chatKey.chatID)
        let meta = await state.chatMeta(chatID: chatKey.chatID)
        var lines = ["<b>🆔 Этот чат</b>", ""]
        lines.append("ID · <code>\(chatKey.chatID)</code>")
        if chatKey.threadID != 0 {
            lines.append("Тема · <code>\(chatKey.threadID)</code>")
        }
        if let meta {
            lines.append("Тип · \(meta.type)" + (meta.title.map { " · «\($0)»" } ?? ""))
        }
        lines.append(ownerLabel.map { "Премиум · открыл \($0)" } ?? "Премиум · <i>здесь не открыт</i>")
        lines.append("")
        lines.append("<i>Если премиум есть у вас — включить его в этом чате: /tenant claim</i>")
        try await sendUserFeedback(chatKey: chatKey, text: lines.joined(separator: "\n"))
    }

    private func handleInspect(chatKey: ChatKey, argument: String) async throws {
        let parts = argument.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first, let targetChatID = Int(first) else {
            try await sendUserFeedback(chatKey: chatKey, text: """
                <b>👁 Инспекция чата</b>

                <code>/inspect &lt;chatID&gt;</code> — настройки и роль чата
                Список чатов с ID — /chats, либо /menu → Супер-админ → 👁 Чаты
                """)
            return
        }

        let label = await state.chatDisplayLabel(chatID: targetChatID)
        let owner = await state.chatOwnerLabel(chatID: targetChatID)
        let keys = await state.existingContextKeys(chatID: targetChatID)

        guard !keys.isEmpty else {
            try await sendUserFeedback(chatKey: chatKey, text: "Чат <code>\(targetChatID)</code> ещё не общался с ботом.")
            return
        }

        var lines = ["<b>👁 \(label)</b> · <code>\(targetChatID)</code>"]
        lines.append(owner.map { "Премиум · \($0)" } ?? "Премиум · <i>нет (бесплатный)</i>")

        for key in keys.prefix(6) {
            guard let help = await state.peekHelp(chatKey: key) else { continue }
            lines.append("")
            lines.append(key.threadID == 0 ? "<b>Основной тред</b>" : "<b>Топик \(key.threadID)</b>")
            lines.append("🤖 <code>\(help.model)</code> · 🌡 \(BotMenuHandler.formatTemp(help.temp)) · 📝 \(help.maxHistory)")
            let realStr = String(format: "$%.4f", help.cumulativeUsage.totalCost)
            let billedStr = String(format: "$%.4f", await state.billedCost(of: help.cumulativeUsage))
            lines.append("📈 запросов \(help.cumulativeUsage.generationCount) · токенов \(Int(help.cumulativeUsage.totalTokens)) · реально \(realStr) · клиентам \(billedStr)")
            let rolePreview = help.role.count > 300 ? String(help.role.prefix(300)) + "…" : help.role
            lines.append("🎭 <blockquote expandable>\(rolePreview)</blockquote>")
        }
        if keys.count > 6 {
            lines.append("\n<i>…и ещё \(keys.count - 6) топиков</i>")
        }

        try await sendUserFeedback(chatKey: chatKey, text: lines.joined(separator: "\n"))
    }

    private func sendStartGreeting(chatKey: ChatKey) async throws {
        // A group reaching /start is almost always Telegram replaying the
        // `?startgroup=` link as `/start <payload>` right after the join. The
        // DM copy ("напишите мне", "добавить в свой чат") makes no sense there,
        // and `claimGroupGreeting` inside makes sure the join event and this
        // message produce exactly one welcome between them.
        if chatKey.chatID < 0 {
            try await sendGroupWelcome(chatID: chatKey.chatID)
            return
        }

        var text = """
        <b>👋 Привет!</b> Я — умный ИИ-ассистент в Telegram.

        Напишите мне — отвечу. Понимаю текст, фото, голос и видео, помню разговор.

        <b>Хотите умного ИИ в свой групповой чат?</b> Меня можно добавить — премиум откроет любой участник, и доступ заработает сразу для всех.

        ⚙️ /menu · 📘 /help
        """
        var rows: [[InlineKeyboardButton]] = []

        // Onboarding (roadmap step 9): ready-made prompts turn the empty chat
        // after /start — the biggest drop-off point — into one tap to value.
        let onboarding = await state.onboardingConfig()
        let exampleRows = OnboardingPresenter.exampleRows(onboarding, inGroup: false)
        if !exampleRows.isEmpty {
            text += "\n\n" + OnboardingPresenter.invitation
            rows.append(contentsOf: exampleRows)
            await state.bumpFunnel(.onboardingShown)
        }

        // Viral loop entry: one tap opens Telegram's group picker and adds the
        // bot; the group-entry greeting then pitches premium to the owner.
        if !botUsername.isEmpty {
            rows.append([InlineKeyboardButton(text: "➕ Добавить в свой чат", url: "https://t.me/\(botUsername)?startgroup=add")])
        }
        rows.append([InlineKeyboardButton(text: "⚙️ Открыть меню", callback_data: BotCallbackAction.menu(action: "open").rawData)])
        rows.append([InlineKeyboardButton(text: "📘 Инструкция", callback_data: BotCallbackAction.faq.rawData)])
        let markup = InlineKeyboardMarkup(inline_keyboard: rows)
        _ = try await telegram.sendMessage(.init(
            chatID: chatKey.chatID,
            threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
            replyTo: nil,
            text: text,
            replyMarkup: markup
        ))
    }

    /// Group welcome (roadmap step 4). Mirrors `BotOrchestrator.sendGroupWelcome`
    /// through the same presenter and the same one-shot claim, so whichever of
    /// the two paths lands first is the one that posts.
    private func sendGroupWelcome(chatID: Int) async throws {
        guard await state.claimGroupGreeting(chatID: chatID) else { return }
        let sponsor = await state.chatSponsor(chatID: chatID, askerUsername: nil)
        let welcome = GroupWelcomePresenter.welcome(
            sponsor: sponsor,
            onboarding: await state.onboardingConfig()
        )
        if welcome.showsExamples {
            await state.bumpFunnel(.onboardingShown)
        }
        _ = try await telegram.sendMessage(.init(
            chatID: chatID,
            threadID: nil,
            replyTo: nil,
            text: welcome.text,
            replyMarkup: welcome.markup
        ))
    }

    // MARK: - Onboarding examples (roadmap step 9)

    /// `/examples` — re-sends the ready-made prompt buttons to anyone (the
    /// greeting scrolls away fast). Super-admins get the same switches the
    /// super-menu page has, so the feature is controllable without the UI.
    private func handleExamples(chatKey: ChatKey, argument: String, fromUser: TelegramUser?) async throws {
        let parts = argument.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let subcommand = (parts.first ?? "").lowercased()
        let isSuper = await isSuperAdmin(fromUser)

        if isSuper, !subcommand.isEmpty {
            var config = await state.onboardingConfig()
            switch subcommand {
            case "on", "off":
                config.enabled = subcommand == "on"
                await state.setOnboardingConfig(config)
                try await sendUserFeedback(chatKey: chatKey, text: "✓ Примеры в приветствии: <b>\(onOff(config.enabled))</b>")
                return
            case "groups":
                config.showInGroups.toggle()
                await state.setOnboardingConfig(config)
                try await sendUserFeedback(chatKey: chatKey, text: "✓ Примеры в приветствии группы: <b>\(onOff(config.showInGroups))</b>")
                return
            case "reset":
                await state.resetOnboardingExamplesToDefaults()
                try await sendUserFeedback(chatKey: chatKey, text: "✓ Стандартный набор примеров восстановлен.")
                return
            case "clearstats":
                await state.resetOnboardingTapStats()
                try await sendUserFeedback(chatKey: chatKey, text: "✓ Счётчики тапов обнулены.")
                return
            case "stats":
                let fresh = await state.onboardingConfig()
                var lines = ["<b>💡 Примеры-запросы · статистика</b>", ""]
                lines.append("Статус · <b>\(onOff(fresh.enabled))</b> · в группах · <b>\(onOff(fresh.showInGroups))</b>")
                if fresh.examples.isEmpty {
                    lines.append("<i>Список пуст.</i>")
                } else {
                    for example in fresh.examples {
                        lines.append("\(example.enabled ? "🟢" : "⚪️") \(OnboardingPresenter.escape(example.label)) · \(example.placement.shortLabel) · тапов <b>\(example.taps)</b> · <code>\(example.id)</code>")
                    }
                }
                lines.append("")
                lines.append("<i>Редактирование — /menu → 🛡 Супер-админ → 💡 Примеры-запросы</i>")
                try await sendUserFeedback(chatKey: chatKey, text: lines.joined(separator: "\n"))
                return
            default:
                try await sendUserFeedback(chatKey: chatKey, text: """
                    <b>💡 Примеры-запросы</b>

                    <code>/examples</code> — показать примеры
                    <code>/examples stats</code> — тапы и размещение по каждому примеру
                    <code>/examples on|off</code> — показывать в приветствии
                    <code>/examples groups</code> — показывать при входе в группу
                    <code>/examples reset</code> — вернуть стандартный набор
                    <code>/examples clearstats</code> — обнулить счётчики

                    Тексты, порядок и размещение (личка / группы / везде) правятся кнопками: /menu → 🛡 Супер-админ → 💡 Примеры-запросы
                    """)
                return
            }
        }

        let onboarding = await state.onboardingConfig()
        let rows = OnboardingPresenter.exampleRows(onboarding, inGroup: chatKey.chatID < 0)
        guard !rows.isEmpty else {
            try await sendUserFeedback(chatKey: chatKey, text: "Готовых примеров сейчас нет — просто напишите свой вопрос, я отвечу.")
            return
        }
        _ = try await telegram.sendMessage(.init(
            chatID: chatKey.chatID,
            threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
            replyTo: nil,
            text: OnboardingPresenter.invitation,
            replyMarkup: InlineKeyboardMarkup(inline_keyboard: rows)
        ))
        await state.bumpFunnel(.onboardingShown)
    }

    private func onOff(_ v: Bool) -> String { v ? "вкл" : "выкл" }

    // MARK: - Balance (pay-as-you-go)

    private func handleBalance(chatKey: ChatKey, argument: String, fromUser: TelegramUser?) async throws {
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

    // MARK: - Renewal reminders & winback (superadmin, roadmap step 8)

    private func handleReminders(chatKey: ChatKey, argument: String, fromUser: TelegramUser?) async throws {
        let parts = argument.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        let subcommand = (parts.first ?? "").lowercased()
        let rest = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        var config = await state.reminderConfig()

        switch subcommand {
        case "":
            try await sendUserFeedback(chatKey: chatKey, text: await remindersStatusText(config: config))

        case "on", "off":
            config.enabled = subcommand == "on"
            await state.setReminderConfig(config)
            try await sendUserFeedback(chatKey: chatKey, text: config.enabled
                ? "✓ Напоминания и winback включены."
                : "✓ Напоминания и winback выключены.")

        case "chats":
            let value = rest.lowercased()
            guard value == "on" || value == "off" else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/reminders chats on|off</code>")
                return
            }
            config.notifyChats = value == "on"
            await state.setReminderConfig(config)
            try await sendUserFeedback(chatKey: chatKey, text: config.notifyChats
                ? "✓ Уведомления пойдут и в чаты спонсора (продлить сможет любой участник)."
                : "✓ Уведомления только в личку спонсора.")

        case "days":
            if rest == "-" || rest == "0" || rest.lowercased() == "off" {
                config.expiryReminderDays = []
                await state.setReminderConfig(config)
                try await sendUserFeedback(chatKey: chatKey, text: "✓ Напоминания до истечения выключены (winback остался).")
                return
            }
            let parsedDays = rest
                .split(whereSeparator: { ",; ".contains($0) })
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                .filter { SubscriptionReminderConfig.daysBeforeRange.contains($0) }
            guard !parsedDays.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/reminders days 3,1</code> — за сколько дней напомнить (до \(SubscriptionReminderConfig.maxExpiryWaves) волн, \(SubscriptionReminderConfig.daysBeforeRange.lowerBound)–\(SubscriptionReminderConfig.daysBeforeRange.upperBound) дн.) · <code>/reminders days off</code> — не напоминать")
                return
            }
            config.expiryReminderDays = parsedDays
            await state.setReminderConfig(config)
            let appliedDays = await state.reminderConfig().expiryReminderDays
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Напоминания: " + appliedDays.map { "за \($0) дн." }.joined(separator: ", "))

        case "winback":
            if rest == "-" || rest == "0" || rest.lowercased() == "off" {
                config.winbackDays = []
                await state.setReminderConfig(config)
                try await sendUserFeedback(chatKey: chatKey, text: "✓ Winback выключен.")
                return
            }
            let parsed = rest
                .split(whereSeparator: { ",; ".contains($0) })
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                .filter { SubscriptionReminderConfig.winbackDayRange.contains($0) }
            guard !parsed.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/reminders winback 1,7</code> · <code>/reminders winback off</code>")
                return
            }
            config.winbackDays = parsed
            await state.setReminderConfig(config)
            let applied = await state.reminderConfig().winbackDays
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Winback: " + applied.map { "+\($0)д" }.joined(separator: ", "))

        case "discount":
            guard let n = Int(rest), SubscriptionReminderConfig.discountRange.contains(n) else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/reminders discount \(SubscriptionReminderConfig.discountRange.lowerBound)-\(SubscriptionReminderConfig.discountRange.upperBound)</code>")
                return
            }
            config.winbackDiscountPercent = n
            await state.setReminderConfig(config)
            try await sendUserFeedback(chatKey: chatKey, text: n == 0
                ? "✓ Winback без скидки — только напоминание."
                : "✓ Скидка winback: <b>\(n)%</b> на подписку (Stars, крипта, карта).")

        case "hours":
            guard let n = Int(rest), SubscriptionReminderConfig.offerHoursRange.contains(n) else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/reminders hours \(SubscriptionReminderConfig.offerHoursRange.lowerBound)-\(SubscriptionReminderConfig.offerHoursRange.upperBound)</code>")
                return
            }
            config.winbackOfferHours = n
            await state.setReminderConfig(config)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Скидка действует <b>\(n) ч</b> после выдачи.")

        case "interval":
            guard let n = Int(rest), SubscriptionReminderConfig.sweepIntervalRange.contains(n) else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/reminders interval \(SubscriptionReminderConfig.sweepIntervalRange.lowerBound)-\(SubscriptionReminderConfig.sweepIntervalRange.upperBound)</code> (минуты)")
                return
            }
            config.sweepIntervalMinutes = n
            await state.setReminderConfig(config)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Проверка каждые <b>\(n) мин</b> (применится к следующему циклу).")

        case "wallet":
            guard let n = Int(rest), SubscriptionReminderConfig.walletWinbackRange.contains(n) else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/reminders wallet 7</code> — через сколько дней тишины написать тем, у кого закончился оплаченный баланс (\(SubscriptionReminderConfig.walletWinbackRange.lowerBound)–\(SubscriptionReminderConfig.walletWinbackRange.upperBound), 0 — не писать)")
                return
            }
            config.walletWinbackDays = n
            await state.setReminderConfig(config)
            try await sendUserFeedback(chatKey: chatKey, text: n == 0
                ? "✓ Возврат по балансу выключен."
                : "✓ Возврат по балансу — после <b>\(n) дн.</b> тишины. Пишем только тем, кто платил деньгами, и один раз до следующего пополнения.")

        case "run":
            guard let reminderService else {
                try await sendUserFeedback(chatKey: chatKey, text: "⚠️ Сервис напоминаний недоступен.")
                return
            }
            let result = await reminderService.sweep()
            try await sendUserFeedback(chatKey: chatKey, text: "🔄 Проверка выполнена · \(result.summaryLine)")

        case "test", "preview":
            guard let reminderService else {
                try await sendUserFeedback(chatKey: chatKey, text: "⚠️ Сервис напоминаний недоступен.")
                return
            }
            // Renders the real texts with real prices; nothing goes to sponsors.
            for preview in await reminderService.previewTexts(username: fromUser?.username) {
                _ = try? await telegram.sendMessage(.init(
                    chatID: chatKey.chatID,
                    threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                    replyTo: nil,
                    text: "👁 <i>Предпросмотр (никому не отправлено)</i>\n\n" + preview.text,
                    replyMarkup: preview.markup
                ))
            }

        case "clear":
            let cleared = await state.clearAllWinbackDiscounts()
            try await sendUserFeedback(chatKey: chatKey, text: "🗑 Снято активных скидок: <b>\(cleared)</b>.")

        default:
            try await sendUserFeedback(chatKey: chatKey, text: """
                <b>⏳ Напоминания и winback</b>

                <code>/reminders</code> — статус и список подписок под наблюдением
                <code>/reminders on|off</code> — включить/выключить
                <code>/reminders days 3,1</code> — за сколько дней напомнить (<code>off</code> — не напоминать)
                <code>/reminders winback 1,7</code> — дни winback после истечения (<code>off</code> — выключить)
                <code>/reminders discount 30</code> — скидка winback, %
                <code>/reminders hours 48</code> — сколько действует скидка
                <code>/reminders interval 60</code> — как часто проверять, мин
                <code>/reminders wallet 7</code> — вернуть тех, у кого кончился оплаченный баланс (0 — не писать)
                <code>/reminders chats on|off</code> — уведомлять ли чаты спонсора
                <code>/reminders run</code> — проверить прямо сейчас
                <code>/reminders test</code> — предпросмотр текстов
                <code>/reminders clear</code> — снять все активные скидки

                Всё то же — в /menu → 🛡 Супер-админ → ⏳ Напоминания и winback.
                """)
        }
    }

    private func remindersStatusText(config: SubscriptionReminderConfig) async -> String {
        let stats = await state.subscriptionLifecycleStats()
        let sweep = await reminderService?.status()
        let dateFormatter = DateFormatter(); dateFormatter.dateFormat = "dd.MM.yyyy"
        let timeFormatter = DateFormatter(); timeFormatter.dateFormat = "dd.MM HH:mm"

        var lines = [
            "<b>⏳ Напоминания и winback</b>",
            "",
            "Статус · <b>\(config.enabled ? "включены" : "выключены")</b>",
            "До истечения · <b>\(config.expiryReminderDays.isEmpty ? "выкл" : config.expiryReminderDays.map { "за \($0) дн." }.joined(separator: ", "))</b>",
            "Winback · <b>\(config.winbackDays.isEmpty ? "выкл" : config.winbackDays.map { "+\($0)д" }.joined(separator: ", "))</b> · скидка <b>\(config.winbackDiscountPercent)%</b> на <b>\(config.winbackOfferHours) ч</b>",
            "Чаты спонсора · <b>\(config.notifyChats ? "уведомляем" : "нет")</b> · проверка каждые <b>\(config.sweepIntervalMinutes)</b> мин",
            "Возврат по балансу · <b>\(config.walletWinbackDays > 0 ? "после \(config.walletWinbackDays) дн. тишины" : "выкл")</b>",
        ]
        if let sweep, let last = sweep.last, let runAt = sweep.lastRunAt {
            lines.append("Последняя проверка · \(timeFormatter.string(from: runAt)) · \(last.summaryLine)")
        } else {
            lines.append("Последняя проверка · <i>ещё не было</i>")
        }
        lines.append("")
        lines.append("Спонсоров с подпиской · <b>\(stats.sponsors)</b> · без канала связи · <b>\(stats.unreachable)</b> · отписались · <b>\(stats.optedOut)</b>")
        if stats.expiringSoon.isEmpty {
            lines.append("⏳ Скоро истекают · <i>нет</i>")
        } else {
            lines.append("⏳ Скоро истекают:")
            for row in stats.expiringSoon.prefix(15) {
                lines.append("• \(row.label) — \(dateFormatter.string(from: row.paidUntil))" + (row.reachable ? "" : " · 🚫 нет канала") + (row.optedOut ? " · 🔕" : ""))
            }
        }
        if !stats.recentlyExpired.isEmpty {
            lines.append("⛔ Недавно истекли:")
            for row in stats.recentlyExpired.prefix(15) {
                lines.append("• \(row.label) — \(dateFormatter.string(from: row.paidUntil))" + (row.reachable ? "" : " · 🚫 нет канала") + (row.optedOut ? " · 🔕" : ""))
            }
        }
        if !stats.activeDiscounts.isEmpty {
            lines.append("🎁 Живые скидки:")
            for entry in stats.activeDiscounts.prefix(15) {
                lines.append("• \(entry.label) — −\(entry.discount.percent)% до \(timeFormatter.string(from: entry.discount.expiresAt))")
            }
        }
        lines.append("")
        lines.append("<i>Подсказка по подкомандам — /reminders help</i>")
        return lines.joined(separator: "\n")
    }

    // MARK: - Ads (superadmin)

    private static let adsDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy"
        return f
    }()

    private func adSummaryLines(_ c: AdCampaign) -> [String] {
        var lines: [String] = []
        let status = c.enabled ? (c.isRunning() ? "🟢" : "🟡") : "⚪"
        var limits = "каждые \(c.everyNReplies) отв. · пауза \(c.minIntervalSeconds / 60) мин"
        if let target = c.totalImpressionsTarget {
            limits += " · показы \(c.impressionsUsed)/\(target)"
        } else {
            limits += " · показов \(c.impressionsUsed)"
        }
        if let endAt = c.endAt {
            limits += " · до \(Self.adsDateFormatter.string(from: endAt))"
        }
        lines.append("\(status) <b>\(c.id)</b> · \(limits)")
        let preview = c.text.count > 120 ? String(c.text.prefix(120)) + "…" : c.text
        lines.append("<blockquote expandable>\(preview)</blockquote>")
        if let bt = c.buttonText, let url = c.buttonURL {
            lines.append("🔗 [\(bt)] → \(url)")
        }
        return lines
    }

    private func handleAds(chatKey: ChatKey, argument: String) async throws {
        let parts = argument.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        let subcommand = (parts.first ?? "").lowercased()
        let rest = parts.count > 1 ? parts[1] : ""

        switch subcommand {
        case "add":
            let text = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/ads add &lt;текст объявления&gt;</code> (HTML разрешён)")
                return
            }
            let campaign = AdCampaign.new(text: text)
            await state.upsertAdCampaign(campaign)
            try await sendUserFeedback(chatKey: chatKey, text: """
                ✓ Кампания <b>\(campaign.id)</b> создана и включена.
                По умолчанию: каждые 10 ответов, пауза 60 мин, без лимита показов.

                Настроить:
                <code>/ads freq \(campaign.id) 10 60</code> — каждые N ответов, пауза в минутах
                <code>/ads limit \(campaign.id) 1000 30</code> — 1000 показов, размазанных на 30 дней
                <code>/ads button \(campaign.id) Открыть | https://example.com</code>
                """)

        case "remove", "rm":
            let id = rest.trimmingCharacters(in: .whitespaces)
            let removed = await state.removeAdCampaign(id: id)
            try await sendUserFeedback(chatKey: chatKey, text: removed ? "✓ Кампания \(id) удалена." : "Кампания \(id) не найдена.")

        case "on", "off":
            let id = rest.trimmingCharacters(in: .whitespaces)
            let ok = await state.setAdCampaignEnabled(id: id, enabled: subcommand == "on")
            try await sendUserFeedback(chatKey: chatKey, text: ok
                ? "✓ Кампания \(id) · \(subcommand == "on" ? "включена" : "выключена")."
                : "Кампания \(id) не найдена.")

        case "freq":
            let args = rest.split(separator: " ").map(String.init)
            guard args.count >= 2, let everyN = Int(args[1]), everyN >= 1,
                  var campaign = await state.adCampaign(id: args[0]) else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/ads freq &lt;id&gt; &lt;каждые_N_ответов&gt; [пауза_минут]</code>")
                return
            }
            campaign.everyNReplies = everyN
            if args.count >= 3, let minutes = Int(args[2]), minutes >= 0 {
                campaign.minIntervalSeconds = minutes * 60
            }
            await state.upsertAdCampaign(campaign)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ \(campaign.id): каждые <b>\(campaign.everyNReplies)</b> ответов · пауза <b>\(campaign.minIntervalSeconds / 60) мин</b>.")

        case "limit":
            let args = rest.split(separator: " ").map(String.init)
            guard let id = args.first, var campaign = await state.adCampaign(id: id) else {
                try await sendUserFeedback(chatKey: chatKey, text: """
                    <i>Использование:</i>
                    <code>/ads limit &lt;id&gt; &lt;показов&gt; [дней]</code> — лимит, равномерно на период
                    <code>/ads limit &lt;id&gt; off</code> — снять лимит
                    """)
                return
            }
            if args.count >= 2, args[1].lowercased() == "off" {
                campaign.totalImpressionsTarget = nil
                campaign.endAt = nil
                await state.upsertAdCampaign(campaign)
                try await sendUserFeedback(chatKey: chatKey, text: "✓ \(campaign.id): лимит показов снят.")
                return
            }
            guard args.count >= 2, let target = Int(args[1]), target > 0 else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/ads limit &lt;id&gt; &lt;показов&gt; [дней]</code>")
                return
            }
            campaign.totalImpressionsTarget = target
            campaign.startAt = Date()
            campaign.impressionsUsed = 0
            if args.count >= 3, let days = Int(args[2]), days > 0 {
                campaign.endAt = Date().addingTimeInterval(TimeInterval(days) * 86_400)
            } else {
                campaign.endAt = nil
            }
            await state.upsertAdCampaign(campaign)
            let window = campaign.endAt.map { " до \(Self.adsDateFormatter.string(from: $0)) (показы размазаны равномерно)" } ?? " (без даты окончания)"
            try await sendUserFeedback(chatKey: chatKey, text: "✓ \(campaign.id): <b>\(target)</b> показов\(window). Счётчик обнулён.")

        case "button":
            let args = rest.split(separator: " ", maxSplits: 1).map(String.init)
            guard let id = args.first, var campaign = await state.adCampaign(id: id) else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/ads button &lt;id&gt; &lt;текст&gt; | &lt;url&gt;</code> или <code>/ads button &lt;id&gt; off</code>")
                return
            }
            let value = args.count > 1 ? args[1] : ""
            if value.lowercased() == "off" || value.isEmpty {
                campaign.buttonText = nil
                campaign.buttonURL = nil
                await state.upsertAdCampaign(campaign)
                try await sendUserFeedback(chatKey: chatKey, text: "✓ \(campaign.id): кнопка убрана.")
                return
            }
            let buttonParts = value.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard buttonParts.count == 2, !buttonParts[0].isEmpty, buttonParts[1].hasPrefix("http") else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/ads button &lt;id&gt; Открыть сайт | https://example.com</code>")
                return
            }
            campaign.buttonText = buttonParts[0]
            campaign.buttonURL = buttonParts[1]
            await state.upsertAdCampaign(campaign)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ \(campaign.id): кнопка «\(buttonParts[0])» → \(buttonParts[1])")

        case "text":
            let args = rest.split(separator: " ", maxSplits: 1).map(String.init)
            guard args.count == 2, var campaign = await state.adCampaign(id: args[0]) else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/ads text &lt;id&gt; &lt;новый текст&gt;</code>")
                return
            }
            campaign.text = args[1]
            await state.upsertAdCampaign(campaign)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ \(campaign.id): текст обновлён.")

        // Built-in self-promo (roadmap step 5) — same knobs as the menu page,
        // nothing about the pitch is hardcoded.
        case "promo":
            let args = rest.split(separator: " ", maxSplits: 1).map(String.init)
            let action = (args.first ?? "").lowercased()
            let value = args.count > 1 ? args[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            var promo = await state.selfPromoConfig()
            switch action {
            case "on", "off":
                promo.enabled = action == "on"
                await state.setSelfPromoConfig(promo)
                try await sendUserFeedback(chatKey: chatKey, text: promo.enabled
                    ? "✓ Само-реклама включена — займёт свободный рекламный слот."
                    : "✓ Само-реклама выключена — свободный слот останется пустым.")
            case "text":
                guard !value.isEmpty else {
                    try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/ads promo text &lt;новый текст&gt;</code>")
                    return
                }
                promo.text = value
                await state.setSelfPromoConfig(promo)
                try await sendUserFeedback(chatKey: chatKey, text: "✓ Текст само-рекламы обновлён (показы сохранены).")
            case "freq":
                let nums = value.split(separator: " ").map(String.init)
                guard let everyN = nums.first.flatMap(Int.init), SelfPromoConfig.repliesRange.contains(everyN) else {
                    try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/ads promo freq &lt;каждые_N_ответов&gt; [пауза_минут]</code>")
                    return
                }
                promo.everyNReplies = everyN
                if nums.count >= 2, let minutes = Int(nums[1]), SelfPromoConfig.pauseMinutesRange.contains(minutes) {
                    promo.minIntervalSeconds = minutes * 60
                }
                await state.setSelfPromoConfig(promo)
                let saved = await state.selfPromoConfig()
                try await sendUserFeedback(chatKey: chatKey, text: "✓ Само-реклама: каждые <b>\(saved.everyNReplies)</b> ответов · пауза <b>\(saved.minIntervalSeconds / 60) мин</b>.")
            case "reset":
                await state.resetSelfPromoStats()
                try await sendUserFeedback(chatKey: chatKey, text: "✓ Счётчик показов само-рекламы обнулён.")
            default:
                try await sendUserFeedback(chatKey: chatKey, text: """
                    <b>📣 Само-реклама премиума</b> · \(promo.enabled ? "включена" : "выключена")
                    Каждые <b>\(promo.everyNReplies)</b> ответов · пауза <b>\(promo.minIntervalSeconds / 60)</b> мин · показов <b>\(promo.impressions)</b>
                    <blockquote expandable>\(promo.text)</blockquote>
                    Занимает рекламный слот в бесплатных чатах, когда нет активной кампании. Кнопку «⚡ Открыть премиум» бот добавляет сам.

                    <code>/ads promo on|off</code> · <code>/ads promo text &lt;текст&gt;</code>
                    <code>/ads promo freq &lt;N&gt; [мин]</code> · <code>/ads promo reset</code>
                    """)
            }

        case "list", "stats", "":
            let campaigns = await state.adCampaigns()
            var lines = ["<b>📣 Рекламные кампании</b> (\(campaigns.count))"]
            if campaigns.isEmpty {
                lines.append("<i>нет</i>")
            } else {
                for c in campaigns {
                    lines.append("")
                    lines.append(contentsOf: adSummaryLines(c))
                }
            }
            let promo = await state.selfPromoConfig()
            lines.append("")
            lines.append("<b>Само-реклама премиума</b> · \(promo.enabled ? "вкл" : "выкл") · каждые \(promo.everyNReplies) отв. · пауза \(promo.minIntervalSeconds / 60) мин · показов \(promo.impressions)")
            lines.append("<i>Занимает слот, когда активных кампаний нет. Настройка — /ads promo</i>")
            lines.append("")
            lines.append("""
                <code>/ads add &lt;текст&gt;</code> — создать
                <code>/ads freq &lt;id&gt; &lt;N&gt; [мин]</code> — частота: каждые N ответов, пауза
                <code>/ads limit &lt;id&gt; &lt;показов&gt; [дней]</code> — лимит с равномерным пейсингом
                <code>/ads button &lt;id&gt; &lt;текст&gt; | &lt;url&gt;</code> — кнопка-ссылка
                <code>/ads text &lt;id&gt; &lt;текст&gt;</code> · <code>on|off|remove &lt;id&gt;</code>
                <code>/ads promo</code> — само-реклама премиума

                <i>Показы — только в чатах без активной платной лицензии, после ответа бота. Проверить самому: /simulate user, затем написать боту.</i>
                """)
            try await sendUserFeedback(chatKey: chatKey, text: lines.joined(separator: "\n"))

        default:
            try await sendUserFeedback(chatKey: chatKey, text: "<i>Неизвестная подкоманда.</i> Список: <code>/ads</code>")
        }
    }

    private func handleWhitelist(chatKey: ChatKey, argument: String) async throws {
        let parts = argument.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        let subcommand = parts.first ?? ""
        let value = parts.count > 1 ? parts[1] : ""

        switch subcommand.lowercased() {
        case "add":
            guard let userID = Int(value) else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Как пользоваться:</i> <code>/whitelist add &lt;номер пользователя&gt;</code>")
                return
            }
            await state.addToWhitelist(userID: userID, chatID: chatKey.chatID)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Пользователь <code>\(userID)</code> добавлен в гости этого чата — ваш премиум работает и для него.")

        case "remove":
            guard let userID = Int(value) else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Как пользоваться:</i> <code>/whitelist remove &lt;номер пользователя&gt;</code>")
                return
            }
            await state.removeFromWhitelist(userID: userID, chatID: chatKey.chatID)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Пользователь <code>\(userID)</code> больше не гость этого чата.")

        case "list":
            let ids = await state.listWhitelisted(chatID: chatKey.chatID)
            if ids.isEmpty {
                try await sendUserFeedback(chatKey: chatKey, text: "Гостей в этом чате пока нет.")
            } else {
                let sorted = ids.sorted()
                let list = sorted.map { "• <code>\($0)</code>" }.joined(separator: "\n")
                try await sendUserFeedback(chatKey: chatKey, text: "<b>👤 Гости этого чата</b> (\(sorted.count))\n\(list)")
            }

        default:
            try await sendUserFeedback(chatKey: chatKey, text: """
                <b>👤 Гости этого чата</b>
                Ваш премиум работает и для них — даже если сам чат к нему не подключён.

                <code>/whitelist add &lt;номер&gt;</code> — добавить
                <code>/whitelist remove &lt;номер&gt;</code> — убрать
                <code>/whitelist list</code> — показать

                <i>То же самое кнопками: /menu → ⚡ Мой премиум → 👤 Гости этого чата</i>
                """)
        }
    }

    private func handleDefaults(chatKey: ChatKey, argument: String) async throws {
        let parts = argument.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        let subcommand = parts.first ?? ""
        let value = parts.count > 1 ? parts[1] : ""

        switch subcommand.lowercased() {
        case "model":
            guard !value.isEmpty else {
                let defs = await state.getDefaults(chatID: chatKey.chatID)
                try await sendUserFeedback(chatKey: chatKey, text: "Модель по умолчанию · <code>\(defs.model)</code>")
                return
            }
            let new = await state.setDefaultModel(value, chatID: chatKey.chatID)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Модель по умолчанию · <code>\(new)</code>")

        case "role":
            guard !value.isEmpty else {
                let defs = await state.getDefaults(chatID: chatKey.chatID)
                try await sendUserFeedback(chatKey: chatKey, text: "Роль по умолчанию:\n<blockquote expandable>\(defs.role)</blockquote>")
                return
            }
            let new = await state.setDefaultRole(value, chatID: chatKey.chatID)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Роль по умолчанию обновлена:\n<blockquote expandable>\(new)</blockquote>")

        case "historylength":
            guard !value.isEmpty, let length = Int(value), (1...50).contains(length) else {
                if value.isEmpty {
                    let defs = await state.getDefaults(chatID: chatKey.chatID)
                    try await sendUserFeedback(chatKey: chatKey, text: "Длина истории по умолчанию · <b>\(defs.historyLength)</b>")
                } else {
                    try await sendUserFeedback(chatKey: chatKey, text: "<i>Нужно число от 1 до 50.</i>\n<i>Пример:</i> <code>/defaults historylength 11</code>")
                }
                return
            }
            let new = await state.setDefaultHistoryLength(length, chatID: chatKey.chatID)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Длина истории по умолчанию · <b>\(new)</b>")

        default:
            let defs = await state.getDefaults(chatID: chatKey.chatID)
            try await sendUserFeedback(chatKey: chatKey, text: """
                <b>⚙️ Значения по умолчанию</b>

                🤖 Модель · <code>\(defs.model)</code>
                📝 Память · <b>\(defs.historyLength) сообщ.</b>
                🎭 Роль:
                <blockquote expandable>\(defs.role)</blockquote>

                <b>Команды:</b>
                <code>/defaults model &lt;id&gt;</code>
                <code>/defaults role &lt;текст&gt;</code>
                <code>/defaults historylength &lt;1–50&gt;</code>

                <i>Заготовки для кнопок меню — /presets</i>
                """)
        }
    }

    private func handleChats(chatKey: ChatKey, fromUser: TelegramUser?) async throws {
        let isSuperAdmin = await self.isSuperAdmin(fromUser)
        let ownerFilter: String? = isSuperAdmin ? nil : fromUser?.username?.lowercased()
        let groups = await state.groupChats(ownedBy: ownerFilter)
        let privates = await state.privateChats(ownedBy: ownerFilter)

        var lines: [String] = []

        lines.append("<b>👥 Групповые чаты</b> (\(groups.count))")
        if groups.isEmpty {
            lines.append("<i>нет</i>")
        } else {
            for (chatID, threadID) in groups.sorted(by: { $0.chatID < $1.chatID }) {
                let threadInfo = threadID != 0 ? " · thread \(threadID)" : ""
                let label = await state.chatMeta(chatID: chatID).map { " · \($0.displayLabel)" } ?? ""
                lines.append("• <code>\(chatID)</code>\(threadInfo)\(label)")
            }
        }

        lines.append("")
        lines.append("<b>👤 Личные чаты</b> (\(privates.count))")
        if privates.isEmpty {
            lines.append("<i>нет</i>")
        } else {
            for (chatID, threadID) in privates.sorted(by: { $0.chatID < $1.chatID }) {
                let threadInfo = threadID != 0 ? " · thread \(threadID)" : ""
                let label = await state.chatMeta(chatID: chatID).map { " · \($0.displayLabel)" } ?? ""
                lines.append("• <code>\(chatID)</code>\(threadInfo)\(label)")
            }
        }

        if isSuperAdmin {
            lines.append("")
            lines.append("<i>Настройки любого чата: /inspect &lt;chatID&gt;</i>")
        }

        try await sendUserFeedback(chatKey: chatKey, text: lines.joined(separator: "\n"))
    }

    private func handleUsers(chatKey: ChatKey, fromUser: TelegramUser?) async throws {
        let isSuperAdmin = await self.isSuperAdmin(fromUser)
        let ownerFilter: String? = isSuperAdmin ? nil : fromUser?.username?.lowercased()
        let privates = await state.privateChats(ownedBy: ownerFilter)

        if privates.isEmpty {
            try await sendUserFeedback(chatKey: chatKey, text: "В личке пока пусто.")
            return
        }

        let sorted = privates.sorted(by: { $0.chatID < $1.chatID })
        var list: [String] = []
        for entry in sorted {
            let label = await state.chatMeta(chatID: entry.chatID).map { " · \($0.displayLabel)" } ?? ""
            list.append("• <code>\(entry.chatID)</code>\(label)")
        }
        try await sendUserFeedback(chatKey: chatKey, text: """
            <b>👤 Пользователи в личке</b> (\(sorted.count))
            \(list.joined(separator: "\n"))

            <i>Открыть кому-то премиум в этом чате:</i> <code>/whitelist add &lt;номер&gt;</code>
            """)
    }

    private func handlePresets(chatKey: ChatKey, argument: String) async throws {
        let parts = argument.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        let presetType = parts.first ?? ""
        let subcommand = parts.count > 1 ? parts[1] : ""
        let value = parts.count > 2 ? parts[2] : ""

        switch presetType.lowercased() {
        case "model":
            try await handlePresetsSub(
                chatKey: chatKey,
                subcommand: subcommand,
                value: value,
                typeKey: "model",
                typeName: "моделей",
                list: { [self] in await state.modelPresets(chatID: chatKey.chatID) },
                add: { [self] display, val, provider in await state.addModelPreset(display: display, value: val, provider: provider, chatID: chatKey.chatID) },
                remove: { [self] val in await state.removeModelPreset(value: val, chatID: chatKey.chatID) }
            )

        case "temp":
            try await handlePresetsSub(
                chatKey: chatKey,
                subcommand: subcommand,
                value: value,
                typeKey: "temp",
                typeName: "температуры",
                list: { [self] in await state.tempPresets(chatID: chatKey.chatID) },
                add: { [self] display, val, _ in await state.addTempPreset(display: display, value: val, chatID: chatKey.chatID) },
                remove: { [self] val in await state.removeTempPreset(value: val, chatID: chatKey.chatID) }
            )

        case "history", "historylength":
            try await handlePresetsSub(
                chatKey: chatKey,
                subcommand: subcommand,
                value: value,
                typeKey: "history",
                typeName: "длины истории",
                list: { [self] in await state.historyLengthPresets(chatID: chatKey.chatID) },
                add: { [self] display, val, _ in await state.addHistoryLengthPreset(display: display, value: val, chatID: chatKey.chatID) },
                remove: { [self] val in await state.removeHistoryLengthPreset(value: val, chatID: chatKey.chatID) }
            )

        case "role":
            try await handlePresetsSub(
                chatKey: chatKey,
                subcommand: subcommand,
                value: value,
                typeKey: "role",
                typeName: "ролей",
                list: { [self] in await state.rolePresets(chatID: chatKey.chatID) },
                add: { [self] display, val, _ in await state.addRolePreset(display: display, value: val, chatID: chatKey.chatID) },
                remove: { [self] val in await state.removeRolePreset(value: val, chatID: chatKey.chatID) }
            )

        default:
            try await sendUserFeedback(chatKey: chatKey, text: """
                <b>🎛 Заготовки для меню</b>

                <code>/presets &lt;тип&gt; add &lt;название&gt; | &lt;значение&gt;</code>
                <code>/presets &lt;тип&gt; remove &lt;value&gt;</code>
                <code>/presets &lt;тип&gt; list</code>

                <b>Типы:</b> <code>model</code>, <code>temp</code>, <code>history</code>, <code>role</code>

                <i>Пример:</i>
                <code>/presets model add GPT-4o | openai/gpt-4o</code>
                """)
        }
    }

    private func handlePresetsSub(
        chatKey: ChatKey,
        subcommand: String,
        value: String,
        typeKey: String,
        typeName: String,
        list: @Sendable () async -> [Preset],
        add: @Sendable (String, String, String?) async -> Preset,
        remove: @Sendable (String) async -> Bool
    ) async throws {
        switch subcommand.lowercased() {
        case "add":
            let separator = value.contains("|") ? "|" : " ~ "
            let addParts = value
                .components(separatedBy: separator)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            guard addParts.count >= 2 else {
                try await sendUserFeedback(
                    chatKey: chatKey,
                    text: """
                    <i>Как пользоваться:</i> <code>/presets \(typeKey) add &lt;название&gt; | &lt;значение&gt;</code>
                    <i>Пример:</i> <code>/presets model add Gemini 3 Flash | google/gemini-3-flash-preview</code>
                    <i>Модель через конкретный сервис:</i> <code>/presets model add DeepSeek V4 | deepseek/deepseek-v4-pro | deepseek</code>
                    """
                )
                return
            }

            let display = addParts[0]
            let presetValue: String
            let presetProvider: String?
            if typeKey == "model", addParts.count >= 3 {
                // Third part pins the OpenRouter upstream provider.
                presetValue = addParts[1]
                presetProvider = addParts[2]
            } else {
                presetValue = addParts.dropFirst().joined(separator: " ")
                presetProvider = nil
            }
            let preset = await add(display, presetValue, presetProvider)
            let providerNote = preset.provider.map { " · <code>\($0)</code>" } ?? ""
            try await sendUserFeedback(
                chatKey: chatKey,
                text: "✓ Заготовка \(typeName): <b>\(preset.display)</b> → <code>\(preset.value)</code>\(providerNote)"
            )

        case "remove":
            guard !value.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Как пользоваться:</i> <code>/presets \(typeKey) remove &lt;значение&gt;</code>")
                return
            }
            let removed = await remove(value)
            try await sendUserFeedback(
                chatKey: chatKey,
                text: removed
                    ? "✓ Заготовка \(typeName) <code>\(value)</code> удалена."
                    : "Заготовка \(typeName) <code>\(value)</code> не найдена."
            )

        case "list":
            let presets = await list()
            if presets.isEmpty {
                try await sendUserFeedback(chatKey: chatKey, text: "Заготовки \(typeName): пусто.")
            } else {
                var lines = ["<b>Заготовки \(typeName)</b> (\(presets.count))"]
                for (i, p) in presets.enumerated() {
                    let providerNote = p.provider.map { " · <code>\($0)</code>" } ?? ""
                    lines.append("\(i). <b>\(p.display)</b> → <code>\(p.value)</code>\(providerNote)")
                }
                try await sendUserFeedback(chatKey: chatKey, text: lines.joined(separator: "\n"))
            }

        default:
            try await sendUserFeedback(chatKey: chatKey, text: """
                <b>📋 Заготовки \(typeName)</b>
                <code>/presets \(typeKey) add &lt;название&gt; | &lt;значение&gt;</code>
                <code>/presets \(typeKey) remove &lt;значение&gt;</code>
                <code>/presets \(typeKey) list</code>
                """)
        }
    }

    private func handleTenant(chatKey: ChatKey, argument: String, fromUser: TelegramUser?) async throws {
        let parts = argument.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        let subcommand = parts.first ?? ""
        let arg1 = parts.count > 1 ? parts[1] : ""
        let arg2 = parts.count > 2 ? parts[2] : ""

        func normalizeUsername(_ raw: String) -> String {
            raw.hasPrefix("@") ? String(raw.dropFirst()) : raw
        }

        // Storage key: stored owners are keyed by userID, so comparisons must
        // use the key rather than the rentable handle.
        let invokerUsername = await state.userKey(username: fromUser?.username)
        let invokerIsSuper = await state.isSuperAdmin(username: fromUser?.username)
        let superOnlySubs: Set<String> = [
            "remove", "price", "freemodels", "cryptoprice", "cryptoaddr",
            "cryptomode", "cryptopool", "stats", "cryptoinvoices",
            "extend", "unlimited", "expire", "markup"
        ]
        if superOnlySubs.contains(subcommand.lowercased()), !invokerIsSuper {
            try await sendUserFeedback(chatKey: chatKey, text: "🔒 Команда только для суперадминистратора.")
            return
        }

        switch subcommand.lowercased() {
        case "add":
            guard invokerIsSuper else {
                try await sendUserFeedback(chatKey: chatKey, text: "🔒 Команда только для суперадминистратора.")
                return
            }
            let username = normalizeUsername(arg1)
            guard !username.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant add @username</code>")
                return
            }
            await state.registerTenant(username: username)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Tenant @\(username) зарегистрирован.")

        case "remove":
            let username = normalizeUsername(arg1)
            guard !username.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant remove @username</code>")
                return
            }
            let removed = await state.removeTenant(username: username)
            try await sendUserFeedback(chatKey: chatKey, text: removed
                ? "✓ Tenant @\(username) удалён."
                : "Tenant @\(username) не найден или является владельцем.")

        case "list":
            let tenants = await state.listTenants()
            if tenants.isEmpty {
                try await sendUserFeedback(chatKey: chatKey, text: "Спонсоров пока нет.")
            } else {
                let list = tenants.map { "• \($0.label)" }.joined(separator: "\n")
                try await sendUserFeedback(chatKey: chatKey, text: "<b>🏢 Спонсоры</b> (\(tenants.count))\n\(list)")
            }

        case "assign":
            let username = normalizeUsername(arg1)
            // Admins may only assign chats to themselves; super may assign to anyone.
            if !invokerIsSuper, await state.userKey(username: username) != invokerUsername {
                try await sendUserFeedback(chatKey: chatKey, text: "🔒 Включить премиум в чате можно только за свой счёт.")
                return
            }
            guard !username.isEmpty, let chatID = Int(arg2) else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant assign @username &lt;chatID&gt;</code>")
                return
            }
            let ok = await state.assignChat(chatID: chatID, to: username)
            try await sendUserFeedback(chatKey: chatKey, text: ok
                ? "✓ В чате <code>\(chatID)</code> включён премиум @\(username)."
                : "У @\(username) нет премиума.")

        case "unassign":
            guard let chatID = Int(arg1) else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant unassign &lt;chatID&gt;</code>")
                return
            }
            let owner = await state.chatOwner(chatID: chatID)
            if !invokerIsSuper, owner != invokerUsername {
                try await sendUserFeedback(chatKey: chatKey, text: "🔒 В этом чате премиум открыли не вы.")
                return
            }
            let removed = await state.unassignChat(chatID: chatID)
            try await sendUserFeedback(chatKey: chatKey, text: removed != nil
                ? "✓ Chat <code>\(chatID)</code> отвязан от \(await state.displayLabel(forKey: removed!))."
                : "Чат <code>\(chatID)</code> не был привязан.")

        case "claim":
            // Admin attaches the current chat to their licence.
            guard let username = invokerUsername else {
                try await sendUserFeedback(chatKey: chatKey, text: "У вас не задан @username.")
                return
            }
            let ok = await state.assignChat(chatID: chatKey.chatID, to: username)
            try await sendUserFeedback(chatKey: chatKey, text: ok
                ? "✓ Этот чат привязан к @\(username)."
                : "У @\(username) нет премиума — оформить: /buy")

        case "release":
            // Admin detaches the current chat from their licence.
            let owner = await state.chatOwner(chatID: chatKey.chatID)
            if !invokerIsSuper, owner != invokerUsername {
                try await sendUserFeedback(chatKey: chatKey, text: "🔒 В этом чате премиум открыли не вы.")
                return
            }
            let removed = await state.unassignChat(chatID: chatKey.chatID)
            try await sendUserFeedback(chatKey: chatKey, text: removed != nil
                ? "✓ Этот чат отвязан от \(await state.displayLabel(forKey: removed!))."
                : "Этот чат не был привязан.")

        case "chats":
            // Admin → own chats; super → all (already covered by /chats).
            guard let username = invokerUsername else {
                try await sendUserFeedback(chatKey: chatKey, text: "У вас не задан @username.")
                return
            }
            let chats = await state.chatsOwnedBy(username)
            if chats.isEmpty {
                try await sendUserFeedback(chatKey: chatKey, text: "Ваш премиум пока не включён ни в одном чате.")
            } else {
                let list = chats.sorted().map { "• <code>\($0)</code>" }.joined(separator: "\n")
                try await sendUserFeedback(chatKey: chatKey, text: "<b>📌 Чаты с премиумом @\(username)</b> (\(chats.count))\n\(list)")
            }

        case "adduser":
            guard let username = invokerUsername else {
                try await sendUserFeedback(chatKey: chatKey, text: "У вас не задан @username.")
                return
            }
            let target = normalizeUsername(arg1)
            guard !target.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant adduser @username</code>")
                return
            }
            let added = await state.addLicensedUser(ownerUsername: username, target: target)
            try await sendUserFeedback(chatKey: chatKey, text: added
                ? "✓ @\(target) теперь пользуется умными моделями за ваш счёт."
                : "@\(target) уже в списке, либо ваш премиум неактивен.")

        case "removeuser":
            guard let username = invokerUsername else {
                try await sendUserFeedback(chatKey: chatKey, text: "У вас не задан @username.")
                return
            }
            let target = normalizeUsername(arg1)
            guard !target.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant removeuser @username</code>")
                return
            }
            let removed = await state.removeLicensedUser(ownerUsername: username, target: target)
            try await sendUserFeedback(chatKey: chatKey, text: removed
                ? "✓ @\(target) больше не гость вашего премиума."
                : "@\(target) не найден среди гостей вашего премиума.")

        case "users":
            guard let username = invokerUsername else {
                try await sendUserFeedback(chatKey: chatKey, text: "У вас не задан @username.")
                return
            }
            let users = await state.licensedUsers(ownerUsername: username)
            if users.isEmpty {
                try await sendUserFeedback(chatKey: chatKey, text: "Гостей премиума пока нет.\n\n<i>Проще всего пригласить ссылкой: /tenant invite</i>")
            } else {
                let list = users.map { "• \($0.label)" }.joined(separator: "\n")
                try await sendUserFeedback(chatKey: chatKey, text: "<b>👥 Гости премиума @\(username)</b> (\(users.count))\n\(list)")
            }

        case "invite":
            guard let username = invokerUsername else {
                try await sendUserFeedback(chatKey: chatKey, text: "У вас не задан @username.")
                return
            }
            guard await state.isTenant(username: username) else {
                try await sendUserFeedback(chatKey: chatKey, text: "Премиум неактивен — оформить: /buy")
                return
            }
            let wantsNew = arg1.lowercased() == "new"
            let existing = await state.inviteToken(owner: username)
            let token: String?
            if wantsNew || existing == nil {
                token = await state.regenerateInviteToken(owner: username)
            } else {
                token = existing
            }
            guard let token else {
                try await sendUserFeedback(chatKey: chatKey, text: "Не удалось создать ссылку — премиум не найден.")
                return
            }
            let link = "https://t.me/\(botUsername)?start=inv_\(token)"
            let renewedNote = wantsNew ? "\n<i>Старая ссылка больше не действует.</i>" : ""
            try await sendUserFeedback(chatKey: chatKey, text: """
                🔗 <b>Ваша ссылка-приглашение</b>

                \(link)

                Любой, кто откроет её и нажмёт «Начать», получит умные модели за ваш счёт и попадёт в список гостей (/tenant users).\(renewedNote)

                <code>/tenant invite new</code> — перевыпустить (старая перестанет работать)
                """)

        case "extend":
            let username = normalizeUsername(arg1)
            guard !username.isEmpty, let days = Int(arg2), days > 0 else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant extend @username &lt;дней&gt;</code>")
                return
            }
            if let until = await state.extendTenantSubscription(username: username, days: days) {
                let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy"
                try await sendUserFeedback(chatKey: chatKey, text: "✓ Подписка @\(username) продлена до <b>\(f.string(from: until))</b>.")
            } else {
                try await sendUserFeedback(chatKey: chatKey, text: "Tenant @\(username) не найден.")
            }

        case "unlimited":
            let username = normalizeUsername(arg1)
            guard !username.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant unlimited @username</code>")
                return
            }
            let ok = await state.setTenantUnlimited(username: username)
            try await sendUserFeedback(chatKey: chatKey, text: ok
                ? "✓ Подписка @\(username) теперь бессрочная."
                : "Tenant @\(username) не найден.")

        case "expire":
            let username = normalizeUsername(arg1)
            guard !username.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant expire @username</code>")
                return
            }
            let ok = await state.expireTenantSubscription(username: username)
            try await sendUserFeedback(chatKey: chatKey, text: ok
                ? "✓ Подписка @\(username) немедленно завершена (лицензия и настройки сохранены)."
                : "Tenant @\(username) не найден или это владелец бота.")

        case "markup":
            if arg1.isEmpty {
                let pct = await state.markupPercent()
                try await sendUserFeedback(chatKey: chatKey, text: """
                    💹 Наценка на цены моделей: <b>\(pct)%</b>

                    Применяется ко всем ценам, которые видят пользователи (футер, меню, /model), и к списаниям с балансов.
                    <i>Изменить:</i> <code>/tenant markup 30</code>
                    """)
            } else if let pct = Int(arg1), (0...500).contains(pct) {
                await state.setMarkupPercent(pct)
                try await sendUserFeedback(chatKey: chatKey, text: "✓ Наценка: <b>\(pct)%</b> (множитель ×\(String(format: "%.2f", 1.0 + Double(pct) / 100.0)))")
            } else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant markup &lt;0–500&gt;</code>")
            }


        case "stats":
            let rows = await state.tenantStats()
            if rows.isEmpty {
                try await sendUserFeedback(chatKey: chatKey, text: "Спонсоров пока нет.")
            } else {
                var lines = ["<b>📊 Статистика tenants</b>"]
                let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy"
                for row in rows {
                    let mark = row.isSuperAdmin ? "🛡" : "🛠"
                    let realStr = String(format: "$%.4f", row.usage.totalCost)
                    let billedStr = String(format: "$%.4f", await state.billedCost(of: row.usage))
                    let tokens = Int(row.usage.totalTokens)
                    let subscription: String
                    if let until = row.paidUntil {
                        subscription = row.isActive ? "до \(f.string(from: until))" : "⛔ истекла \(f.string(from: until))"
                    } else {
                        subscription = "бессрочно"
                    }
                    lines.append("\n\(mark) <b>@\(row.username)</b> · \(subscription)")
                    lines.append("  чатов <b>\(row.chatCount)</b> · юзеров <b>\(row.licensedUserCount)</b>")
                    lines.append("  запросов <b>\(row.usage.generationCount)</b> · токенов <b>\(tokens)</b>")
                    lines.append("  💵 реально <b>\(realStr)</b> · клиентская цена <b>\(billedStr)</b>")
                }
                try await sendUserFeedback(chatKey: chatKey, text: lines.joined(separator: "\n"))
            }

        case "freemodels":
            try await handleFreeModels(chatKey: chatKey, subcommand: arg1, value: arg2)

        case "cryptoprice":
            if arg1.isEmpty {
                let cents = await state.cryptoPriceUsdCents()
                if let cents {
                    let usd = Double(cents) / 100.0
                    try await sendUserFeedback(chatKey: chatKey, text: String(format: "🪙 Цена в крипто: <b>$%.2f</b>", usd))
                } else {
                    try await sendUserFeedback(chatKey: chatKey, text: "🪙 Крипто-оплата отключена.")
                }
            } else if arg1 == "0" || arg1.lowercased() == "off" {
                await state.setCryptoPriceUsdCents(nil)
                try await sendUserFeedback(chatKey: chatKey, text: "✓ Крипто-оплата отключена.")
            } else if let usd = Double(arg1.replacingOccurrences(of: ",", with: ".")), usd > 0 {
                let cents = Int((usd * 100.0).rounded())
                await state.setCryptoPriceUsdCents(cents)
                try await sendUserFeedback(chatKey: chatKey, text: String(format: "✓ Цена в крипто: <b>$%.2f</b>", Double(cents) / 100.0))
            } else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant cryptoprice 9.99</code> или <code>/tenant cryptoprice 0</code>")
            }

        case "cryptoaddr":
            try await handleCryptoAddr(chatKey: chatKey, subArg: arg1, value: arg2)

        case "cryptomode":
            try await handleCryptoMode(chatKey: chatKey, value: arg1)

        case "cryptopool":
            try await handleCryptoPool(chatKey: chatKey, subArg: arg1, value: arg2)

        case "cryptoinvoices":
            try await handleCryptoInvoices(chatKey: chatKey)

        case "price":
            if arg1.isEmpty {
                let price = await state.starsPrice()
                if let price {
                    try await sendUserFeedback(chatKey: chatKey, text: "💫 Цена доступа: <b>\(price) Stars</b>")
                } else {
                    try await sendUserFeedback(chatKey: chatKey, text: "💫 Продажа доступа отключена.")
                }
            } else if arg1 == "0" || arg1.lowercased() == "off" {
                await state.setStarsPrice(nil)
                try await sendUserFeedback(chatKey: chatKey, text: "✓ Продажа доступа отключена.")
            } else if let price = Int(arg1), price > 0 {
                await state.setStarsPrice(price)
                try await sendUserFeedback(chatKey: chatKey, text: "✓ Цена доступа: <b>\(price) Stars</b>")
            } else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant price &lt;число&gt;</code> или <code>/tenant price 0</code> (отключить)")
            }

        default:
            let adminHelp = """
                <b>⚡ Управление премиумом</b>

                <code>/tenant invite</code> — 🔗 ссылка-приглашение (проще всего поделиться доступом)
                <code>/tenant claim</code> — включить премиум в этом чате
                <code>/tenant release</code> — выключить в этом чате
                <code>/tenant assign @username &lt;номер чата&gt;</code> — включить в другом чате
                <code>/tenant unassign &lt;номер чата&gt;</code> — выключить в другом чате
                <code>/tenant chats</code> — чаты, где работает ваш премиум
                <code>/tenant adduser @username</code> — добавить гостя
                <code>/tenant removeuser @username</code> — убрать гостя
                <code>/tenant users</code> — список гостей
                <code>/chatid</code> — номер этого чата
                <code>/buy</code> — статус и продление премиума
                """
            let superHelp = """

                <b>🛡 Только суперадмин</b>
                <code>/tenant add @username</code> — зарегистрировать (бессрочно)
                <code>/tenant remove @username</code> — удалить
                <code>/tenant extend @username &lt;дней&gt;</code> — продлить подписку
                <code>/tenant unlimited @username</code> · <code>/tenant expire @username</code>
                <code>/tenant list</code> — все tenants
                <code>/tenant stats</code> — статистика и подписки
                <code>/tenant price &lt;число&gt;</code> — цена в Stars (0 = отключить)
                <code>/tenant freemodels add|remove|list|available &lt;id&gt;</code>
                <code>/tenant cryptoprice &lt;USD&gt;</code> — цена крипто-доступа
                <code>/tenant cryptoaddr &lt;chain&gt; &lt;addr&gt;|list</code>
                <code>/tenant cryptomode delta|unique</code>
                <code>/tenant cryptopool add|remove|list &lt;chain&gt; …</code>
                <code>/tenant cryptoinvoices</code> — открытые счета
                """
            let text = invokerIsSuper ? adminHelp + superHelp : adminHelp
            try await sendUserFeedback(chatKey: chatKey, text: text)
        }
    }

    private func handleSuperAdminCmd(chatKey: ChatKey, argument: String) async throws {
        let parts = argument.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        let subcommand = (parts.first ?? "").lowercased()
        let arg = parts.count > 1 ? parts[1] : ""

        func normalizeUsername(_ raw: String) -> String {
            raw.hasPrefix("@") ? String(raw.dropFirst()) : raw
        }

        switch subcommand {
        case "add":
            let username = normalizeUsername(arg.trimmingCharacters(in: .whitespaces))
            guard !username.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/superadmin add @username</code>")
                return
            }
            let ok = await state.addSuperAdmin(target: username)
            try await sendUserFeedback(chatKey: chatKey, text: ok
                ? "✓ @\(username) теперь суперадмин."
                : "@\(username) уже является суперадмином.")

        case "remove":
            let username = normalizeUsername(arg.trimmingCharacters(in: .whitespaces))
            guard !username.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/superadmin remove @username</code>")
                return
            }
            let ok = await state.removeSuperAdmin(target: username)
            try await sendUserFeedback(chatKey: chatKey, text: ok
                ? "✓ @\(username) больше не суперадмин."
                : "Нельзя удалить главного суперадмина или такого пользователя нет.")

        case "list":
            let supers = await state.listSuperAdmins()
            let list = supers.map { "• \($0.label)" }.joined(separator: "\n")
            try await sendUserFeedback(chatKey: chatKey, text: "<b>🛡 Суперадмины</b> (\(supers.count))\n\(list)")

        default:
            try await sendUserFeedback(chatKey: chatKey, text: """
                <b>🛡 Суперадмины</b>

                <code>/superadmin add @username</code>
                <code>/superadmin remove @username</code>
                <code>/superadmin list</code>

                <i>Только главный суперадмин может управлять списком.</i>
                """)
        }
    }

    private func handleSimulate(chatKey: ChatKey, fromUser: TelegramUser?, argument: String) async throws {
        guard let username = fromUser?.username else {
            try await sendUserFeedback(chatKey: chatKey, text: "У вас не задан username в Telegram.")
            return
        }

        let arg = argument.trimmingCharacters(in: .whitespaces).lowercased()

        func currentLabel() async -> String {
            switch await state.simulatedRole(username: username) {
            case .admin: return "админ"
            case .regularUser: return "обычный пользователь"
            case nil: return "выкл (суперадмин)"
            }
        }

        switch arg {
        case "":
            let label = await currentLabel()
            try await sendUserFeedback(chatKey: chatKey, text: """
                <b>🎭 Симуляция роли</b>

                Текущий режим · <b>\(label)</b>

                <code>/simulate admin</code> — тест от админа
                <code>/simulate user</code> — тест от обычного пользователя
                <code>/simulate buy</code> — тест покупки (активация подписки без оплаты)
                <code>/simulate off</code> — выключить
                <code>/simulate status</code> — статус

                <i>Действует только в текущем процессе бота, не сохраняется при рестарте.</i>
                """)

        case "status":
            let label = await currentLabel()
            try await sendUserFeedback(chatKey: chatKey, text: "🎭 Симуляция · <b>\(label)</b>")

        case "admin":
            await state.setSimulatedRole(username: username, role: .admin)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Симуляция включена · <b>админ</b>.\nЧтобы выключить — <code>/simulate off</code>.")

        case "user", "regular":
            await state.setSimulatedRole(username: username, role: .regularUser)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Симуляция включена · <b>обычный пользователь</b>.\nЧтобы выключить — <code>/simulate off</code>.")

        case "off", "выкл", "none":
            await state.setSimulatedRole(username: username, role: nil)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Симуляция выключена. Вы снова суперадмин.")

        case "buy":
            // Test purchase: exercises the same activation logic as a real
            // Stars payment, without money changing hands.
            let activation = await state.activatePaidSubscription(username: username)
            await state.assignChat(chatID: chatKey.chatID, to: username)
            let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy"
            let resultLine: String
            switch activation {
            case .started(let until):
                resultLine = "Создан tenant @\(username), подписка до <b>\(f.string(from: until))</b>."
            case .extended(let until):
                resultLine = "Подписка @\(username) продлена до <b>\(f.string(from: until))</b>."
            case .alreadyUnlimited:
                resultLine = "У @\(username) бессрочный доступ — активация ничего не меняет."
            }
            try await sendUserFeedback(chatKey: chatKey, text: """
                🧪 <b>Тест покупки выполнен.</b>
                \(resultLine)
                Этот чат привязан к лицензии @\(username).

                Откатить: <code>/tenant remove @\(username)</code>
                Проверить поведение подписки: /menu → Админ-панель, /buy
                """)

        default:
            try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/simulate admin|user|buy|off|status</code>")
        }
    }

    private func handleCryptoInvoices(chatKey: ChatKey) async throws {
        let invoices = await state.openCryptoInvoices()
        var lines: [String] = ["<b>🪙 Открытые счета</b> (\(invoices.count))"]
        if invoices.isEmpty {
            lines.append("<i>нет</i>")
        } else {
            let sorted = invoices.sorted { $0.createdAt < $1.createdAt }
            for inv in sorted.prefix(50) {
                let amount = CryptoAmountFormatter.format(atomic: inv.exactAmountAtomic, decimals: inv.asset.decimals)
                let received = CryptoAmountFormatter.format(atomic: inv.accumulatedAtomic, decimals: inv.asset.decimals)
                lines.append("• @\(inv.username) · \(inv.asset.displayLabel) · \(received)/\(amount) \(inv.asset.symbol) · \(inv.status.rawValue)")
            }
        }
        try await sendUserFeedback(chatKey: chatKey, text: lines.joined(separator: "\n"))
    }

    private func handleCryptoMode(chatKey: ChatKey, value: String) async throws {
        let v = value.trimmingCharacters(in: .whitespaces).lowercased()
        if v.isEmpty {
            let mode = await state.cryptoMatchMode()
            try await sendUserFeedback(chatKey: chatKey, text: "🪙 Режим: <b>\(mode.displayName)</b>\n<i>Использование:</i> <code>/tenant cryptomode delta|unique</code>")
            return
        }
        let target: CryptoMatchMode?
        switch v {
        case "delta", "amount", "amount_delta": target = .amountDelta
        case "unique", "address", "unique_address": target = .uniqueAddress
        default: target = nil
        }
        guard let mode = target else {
            try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant cryptomode delta|unique</code>")
            return
        }
        await state.setCryptoMatchMode(mode)
        try await sendUserFeedback(chatKey: chatKey, text: "✓ Режим: <b>\(mode.displayName)</b>")
    }

    private func handleCryptoPool(chatKey: ChatKey, subArg: String, value: String) async throws {
        let sub = subArg.trimmingCharacters(in: .whitespaces).lowercased()
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        let chainStr = parts.first ?? ""
        let arg2 = parts.count > 1 ? parts[1] : ""

        if sub.isEmpty || sub == "list" {
            let pools = await state.cryptoAddressPools()
            var lines: [String] = ["<b>🪙 Пулы адресов</b>"]
            for chain in CryptoChain.allCases {
                let pool = pools[chain] ?? []
                if pool.isEmpty {
                    lines.append("• \(chain.displayName) · <i>пусто</i>")
                } else {
                    lines.append("• \(chain.displayName) (\(pool.count))")
                    for (i, addr) in pool.enumerated() {
                        lines.append("  \(i). <code>\(addr)</code>")
                    }
                }
            }
            try await sendUserFeedback(chatKey: chatKey, text: lines.joined(separator: "\n"))
            return
        }

        guard let chain = CryptoChain(rawValue: chainStr.lowercased()) else {
            try await sendUserFeedback(chatKey: chatKey, text: "<i>Неизвестная сеть.</i> Используйте: <code>ton|bsc|eth|tron</code>")
            return
        }

        switch sub {
        case "add":
            let addr = arg2.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !addr.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant cryptopool add &lt;chain&gt; &lt;addr&gt;</code>")
                return
            }
            let added = await state.addCryptoPoolAddress(chain, address: addr)
            try await sendUserFeedback(chatKey: chatKey, text: added
                ? "✓ В пул \(chain.displayName) добавлен: <code>\(addr)</code>"
                : "Адрес уже в пуле.")
        case "remove":
            guard let index = Int(arg2) else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant cryptopool remove &lt;chain&gt; &lt;index&gt;</code>")
                return
            }
            let removed = await state.removeCryptoPoolAddress(chain, at: index)
            try await sendUserFeedback(chatKey: chatKey, text: removed
                ? "✓ Удалён из пула \(chain.displayName), индекс \(index)."
                : "Адрес с таким индексом не найден.")
        default:
            try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant cryptopool add|remove|list</code>")
        }
    }

    private func handleCryptoAddr(chatKey: ChatKey, subArg: String, value: String) async throws {
        let lower = subArg.lowercased()
        if lower.isEmpty || lower == "list" {
            let addrs = await state.cryptoAddresses()
            if addrs.isEmpty {
                try await sendUserFeedback(chatKey: chatKey, text: "🪙 Адреса не настроены.\n<i>Использование:</i> <code>/tenant cryptoaddr ton EQ...</code>")
                return
            }
            var lines = ["<b>🪙 Адреса для приёма</b>"]
            for chain in CryptoChain.allCases {
                if let addr = addrs[chain] {
                    lines.append("• \(chain.displayName) · <code>\(addr)</code>")
                }
            }
            try await sendUserFeedback(chatKey: chatKey, text: lines.joined(separator: "\n"))
            return
        }
        guard let chain = CryptoChain(rawValue: lower) else {
            try await sendUserFeedback(chatKey: chatKey, text: "<i>Неизвестная сеть.</i> Используйте: <code>ton</code>, <code>bsc</code>, <code>eth</code>, <code>tron</code>")
            return
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            await state.setCryptoAddress(chain, address: nil)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Адрес для \(chain.displayName) удалён.")
        } else {
            await state.setCryptoAddress(chain, address: trimmed)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Адрес для \(chain.displayName): <code>\(trimmed)</code>")
        }
    }

    private func handleFreeModels(chatKey: ChatKey, subcommand: String, value: String) async throws {
        switch subcommand.lowercased() {
        case "add":
            let id = value.trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant freemodels add &lt;model-id&gt;</code>")
                return
            }
            let added = await state.addFreeModel(id)
            try await sendUserFeedback(chatKey: chatKey, text: added
                ? "✓ Бесплатная модель добавлена: <code>\(id)</code>"
                : "Модель <code>\(id)</code> уже в списке.")

        case "remove":
            let id = value.trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant freemodels remove &lt;model-id&gt;</code>")
                return
            }
            let removed = await state.removeFreeModel(id)
            try await sendUserFeedback(chatKey: chatKey, text: removed
                ? "✓ Модель <code>\(id)</code> удалена из бесплатных."
                : "Модель <code>\(id)</code> не найдена в списке.")

        case "list":
            let ids = await state.freeModelIDs()
            if ids.isEmpty {
                try await sendUserFeedback(chatKey: chatKey, text: "💡 Список бесплатных моделей пуст — все модели доступны всем.")
            } else {
                let list = ids.enumerated().map { "\($0.offset + 1). <code>\($0.element)</code>" }.joined(separator: "\n")
                try await sendUserFeedback(chatKey: chatKey, text: "<b>Бесплатные модели</b> (\(ids.count))\n\(list)")
            }

        case "available":
            guard let monitor = modelPriceMonitor else {
                try await sendUserFeedback(chatKey: chatKey, text: "⚠️ Мониторинг моделей недоступен.")
                return
            }
            try await sendUserFeedback(chatKey: chatKey, text: "⏳ Запрашиваю список бесплатных моделей OpenRouter…")
            let freeModels = try await monitor.fetchCurrentFreeModels()
            if freeModels.isEmpty {
                try await sendUserFeedback(chatKey: chatKey, text: "Бесплатных моделей на OpenRouter сейчас нет.")
            } else {
                let list = freeModels.map { "• <code>\($0.id)</code>" }.joined(separator: "\n")
                try await sendUserFeedback(chatKey: chatKey, text: "<b>🆓 Бесплатные модели OpenRouter сейчас</b> (\(freeModels.count))\n\(list)")
            }

        default:
            let ids = await state.freeModelIDs()
            let status = ids.isEmpty
                ? "<i>Список пуст — все модели доступны всем.</i>"
                : ids.map { "• <code>\($0)</code>" }.joined(separator: "\n")
            try await sendUserFeedback(chatKey: chatKey, text: """
                <b>🆓 Бесплатные модели</b>

                \(status)

                <code>/tenant freemodels add &lt;id&gt;</code>
                <code>/tenant freemodels remove &lt;id&gt;</code>
                <code>/tenant freemodels list</code>
                <code>/tenant freemodels available</code> — актуальный список от OpenRouter
                """)
        }
    }

    private func handleBuy(chatKey: ChatKey, fromUser: TelegramUser?) async throws {
        let starsPrice = await state.starsPrice()
        let cryptoPriceCents = await state.cryptoPriceUsdCents()
        let cryptoAssets: [CryptoAsset] = await {
            guard let service = cryptoService else { return [] }
            return await service.availableAssets()
        }()
        let cryptoAvailable = cryptoPriceCents != nil && !cryptoAssets.isEmpty
        let card = await state.cardConfig()
        let cardAvailable = card.isEnabled

        // Credit packs are sold through their own switches (Stars rate / crypto
        // addresses / card FX rate), so /buy stays useful even when monthly
        // subscriptions are switched off (roadmap step 2).
        let creditsAvailable = await state.starsCreditsEnabled() || cryptoAvailable || card.creditsEnabled
        guard (starsPrice ?? 0) > 0 || cryptoAvailable || cardAvailable || creditsAvailable else {
            try await sendUserFeedback(chatKey: chatKey, text: "ℹ️ Продажа доступа сейчас недоступна.")
            return
        }
        guard let buyerID = fromUser?.id else { return }
        // Purchases identify the buyer by userID, so a @username is optional.
        let username = state.userKey(userID: buyerID)
        await state.bumpPurchaseOpen(source: .command)
        // Prices for this user: a live winback discount (roadmap step 8) is
        // already applied, so quotes here match what checkout will charge.
        let pricing = await state.subscriptionPricing(username: username)
        // Existing tenant: unlimited → nothing to buy; with an expiry →
        // the same purchase flow extends the subscription.
        if await state.isTenant(username: username) {
            let sub = await state.tenantSubscription(ownerUsername: username)
            if sub.paidUntil == nil {
                try await sendUserFeedback(chatKey: chatKey, text: "✅ У вас бессрочный доступ к боту.")
                return
            }
            let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy"
            let statusLine = sub.isActive
                ? "Ваша подписка активна до <b>\(f.string(from: sub.paidUntil!))</b>."
                : "⛔ Ваша подписка истекла <b>\(f.string(from: sub.paidUntil!))</b>."
            var text = statusLine + "\nОплата ниже продлит её на \(ChatContextStore.subscriptionDays) дней."
            if let discount = pricing.discount, pricing.hasDiscount {
                let df = DateFormatter(); df.dateFormat = "dd.MM HH:mm"
                text += "\n🎁 Ваша скидка <b>−\(discount.percent)%</b> действует до <b>\(df.string(from: discount.expiresAt))</b>."
            }
            try await sendUserFeedback(chatKey: chatKey, text: text)
        }

        // Exactly one way to pay and nothing cheaper to offer → straight to the
        // invoice; otherwise show the choice, so the low-threshold top-up is
        // never hidden behind a single-method shortcut.
        let methodCount = ((starsPrice ?? 0) > 0 ? 1 : 0) + (cryptoAvailable ? 1 : 0) + (cardAvailable ? 1 : 0)
        let discountNote = pricing.hasDiscount ? " · скидка −\(pricing.discount?.percent ?? 0)%" : ""
        if methodCount == 1, !creditsAvailable {
            if let starsAmount = pricing.stars, starsAmount > 0 {
                try await telegram.sendInvoice(.init(
                    chatID: chatKey.chatID,
                    title: "Премиум-доступ · \(ChatContextStore.subscriptionDays) дней\(discountNote)",
                    description: "Умные модели (GPT, Claude, Gemini), без рекламы и лимитов — для этого чата и вашей лички",
                    payload: "buy_access",
                    starsAmount: starsAmount
                ))
                await state.bumpFunnel(.invoiceSent)
                return
            }
            if cryptoAvailable {
                await menuHandler.sendCryptoAssetChoice(chatKey: chatKey, username: username)
                return
            }
            if cardAvailable, let token = card.providerToken, let minorUnits = pricing.cardMinorUnits {
                try await telegram.sendInvoice(.init(
                    chatID: chatKey.chatID,
                    title: "Премиум-доступ · \(ChatContextStore.subscriptionDays) дней\(discountNote)",
                    description: "Умные модели (GPT, Claude, Gemini), без рекламы и лимитов — для этого чата и вашей лички",
                    payload: "buy_access_card",
                    kind: .fiat(currency: card.currency.rawValue, amountMinorUnits: minorUnits, providerToken: token)
                ))
                await state.bumpFunnel(.invoiceSent)
                return
            }
        }

        // Several methods available → choice menu
        var rows: [[InlineKeyboardButton]] = []
        if let starsAmount = pricing.stars, starsAmount > 0 {
            rows.append([InlineKeyboardButton(
                text: "💫 Stars · \(starsAmount) ⭐\(discountNote)",
                callback_data: BotCallbackAction.menu(action: "buy:stars").rawData
            )])
        }
        if cryptoAvailable, let cents = pricing.cryptoCents {
            let label = String(format: "🪙 Криптовалюта · $%.2f", Double(cents) / 100.0)
            rows.append([InlineKeyboardButton(
                text: label,
                callback_data: BotCallbackAction.menu(action: "buy:crypto").rawData
            )])
        }
        if cardAvailable, let minorUnits = pricing.cardMinorUnits {
            rows.append([InlineKeyboardButton(
                text: "💳 Картой · \(card.currency.format(minorUnits: minorUnits))",
                callback_data: BotCallbackAction.menu(action: "buy:card").rawData
            )])
        }
        // Lower entry point right next to the monthly price: a top-up is the
        // first payment most people are willing to make (roadmap step 2).
        var creditsNote = ""
        if creditsAvailable {
            rows.append(CreditPack.centsOptions.map {
                InlineKeyboardButton(
                    text: "💰 \(CreditPack.label(cents: $0))",
                    callback_data: BotCallbackAction.menu(action: "buy:credits:\($0)").rawData
                )
            })
            creditsNote = "\n\n💰 <b>Не готовы на месяц?</b> Пополните баланс — с него списывается стоимость каждого ответа, обычно доли цента. Подписка при этом не нужна."
        }
        let markup = InlineKeyboardMarkup(inline_keyboard: rows)
        _ = try await telegram.sendMessage(.init(
            chatID: chatKey.chatID,
            threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
            replyTo: nil,
            text: """
            <b>💳 Выберите способ оплаты</b>

            Доступ включится автоматически сразу после оплаты.\(creditsNote)
            """,
            replyMarkup: markup
        ))
    }

    private func handleHistory(chatKey: ChatKey) async throws {
        let messages = await state.history(chatKey: chatKey)
        guard !messages.isEmpty else {
            try await sendUserFeedback(chatKey: chatKey, text: "📝 Бот пока ничего не помнит — переписки нет.")
            return
        }

        var lines: [String] = ["<b>📝 Что бот помнит</b> (\(messages.count))"]
        for msg in messages {
            let roleLabel: String
            switch msg.role {
            case "system": roleLabel = "⚙️"
            case "user": roleLabel = "👤"
            case "assistant": roleLabel = "🤖"
            default: roleLabel = msg.role
            }

            let content: String
            switch msg.content {
            case .text(let text):
                content = text
            case .parts(let parts):
                let textParts = parts.compactMap { $0.text }
                let mediaTags = parts.compactMap { part -> String? in
                    if part.inputImage != nil { return "[изображение]" }
                    if part.inputAudio != nil { return "[аудио]" }
                    if part.inputVideo != nil { return "[видео]" }
                    return nil
                }
                content = (textParts.joined(separator: " ") + " " + mediaTags.joined(separator: " ")).trimmingCharacters(in: .whitespaces)
            }
            let displayContent = content.isEmpty ? "<i>(пусто)</i>" : truncateForHistory(content)
            lines.append("\n\(roleLabel) \(displayContent)")
        }

        try await sendUserFeedback(chatKey: chatKey, text: lines.joined(separator: "\n"))
    }

    private func truncateForHistory(_ text: String) -> String {
        let limit = 280
        guard text.count > limit else { return text }
        let endIndex = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<endIndex]) + "…"
    }

    private func sendUserFeedback(chatKey: ChatKey, text: String) async throws {
        _ = try await telegram.sendMessage(
            .init(
                chatID: chatKey.chatID,
                threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                replyTo: nil,
                text: text,
                replyMarkup: nil
            )
        )
    }
}
