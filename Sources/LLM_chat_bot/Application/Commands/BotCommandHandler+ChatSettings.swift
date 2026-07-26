import Foundation

// Commands that change what one chat keeps for itself: role, model, style,
// memory, footer toggles, AI service. Bodies moved here verbatim from the
// dispatch switch — each still sits inside a `switch parsed.name`.

extension BotCommandHandler {
    /// Role, model, style of the answer, memory length.
    func handleChatValueCommand(_ parsed: ParsedBotCommand, chatKey: ChatKey, fromUser: TelegramUser?) async throws {
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

        default:
            break
        }
    }

    /// What the bot prints under an answer, plus test mode and the resets.
    func handleChatToggleCommand(_ parsed: ParsedBotCommand, chatKey: ChatKey) async throws {
        switch parsed.name {
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
            try await sendUserFeedback(chatKey: chatKey, text: "↺ Настройки сброшены к стандартным.")

        case .resetStats:
            await state.resetUsage(chatKey: chatKey)
            try await sendUserFeedback(chatKey: chatKey, text: "🗑 Статистика этого чата сброшена.")

        default:
            break
        }
    }

    /// Which AI service answers, and whether it thinks before answering.
    func handleAiServiceCommand(_ parsed: ParsedBotCommand, chatKey: ChatKey) async throws {
        switch parsed.name {
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

        default:
            break
        }
    }
}
