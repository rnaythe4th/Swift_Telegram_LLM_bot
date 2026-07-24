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

    init(
        telegram: TelegramGatewayPort,
        state: ChatContextStore,
        gateways: ProviderGatewayRegistry,
        botUsername: String,
        formatOptions: String,
        menuHandler: BotMenuHandler,
        modelPriceMonitor: ModelPriceMonitor? = nil,
        cryptoService: CryptoPaymentService? = nil
    ) {
        self.telegram = telegram
        self.state = state
        self.gateways = gateways
        self.botUsername = botUsername
        self.formatOptions = formatOptions
        self.menuHandler = menuHandler
        self.modelPriceMonitor = modelPriceMonitor
        self.cryptoService = cryptoService
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

        case .setRole:
            let trimmed = parsed.argument.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: """
                    🎭 Укажите текст роли.
                    <i>Пример:</i> <code>/setrole Ты — эксперт по математике, отвечай кратко.</code>
                    """)
                return
            }
            _ = await state.setRoleAndResetHistory(chatKey: chatKey, role: trimmed + formatOptions)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Роль обновлена. История очищена.")

        case .clearHistory:
            await state.clearHistory(chatKey: chatKey)
            try await sendUserFeedback(chatKey: chatKey, text: "🧹 История очищена.")

        case .setTemp:
            guard let temp = Float(parsed.argument), (0.0...2.0).contains(temp) else {
                let hint = "<i>Нужно число от 0.0 до 2.0.</i>\n<i>Пример:</i> <code>/settemp 1.0</code>"
                try await sendUserFeedback(chatKey: chatKey, text: hint)
                return
            }
            await state.setTemperature(chatKey: chatKey, value: temp)
            let bucket = BotMenuHandler.tempBucket(temp)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Темп: <b>\(BotMenuHandler.formatTemp(temp))</b> — \(bucket)")

        case .model:
            let trimmed = parsed.argument.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: """
                    🤖 Укажите модель.
                    <i>Пример:</i> <code>/model openai/gpt-4o</code>
                    <i>С провайдером (роутинг OpenRouter):</i> <code>/model deepseek/deepseek-v4-pro | deepseek</code>
                    Готовые варианты — /menu → Модель
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
            let hasAccess = await state.hasFullModelAccess(username: fromUser?.username, userID: fromUser?.id, chatID: chatKey.chatID)
            let effectiveFree = await state.effectiveFreeModelIDs()
            if !hasAccess, let eff = effectiveFree, !eff.contains(modelID) {
                let price = await state.starsPrice()
                let buyHint = price.map { "\n\nКупить полный доступ (\($0) ⭐): /buy" } ?? "\n\nОформите полный доступ: /buy"
                try await sendUserFeedback(chatKey: chatKey, text: "⭐ <b>\(modelID)</b> — модель с полным доступом.\(buyHint)")
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
            let providerNote = providerRouting.map { "\nПровайдер: <code>\($0)</code>" } ?? ""
            try await sendUserFeedback(chatKey: chatKey, text: """
                ✓ Модель: <code>\(changed.new)</code>\(providerNote)
                <i>Была:</i> <code>\(changed.old)</code>
                История очищена.\(priceNote)
                """)

        case .showTokens:
            let new = await state.toggleShowStats(chatKey: chatKey)
            try await sendUserFeedback(chatKey: chatKey, text: "📊 Показ токенов · <b>\(onOff(new))</b>")

        case .showCost:
            let new = await state.toggleShowCost(chatKey: chatKey)
            try await sendUserFeedback(chatKey: chatKey, text: "💵 Показ стоимости · <b>\(onOff(new))</b>")

        case .showModel:
            let new = await state.toggleShowModel(chatKey: chatKey)
            try await sendUserFeedback(chatKey: chatKey, text: "🤖 Показ модели · <b>\(onOff(new))</b>")

        case .backupNotify:
            let new = await state.toggleBackupNotify(chatKey: chatKey)
            try await sendUserFeedback(chatKey: chatKey, text: "💾 Уведомления о бэкапе · <b>\(onOff(new))</b>")

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
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Роль сброшена к стандартной. История очищена.")

        case .historyLength:
            guard let newMax = Int(parsed.argument), (1...50).contains(newMax) else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Нужно число от 1 до 50.</i>\n<i>Пример:</i> <code>/historylength 11</code>")
                return
            }
            await state.setMaxHistory(chatKey: chatKey, newMax: newMax)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Длина истории: <b>\(newMax) сообщ.</b>")

        case .provider:
            if let provider = ServiceProvider.parse(parsed.argument) {
                let old = await state.changeProvider(chatKey: chatKey, newProvider: provider)
                var lines = ["✓ Провайдер: <b>\(provider.commandValue)</b>"]
                if old != provider {
                    lines.append("<i>Был:</i> <b>\(old.commandValue)</b>")
                }

                let gateway = try gateways.gateway(for: provider)
                let reasoningEnabled = await state.reasoningEnabled(chatKey: chatKey)
                if reasoningEnabled, !gateway.capabilities.supportsReasoning {
                    await state.setReasoningEffort(chatKey: chatKey, effort: nil)
                    lines.append("<i>Reasoning отключён — провайдер не поддерживает.</i>")
                }
                try await sendUserFeedback(chatKey: chatKey, text: lines.joined(separator: "\n"))
            } else {
                try await sendUserFeedback(chatKey: chatKey, text: "Неизвестный провайдер. Доступны: <code>deepseek</code>, <code>openrouter</code>, <code>yandex</code>.")
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
                    text: "🧠 Провайдер <b>\(provider.commandValue)</b> не поддерживает reasoning."
                )
                return
            }

            let arg = parsed.argument.trimmingCharacters(in: .whitespaces).lowercased()
            if let effort = ReasoningEffort(rawValue: arg) {
                await state.setReasoningEffort(chatKey: chatKey, effort: effort)
            } else if arg == "off" || arg == "выкл" {
                await state.setReasoningEffort(chatKey: chatKey, effort: nil)
            } else if arg.isEmpty {
                _ = await state.toggleReasoning(chatKey: chatKey)
            } else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/reasoning low|medium|high|off</code>")
                return
            }
            let current = await state.reasoningEffort(chatKey: chatKey)
            try await sendUserFeedback(chatKey: chatKey, text: "🧠 Reasoning · <b>\(current?.rawValue ?? "выкл")</b>")

        case .menu:
            await menuHandler.sendMenu(chatKey: chatKey, username: fromUser?.username)

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
        // Deep-link invite: t.me/<bot>?start=inv_<token> — grants paid-model
        // access under the issuing admin's licence.
        let payload = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        if payload.hasPrefix("inv_") {
            try await handleInviteRedemption(token: String(payload.dropFirst(4)), chatKey: chatKey, fromUser: fromUser)
            return
        }
        try await sendStartGreeting(chatKey: chatKey)
    }

    private func handleInviteRedemption(token: String, chatKey: ChatKey, fromUser: TelegramUser?) async throws {
        guard let owner = await state.redeemInvite(token: token) else {
            try await sendUserFeedback(chatKey: chatKey, text: """
                ⚠️ Пригласительная ссылка недействительна или её лицензия неактивна.
                Попросите у администратора новую ссылку.
                """)
            try await sendStartGreeting(chatKey: chatKey)
            return
        }

        if let username = fromUser?.username, username.lowercased() == owner {
            try await sendUserFeedback(chatKey: chatKey, text: "ℹ️ Это ваша собственная пригласительная ссылка — доступ у вас и так есть.")
            return
        }

        var grantedLines: [String] = []
        if let username = fromUser?.username {
            _ = await state.addLicensedUser(ownerUsername: owner, target: username)
            grantedLines.append("• платные модели доступны вам (@\(username)) во всех чатах с этим ботом")
        }
        // Private chat: attach it to the inviter's licence so access works
        // even without a @username.
        if chatKey.chatID > 0, await state.chatOwner(chatID: chatKey.chatID) == nil {
            _ = await state.assignChat(chatID: chatKey.chatID, to: owner)
            grantedLines.append("• этот чат подключён к лицензии @\(owner)")
        }

        guard !grantedLines.isEmpty else {
            try await sendUserFeedback(chatKey: chatKey, text: """
                ⚠️ Не удалось активировать приглашение: у вас нет @username, а этот чат уже привязан к другой лицензии.
                """)
            return
        }

        try await sendUserFeedback(chatKey: chatKey, text: """
            🎟 <b>Приглашение от @\(owner) активировано!</b>

            \(grantedLines.joined(separator: "\n"))

            Просто напишите сообщение — бот ответит. Настройки: /menu
            """)
    }

    private func handleChatID(chatKey: ChatKey) async throws {
        let owner = await state.chatOwner(chatID: chatKey.chatID)
        let meta = await state.chatMeta(chatID: chatKey.chatID)
        var lines = ["<b>🆔 Этот чат</b>", ""]
        lines.append("ID · <code>\(chatKey.chatID)</code>")
        if chatKey.threadID != 0 {
            lines.append("Топик (thread) · <code>\(chatKey.threadID)</code>")
        }
        if let meta {
            lines.append("Тип · \(meta.type)" + (meta.title.map { " · «\($0)»" } ?? ""))
        }
        lines.append(owner.map { "Лицензия · @\($0)" } ?? "Лицензия · <i>не привязан</i>")
        lines.append("")
        lines.append("<i>Привязать чат к своей лицензии: /tenant claim (для админов)</i>")
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
        let owner = await state.chatOwner(chatID: targetChatID)
        let keys = await state.existingContextKeys(chatID: targetChatID)

        guard !keys.isEmpty else {
            try await sendUserFeedback(chatKey: chatKey, text: "Чат <code>\(targetChatID)</code> ещё не общался с ботом.")
            return
        }

        var lines = ["<b>👁 \(label)</b> · <code>\(targetChatID)</code>"]
        lines.append(owner.map { "Лицензия · @\($0)" } ?? "Лицензия · <i>нет (бесплатный)</i>")

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
        let text = """
        <b>👋 Привет!</b> Я — умный ИИ-ассистент в Telegram.

        Напишите мне — отвечу. Понимаю текст, фото, голос и видео, помню разговор.

        <b>Хотите умного ИИ в свой групповой чат?</b> Меня можно добавить — премиум откроет любой участник, и доступ заработает сразу для всех.

        ⚙️ /menu · 📘 /help
        """
        let markup = InlineKeyboardMarkup(inline_keyboard: [
            [InlineKeyboardButton(text: "⚙️ Открыть меню", callback_data: BotCallbackAction.menu(action: "open").rawData)],
            [InlineKeyboardButton(text: "📘 Инструкция", callback_data: BotCallbackAction.faq.rawData)],
        ])
        _ = try await telegram.sendMessage(.init(
            chatID: chatKey.chatID,
            threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
            replyTo: nil,
            text: text,
            replyMarkup: markup
        ))
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
                        lines.append("• <b>@\(entry.username)</b> · остаток <b>\(formatUsd(w.balanceUsd))</b>")
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

        // Personal view (everyone, incl. superadmin without subcommand)
        guard let username = fromUser?.username else {
            try await sendUserFeedback(chatKey: chatKey, text: "⚠️ Для баланса нужен @username в Telegram.")
            return
        }
        guard let wallet = await state.balance(username: username) else {
            var lines = ["💰 У вас нет кошелька. Баланс — способ платить за платные модели по факту использования, без подписки."]
            if isSuper {
                lines.append("\n<i>Суперадмин:</i> <code>/balance add @\(username) 5</code> — начислить себе, <code>/balance list</code> — все кошельки.")
            } else {
                lines.append("Чтобы открыть баланс, обратитесь к администратору бота. Подписка — /buy.")
            }
            try await sendUserFeedback(chatKey: chatKey, text: lines.joined(separator: "\n"))
            return
        }

        let status = wallet.balanceUsd > 0
            ? "🟢 активен — платные модели доступны"
            : "⛔ исчерпан — доступны только бесплатные модели"
        var lines = ["<b>💰 Ваш баланс</b>", ""]
        lines.append("Остаток · <b>\(formatUsd(wallet.balanceUsd))</b>")
        lines.append("Потрачено всего · \(formatUsd(wallet.spentBilledUsd))")
        lines.append(status)
        lines.append("")
        lines.append("<i>Списание за каждый ответ видно в футере сообщений (включите /show_cost). Пополнение — у администратора бота.</i>")
        if isSuper {
            lines.append("<i>Реально потрачено (суперадмин): \(formatUsd(wallet.spentRealUsd)) · маржа \(formatUsd(wallet.spentBilledUsd - wallet.spentRealUsd))</i>")
        }
        try await sendUserFeedback(chatKey: chatKey, text: lines.joined(separator: "\n"))
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
            lines.append("")
            lines.append("""
                <code>/ads add &lt;текст&gt;</code> — создать
                <code>/ads freq &lt;id&gt; &lt;N&gt; [мин]</code> — частота: каждые N ответов, пауза
                <code>/ads limit &lt;id&gt; &lt;показов&gt; [дней]</code> — лимит с равномерным пейсингом
                <code>/ads button &lt;id&gt; &lt;текст&gt; | &lt;url&gt;</code> — кнопка-ссылка
                <code>/ads text &lt;id&gt; &lt;текст&gt;</code> · <code>on|off|remove &lt;id&gt;</code>

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
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/whitelist add &lt;ID&gt;</code>")
                return
            }
            await state.addToWhitelist(userID: userID, chatID: chatKey.chatID)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Пользователь <code>\(userID)</code> добавлен в белый список.")

        case "remove":
            guard let userID = Int(value) else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/whitelist remove &lt;ID&gt;</code>")
                return
            }
            await state.removeFromWhitelist(userID: userID, chatID: chatKey.chatID)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Пользователь <code>\(userID)</code> удалён из белого списка.")

        case "list":
            let ids = await state.listWhitelisted(chatID: chatKey.chatID)
            if ids.isEmpty {
                try await sendUserFeedback(chatKey: chatKey, text: "Белый список пуст.")
            } else {
                let sorted = ids.sorted()
                let list = sorted.map { "• <code>\($0)</code>" }.joined(separator: "\n")
                try await sendUserFeedback(chatKey: chatKey, text: "<b>Белый список</b> (\(sorted.count))\n\(list)")
            }

        default:
            try await sendUserFeedback(chatKey: chatKey, text: """
                <b>/whitelist</b>
                <code>/whitelist add &lt;ID&gt;</code> — добавить
                <code>/whitelist remove &lt;ID&gt;</code> — удалить
                <code>/whitelist list</code> — показать
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
                📝 История · <b>\(defs.historyLength) сообщ.</b>
                🎭 Роль:
                <blockquote expandable>\(defs.role)</blockquote>

                <b>Команды:</b>
                <code>/defaults model &lt;id&gt;</code>
                <code>/defaults role &lt;текст&gt;</code>
                <code>/defaults historylength &lt;1–50&gt;</code>

                <i>Управление пресетами меню — /presets</i>
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

            <i>Добавить в whitelist:</i> <code>/whitelist add &lt;ID&gt;</code>
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
                <b>🎛 Пресеты меню</b>

                <code>/presets &lt;тип&gt; add &lt;label&gt; | &lt;value&gt;</code>
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
                    <i>Использование:</i> <code>/presets \(typeKey) add &lt;label&gt; | &lt;value&gt;</code>
                    <i>Пример:</i> <code>/presets model add Gemini 3 Flash | google/gemini-3-flash-preview</code>
                    <i>Модель с провайдером:</i> <code>/presets model add DeepSeek V4 | deepseek/deepseek-v4-pro | deepseek</code>
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
                text: "✓ Пресет \(typeName): <b>\(preset.display)</b> → <code>\(preset.value)</code>\(providerNote)"
            )

        case "remove":
            guard !value.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/presets \(typeKey) remove &lt;value&gt;</code>")
                return
            }
            let removed = await remove(value)
            try await sendUserFeedback(
                chatKey: chatKey,
                text: removed
                    ? "✓ Пресет \(typeName) <code>\(value)</code> удалён."
                    : "Пресет \(typeName) <code>\(value)</code> не найден."
            )

        case "list":
            let presets = await list()
            if presets.isEmpty {
                try await sendUserFeedback(chatKey: chatKey, text: "Пресеты \(typeName): пусто.")
            } else {
                var lines = ["<b>Пресеты \(typeName)</b> (\(presets.count))"]
                for (i, p) in presets.enumerated() {
                    let providerNote = p.provider.map { " · <code>\($0)</code>" } ?? ""
                    lines.append("\(i). <b>\(p.display)</b> → <code>\(p.value)</code>\(providerNote)")
                }
                try await sendUserFeedback(chatKey: chatKey, text: lines.joined(separator: "\n"))
            }

        default:
            try await sendUserFeedback(chatKey: chatKey, text: """
                <b>/presets \(typeKey)</b>
                <code>/presets \(typeKey) add &lt;label&gt; | &lt;value&gt;</code>
                <code>/presets \(typeKey) remove &lt;value&gt;</code>
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

        let invokerUsername = fromUser?.username?.lowercased()
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
                try await sendUserFeedback(chatKey: chatKey, text: "Tenants: пусто.")
            } else {
                let list = tenants.map { "• @\($0)" }.joined(separator: "\n")
                try await sendUserFeedback(chatKey: chatKey, text: "<b>🏢 Tenants</b> (\(tenants.count))\n\(list)")
            }

        case "assign":
            let username = normalizeUsername(arg1)
            // Admins may only assign chats to themselves; super may assign to anyone.
            if !invokerIsSuper, username.lowercased() != invokerUsername {
                try await sendUserFeedback(chatKey: chatKey, text: "🔒 Можно привязать чат только к своей лицензии.")
                return
            }
            guard !username.isEmpty, let chatID = Int(arg2) else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant assign @username &lt;chatID&gt;</code>")
                return
            }
            let ok = await state.assignChat(chatID: chatID, to: username)
            try await sendUserFeedback(chatKey: chatKey, text: ok
                ? "✓ Chat <code>\(chatID)</code> назначен @\(username)."
                : "Tenant @\(username) не найден.")

        case "unassign":
            guard let chatID = Int(arg1) else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant unassign &lt;chatID&gt;</code>")
                return
            }
            let owner = await state.chatOwner(chatID: chatID)
            if !invokerIsSuper, owner?.lowercased() != invokerUsername {
                try await sendUserFeedback(chatKey: chatKey, text: "🔒 Этот чат не привязан к вашей лицензии.")
                return
            }
            let removed = await state.unassignChat(chatID: chatID)
            try await sendUserFeedback(chatKey: chatKey, text: removed != nil
                ? "✓ Chat <code>\(chatID)</code> отвязан от @\(removed!)."
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
                : "Tenant @\(username) не найден — оплатите доступ через /buy.")

        case "release":
            // Admin detaches the current chat from their licence.
            let owner = await state.chatOwner(chatID: chatKey.chatID)
            if !invokerIsSuper, owner?.lowercased() != invokerUsername {
                try await sendUserFeedback(chatKey: chatKey, text: "🔒 Этот чат не привязан к вашей лицензии.")
                return
            }
            let removed = await state.unassignChat(chatID: chatKey.chatID)
            try await sendUserFeedback(chatKey: chatKey, text: removed != nil
                ? "✓ Этот чат отвязан от @\(removed!)."
                : "Этот чат не был привязан.")

        case "chats":
            // Admin → own chats; super → all (already covered by /chats).
            guard let username = invokerUsername else {
                try await sendUserFeedback(chatKey: chatKey, text: "У вас не задан @username.")
                return
            }
            let chats = await state.chatsOwnedBy(username)
            if chats.isEmpty {
                try await sendUserFeedback(chatKey: chatKey, text: "У вашей лицензии нет привязанных чатов.")
            } else {
                let list = chats.sorted().map { "• <code>\($0)</code>" }.joined(separator: "\n")
                try await sendUserFeedback(chatKey: chatKey, text: "<b>📌 Чаты лицензии @\(username)</b> (\(chats.count))\n\(list)")
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
                ? "✓ @\(target) получил доступ к платным моделям по вашей лицензии."
                : "@\(target) уже в списке или ваша лицензия не активна.")

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
                ? "✓ @\(target) удалён из списка лицензированных."
                : "@\(target) не найден в списке лицензированных.")

        case "users":
            guard let username = invokerUsername else {
                try await sendUserFeedback(chatKey: chatKey, text: "У вас не задан @username.")
                return
            }
            let users = await state.licensedUsers(ownerUsername: username)
            if users.isEmpty {
                try await sendUserFeedback(chatKey: chatKey, text: "В вашей лицензии нет добавленных пользователей.\n\n<i>Удобнее всего — пригласительная ссылка: /tenant invite</i>")
            } else {
                let list = users.map { "• @\($0)" }.joined(separator: "\n")
                try await sendUserFeedback(chatKey: chatKey, text: "<b>👥 Лицензированные пользователи @\(username)</b> (\(users.count))\n\(list)")
            }

        case "invite":
            guard let username = invokerUsername else {
                try await sendUserFeedback(chatKey: chatKey, text: "У вас не задан @username.")
                return
            }
            guard await state.isTenant(username: username) else {
                try await sendUserFeedback(chatKey: chatKey, text: "Лицензия не активна — оформите доступ: /buy")
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
                try await sendUserFeedback(chatKey: chatKey, text: "Не удалось создать ссылку — лицензия не найдена.")
                return
            }
            let link = "https://t.me/\(botUsername)?start=inv_\(token)"
            let renewedNote = wantsNew ? "\n<i>Старая ссылка больше не действует.</i>" : ""
            try await sendUserFeedback(chatKey: chatKey, text: """
                🔗 <b>Пригласительная ссылка вашей лицензии</b>

                \(link)

                Любой, кто откроет её и нажмёт Start, получит доступ к платным моделям за ваш счёт (и попадёт в список /tenant users).\(renewedNote)

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
                try await sendUserFeedback(chatKey: chatKey, text: "Tenants: пусто.")
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
                <b>🏢 Управление лицензией</b>

                <code>/tenant invite</code> — 🔗 пригласительная ссылка (самый простой способ дать доступ)
                <code>/tenant claim</code> — привязать этот чат к вашей лицензии
                <code>/tenant release</code> — отвязать этот чат
                <code>/tenant assign @username &lt;chatID&gt;</code> — привязать чат вручную
                <code>/tenant unassign &lt;chatID&gt;</code> — отвязать чат
                <code>/tenant chats</code> — чаты вашей лицензии
                <code>/tenant adduser @username</code> — дать пользователю доступ
                <code>/tenant removeuser @username</code> — отозвать доступ
                <code>/tenant users</code> — лицензированные пользователи
                <code>/chatid</code> — ID текущего чата
                <code>/buy</code> — статус и продление подписки
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
            let list = supers.map { "• @\($0)" }.joined(separator: "\n")
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

        guard (starsPrice ?? 0) > 0 || cryptoAvailable || cardAvailable else {
            try await sendUserFeedback(chatKey: chatKey, text: "ℹ️ Продажа доступа сейчас недоступна.")
            return
        }
        guard let username = fromUser?.username else {
            try await sendUserFeedback(chatKey: chatKey, text: """
                ⚠️ <b>Для покупки нужен username в Telegram.</b>

                Установите @username в настройках Telegram и попробуйте снова.
                """)
            return
        }
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
            try await sendUserFeedback(chatKey: chatKey, text: statusLine + "\nОплата ниже продлит её на \(ChatContextStore.subscriptionDays) дней.")
        }

        // Single method available → go straight; several → show choice menu.
        let methodCount = ((starsPrice ?? 0) > 0 ? 1 : 0) + (cryptoAvailable ? 1 : 0) + (cardAvailable ? 1 : 0)
        if methodCount == 1 {
            if let starsPrice, starsPrice > 0 {
                try await telegram.sendInvoice(.init(
                    chatID: chatKey.chatID,
                    title: "Подписка на бота · \(ChatContextStore.subscriptionDays) дней",
                    description: "Персональная копия ИИ-бота: платные модели, свои чаты и пользователи",
                    payload: "buy_access",
                    starsAmount: starsPrice
                ))
                return
            }
            if cryptoAvailable {
                await menuHandler.sendCryptoAssetChoice(chatKey: chatKey)
                return
            }
            if cardAvailable, let token = card.providerToken, let minorUnits = card.priceMinorUnits {
                try await telegram.sendInvoice(.init(
                    chatID: chatKey.chatID,
                    title: "Подписка на бота · \(ChatContextStore.subscriptionDays) дней",
                    description: "Персональная копия ИИ-бота: платные модели, свои чаты и пользователи",
                    payload: "buy_access_card",
                    kind: .fiat(currency: card.currency.rawValue, amountMinorUnits: minorUnits, providerToken: token)
                ))
                return
            }
        }

        // Several methods available → choice menu
        var rows: [[InlineKeyboardButton]] = []
        if let starsPrice, starsPrice > 0 {
            rows.append([InlineKeyboardButton(
                text: "💫 Stars · \(starsPrice) ⭐",
                callback_data: BotCallbackAction.menu(action: "buy:stars").rawData
            )])
        }
        if cryptoAvailable, let cents = cryptoPriceCents {
            let label = String(format: "🪙 Криптовалюта · $%.2f", Double(cents) / 100.0)
            rows.append([InlineKeyboardButton(
                text: label,
                callback_data: BotCallbackAction.menu(action: "buy:crypto").rawData
            )])
        }
        if cardAvailable, let priceLabel = card.priceLabel {
            rows.append([InlineKeyboardButton(
                text: "💳 Картой · \(priceLabel)",
                callback_data: BotCallbackAction.menu(action: "buy:card").rawData
            )])
        }
        let markup = InlineKeyboardMarkup(inline_keyboard: rows)
        _ = try await telegram.sendMessage(.init(
            chatID: chatKey.chatID,
            threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
            replyTo: nil,
            text: """
            <b>💳 Выберите способ оплаты</b>

            После оплаты бот активирует персональную копию автоматически.
            """,
            replyMarkup: markup
        ))
    }

    private func handleHistory(chatKey: ChatKey) async throws {
        let messages = await state.history(chatKey: chatKey)
        guard !messages.isEmpty else {
            try await sendUserFeedback(chatKey: chatKey, text: "📝 История пуста.")
            return
        }

        var lines: [String] = ["<b>📝 История</b> (\(messages.count))"]
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
