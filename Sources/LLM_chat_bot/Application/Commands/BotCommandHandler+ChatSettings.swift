import Foundation

// Commands that change what one chat keeps for itself: role, model, style,
// memory, footer toggles, AI service. Bodies moved here verbatim from the
// dispatch switch — each still sits inside a `switch parsed.name`.

extension BotCommandHandler {
    /// Role, model, style of the answer, memory length.
    func handleChatValueCommand(_ parsed: ParsedBotCommand, chatKey: ChatKey, fromUser: TelegramUser?) async throws {
        let web = await state.provider(chatKey: chatKey) == .deepseekWeb
        if web && chatKey.chatID.isGroup && [.setRole, .defaultRole, .clearHistory].contains(parsed.name) {
            guard await requireOperatorForTuning(chatKey: chatKey, fromUser: fromUser,
                                                 refusal: "🔒 Эти настройки меняет администратор чата.") else { return }
        }
        switch parsed.name {
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
            try await menuHandler.checkpointWebSettings(chatKey: chatKey)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Роль обновлена. Переписка очищена.")

        case .clearHistory:
            await state.clearHistory(chatKey: chatKey)
            try await menuHandler.checkpointWebSettings(chatKey: chatKey)
            try await sendUserFeedback(chatKey: chatKey, text: "🧹 Переписка очищена — бот забыл, о чём был разговор.")

        case .setTemp:
            // Same line as the menu: hand-tuning is what premium unlocks, and a
            // command must not be the back door around it.
            guard await requireFullAccessForTuning(chatKey: chatKey, fromUser: fromUser) else { return }
            guard let temp = Float(parsed.argument), ChatContext.tempRange.contains(temp) else {
                let hint = "<i>Нужно число от 0.0 (строго по фактам) до 2.0 (творчески).</i>\n<i>Пример:</i> <code>/settemp 1.0</code>"
                try await sendUserFeedback(chatKey: chatKey, text: hint)
                return
            }
            await state.setTemperature(chatKey: chatKey, value: temp)
            let bucket = BotMenuHandler.tempBucket(temp)
            let note = web ? "\nНастройка действует для ответов через API." : ""
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Стиль ответа: <b>\(bucket)</b> (\(BotMenuHandler.formatTemp(temp)))\(note)")

        case .model:
            let trimmed = parsed.argument.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: """
                    🤖 Укажите название модели.
                    <i>Пример:</i> <code>/model openai/gpt-4o</code>
                    <i>Через конкретный сервис:</i> <code>/model deepseek/deepseek-v4-pro | deepseek</code>
                    Готовые варианты в /menu → ⚙️ Тонкая настройка → 🤖 Модель
                    """)
                return
            }
            // Optional second part after "|": OpenRouter upstream provider pin.
            let modelParts = trimmed.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let modelID = modelParts.first ?? ""
            let providerRouting = modelParts.count > 1 && !modelParts[1].isEmpty ? modelParts[1] : nil
            guard !modelID.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "⚠️ Укажите модель перед <code>|</code>.")
                return
            }
            // A free-tier chat may still pick a paid model while today's premium
            // taste has units left — the cap enforces itself at generation time.
            let access = await state.paidModelAccess(key: actorKey(fromUser), userID: fromUser?.id, chatID: chatKey.chatID)
            // Unknown catalogue counts as paid, like the generation gate: while
            // OpenRouter is unreachable this must not become a way to run any
            // model for free.
            let allowedFree = await state.allowedFreeModelIDs()
            let isPaidModel = allowedFree.map { !$0.contains(modelID) } ?? true
            if isPaidModel, case .none = access {
                let price = await state.starsPrice()
                let buyHint = price.map { "\n\nОткрыть премиум для этого чата (\($0) ⭐) — /buy, или пополните баланс и платите за ответы — /balance" } ?? "\n\nОткрыть премиум для этого чата — /buy, или пополните баланс и платите за ответы — /balance"
                try await sendUserFeedback(chatKey: chatKey, text: "⭐ <b>\(MessageText.escaped(modelID))</b> — платная модель.\(buyHint)")
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
            // Model id and upstream pin are whatever the person typed; the
            // pages that print them are escaped (audit zone 21), and this
            // confirmation is the same value through a different door — one
            // `<` and Telegram refuses the whole message, so the setting
            // applies and nobody is told.
            let providerNote = providerRouting.map { "\nСервис: <code>\(MessageText.escaped($0))</code>" } ?? ""
            // Say the daily ceiling out loud: on a free tier this model answers
            // N times today and then falls back on its own.
            var tasteNote = ""
            if isPaidModel, case .dailyTaste(let remaining, let limit) = access {
                tasteNote = "\n🚦 Умных ответов сегодня: <b>\(remaining) из \(limit)</b>, дальше отвечаю на бесплатной."
            }
            let historyNote = web ? "Модель сохранена для ответов через API." : "Переписка очищена."
            try await sendUserFeedback(chatKey: chatKey, text: """
                ✓ Модель: <code>\(MessageText.escaped(changed.new))</code>\(providerNote)
                <i>Была:</i> <code>\(MessageText.escaped(changed.old))</code>
                \(historyNote)\(priceNote)\(tasteNote)
                """)

        case .defaultRole:
            let defaultRole = await state.defaultRole(chatID: chatKey.chatID)
            _ = await state.setRoleAndResetHistory(chatKey: chatKey, role: defaultRole)
            try await menuHandler.checkpointWebSettings(chatKey: chatKey)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Роль сброшена к стандартной. Переписка очищена.")

        case .historyLength:
            // The owner's lever, not a per-user preference: every remembered
            // message is re-sent on every turn, so this multiplies the cost of
            // each answer.
            guard await requireOperatorForTuning(chatKey: chatKey, fromUser: fromUser,
                                                 refusal: "🔒 Длину памяти настраивает владелец бота.") else { return }
            guard let newMax = Int(parsed.argument), ChatContext.historyRange.contains(newMax) else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Нужно число от 1 до 50 — сколько прошлых сообщений бот держит в голове.</i>\n<i>Пример:</i> <code>/historylength 11</code>")
                return
            }
            await state.setMaxHistory(chatKey: chatKey, newMax: newMax)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Память: <b>\(newMax) сообщ.</b>")

        default:
            break
        }
    }

    /// What the bot prints under an answer, plus test mode and the resets.
    func handleChatToggleCommand(_ parsed: ParsedBotCommand, chatKey: ChatKey) async throws {
        let web = await state.selectedProvider(chatKey: chatKey) == .deepseekWeb
        let note = web ? "\nНастройка действует для ответов через API." : ""
        switch parsed.name {
        case .showTokens:
            let new = await state.toggleShowStats(chatKey: chatKey)
            try await sendUserFeedback(chatKey: chatKey, text: "📊 Объём текста под ответом · <b>\(onOff(new))</b>\(note)")

        case .showCost:
            let new = await state.toggleShowCost(chatKey: chatKey)
            try await sendUserFeedback(chatKey: chatKey, text: "💵 Стоимость под ответом · <b>\(onOff(new))</b>\(note)")

        case .showModel:
            let new = await state.toggleShowModel(chatKey: chatKey)
            try await sendUserFeedback(chatKey: chatKey, text: "🤖 Название модели под ответом · <b>\(onOff(new))</b>\(note)")

        case .backupNotify:
            let new = await state.toggleBackupNotify(chatKey: chatKey)
            try await sendUserFeedback(chatKey: chatKey, text: "💾 Отчёты о сохранении · <b>\(onOff(new))</b>")

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

        case .reset:
            await state.resetChat(chatKey: chatKey)
            try await menuHandler.checkpointWebSettings(chatKey: chatKey)
            try await sendUserFeedback(chatKey: chatKey, text: "↺ Настройки сброшены к стандартным.")

        case .resetStats:
            await state.resetUsage(chatKey: chatKey)
            try await sendUserFeedback(chatKey: chatKey, text: "🗑 Статистика этого чата сброшена.")

        default:
            break
        }
    }

    /// Which AI service answers, and whether it thinks before answering.
    func handleAiServiceCommand(_ parsed: ParsedBotCommand, chatKey: ChatKey, fromUser: TelegramUser?) async throws {
        switch parsed.name {
        case .provider:
            // Plumbing: the wrong service silently removes reasoning and most
            // of the model catalogue. Owner-only, like the menu page.
            guard await requireOperatorForTuning(chatKey: chatKey, fromUser: fromUser,
                                                 refusal: "🔒 Сервис ИИ настраивает владелец бота.") else { return }
            if let provider = ServiceProvider.parse(parsed.argument) {
                guard let capabilities = gateways.capabilities(for: provider) else {
                    throw ProviderGatewayRegistryError.missingAdapter(provider)
                }
                if provider == .deepseekWeb, chatKey.chatID.isGroup, !(await state.webListeningAllowed(chatKey: chatKey)) {
                    let listening = await state.listening(chatKey: chatKey).isOn
                    let disclosure = Texts.webGroupDisclosure + (listening ? "\n" + Texts.webListenDisclosure : "")
                    try await sendUserFeedback(chatKey: chatKey, text: disclosure)
                }
                let old = await state.changeProvider(chatKey: chatKey, newProvider: provider)
                var lines = ["✓ Сервис ИИ: <b>\(provider.commandValue)</b>"]
                if old != provider {
                    lines.append("<i>Был:</i> <b>\(old.commandValue)</b>")
                }

                try await menuHandler.checkpointWebSettings(chatKey: chatKey)
                let reasoningEnabled = await state.reasoningEnabled(chatKey: chatKey)
                if reasoningEnabled, !capabilities.supportsReasoning {
                    lines.append("<i>На этом сервисе уровни обдумывания недоступны.</i>")
                }
                try await sendUserFeedback(chatKey: chatKey, text: lines.joined(separator: "\n"))
            } else {
                let available = gateways.available.map { "<code>\($0.commandValue)</code>" }.joined(separator: ", ")
                let current = await state.provider(chatKey: chatKey)
                let status = gateways.capabilities(for: current) == nil ? " (отключён)" : ""
                try await sendUserFeedback(chatKey: chatKey, text: "Сейчас: \(current.rawValue)\(status). Доступны: \(available).")
            }

        case .reasoning:
            let provider = await state.provider(chatKey: chatKey)
            if provider == .deepseekWeb {
                if chatKey.chatID.isGroup {
                    guard await requireOperatorForTuning(chatKey: chatKey, fromUser: fromUser,
                                                         refusal: "🔒 DeepThink настраивает администратор чата.") else { return }
                }
            } else {
                guard await requireFullAccessForTuning(chatKey: chatKey, fromUser: fromUser) else { return }
            }
            guard let capabilities = gateways.capabilities(for: provider) else {
                throw ProviderGatewayRegistryError.missingAdapter(provider)
            }

            guard capabilities.supportsReasoning else {
                try await sendUserFeedback(
                    chatKey: chatKey,
                    text: "🧠 Сервис <b>\(provider.commandValue)</b> не умеет обдумывать ответ. Смените его в /menu → 🔌 Сервис ИИ."
                )
                return
            }

            let arg = parsed.argument.trimmingCharacters(in: .whitespaces).lowercased()
            if provider == .deepseekWeb {
                let selection: Bool?
                switch arg {
                case "on", "вкл": selection = true
                case "off", "выкл": selection = false
                case "": selection = nil
                default:
                    try await sendUserFeedback(chatKey: chatKey, text: "<i>Как пользоваться:</i> <code>/reasoning on|off</code>")
                    return
                }
                guard let enabled = await state.setWebDeepThink(chatKey: chatKey, enabled: selection) else {
                    throw DeepSeekWebPersistenceError.unavailable
                }
                try await menuHandler.checkpointWebSettings(chatKey: chatKey)
                try await sendUserFeedback(chatKey: chatKey, text: "🧠 DeepThink · <b>\(enabled ? "включён" : "выключен")</b>")
                return
            }
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

        default:
            break
        }
    }

    // MARK: - Gates shared with the menu

    /// Hand-tuning a setting a reference mode owns. The same line the menu
    /// draws (`MenuPage.access == .paidAccess`): a free chat picks a mode, a
    /// paying one takes the settings apart. Without this the commands are a
    /// back door around the paywall — and around the cost controls behind it.
    func requireFullAccessForTuning(chatKey: ChatKey, fromUser: TelegramUser?) async -> Bool {
        let allowed = await state.hasFullModelAccess(
            key: actorKey(fromUser),
            userID: fromUser?.id,
            chatID: chatKey.chatID
        )
        guard allowed else {
            try? await sendUserFeedback(
                chatKey: chatKey,
                text: "⭐ Тонкая настройка — с премиумом или балансом.\nСейчас доступны готовые режимы: /menu"
            )
            return false
        }
        return true
    }

    /// Whoever runs the bot here: super-admin, or the admin whose licence pays
    /// for this chat.
    func requireOperatorForTuning(chatKey: ChatKey, fromUser: TelegramUser?, refusal: String) async -> Bool {
        let allowed = await state.isAdmin(actorKey(fromUser), chatID: chatKey.chatID)
        guard allowed else {
            try? await sendUserFeedback(chatKey: chatKey, text: refusal)
            return false
        }
        return true
    }
}
