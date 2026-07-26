import Foundation

// Per-chat settings pages: role, model, style, memory, provider,
// reasoning — plus the actions behind their buttons. The command switch is a
// dispatcher; each command keeps its own body, where a bare `return` still
// means "done with this tap".

extension BotMenuHandler {
    /// Per-chat settings: role, model, temperature, memory, footer toggles.
    func processChatSettingsAction(
        command: String,
        parts: [String],
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        switch command {
        case "role":
            try await handleRoleAction(parts: parts, chatKey: chatKey, callback: callback, message: message)

        case "model":
            try await handleModelAction(parts: parts, chatKey: chatKey, callback: callback, message: message)

        case "temp":
            try await handleTempAction(parts: parts, chatKey: chatKey, callback: callback, message: message)

        case "stats":
            try await handleStatsAction(parts: parts, chatKey: chatKey, callback: callback, message: message)

        case "history":
            try await handleHistoryAction(parts: parts, chatKey: chatKey, callback: callback, message: message)

        case "provider":
            try await handleProviderAction(parts: parts, chatKey: chatKey, callback: callback, message: message)

        case "reasoning":
            try await handleReasoningAction(parts: parts, chatKey: chatKey, callback: callback, message: message)

        case "reset":
            await clearAllPendingInputs(chatKey: chatKey)
            await state.resetChat(chatKey: chatKey)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Настройки сброшены")
            try await showPage(.main, chatKey: chatKey, callback: callback, message: message)
            return

        case "help":
            try await showPage(.helpPage, chatKey: chatKey, callback: callback, message: message)

        default:
            break
        }
    }

    private func handleRoleAction(
        parts: [String],
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard parts.count >= 2 else { return }
        if parts[1] == "custom" {
            await state.setAdminPendingInput(.init(kind: .chatCustomRole, menuMessageID: message.message_id, payload: nil), chatKey: chatKey)
            let prompt = """
            <b>🎭 Своя роль</b>

            Отправьте текст роли одним сообщением.
            <i>Пример:</i> <code>Ты — эксперт по математике, отвечай кратко.</code>

            ⚠️ Переписка в этом чате будет очищена.
            """
            let markup = InlineKeyboardMarkup(inline_keyboard: [[menuButton("❌ Отмена", action: "nav:role")]])
            try await editOrAnswer(callback: callback, message: message, text: prompt, markup: markup)
            return
        } else if parts[1] == "default" {
            let defaultRole = await state.defaultRole(chatID: chatKey.chatID)
            _ = await state.setRoleAndResetHistory(chatKey: chatKey, role: defaultRole)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Роль по умолчанию")
            try await showPage(.role, chatKey: chatKey, callback: callback, message: message)
            return
        } else if parts[1] == "gsel", parts.count >= 3, let index = Int(parts[2]) {
            let presets = await state.rolePresets(chatID: chatKey.chatID)
            guard index >= 0, index < presets.count else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Заготовка не найдена")
                return
            }
            let roleValue = presets[index].value + formatOptions
            _ = await state.setRoleAndResetHistory(chatKey: chatKey, role: roleValue)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Роль: \(presets[index].display)")
            try await showPage(.role, chatKey: chatKey, callback: callback, message: message)
            return
        } else if parts[1] == "csel", parts.count >= 3, let index = Int(parts[2]) {
            let presets = await state.chatPresets(category: .role, chatKey: chatKey)
            guard index >= 0, index < presets.count else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Заготовка не найдена")
                return
            }
            let roleValue = presets[index].value + formatOptions
            _ = await state.setRoleAndResetHistory(chatKey: chatKey, role: roleValue)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Роль: \(presets[index].display)")
            try await showPage(.role, chatKey: chatKey, callback: callback, message: message)
            return
        } else if parts[1] == "select", parts.count >= 3, let index = Int(parts[2]) {
            // Legacy: treat as global
            let presets = await state.rolePresets(chatID: chatKey.chatID)
            guard index >= 0, index < presets.count else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Заготовка не найдена")
                return
            }
            let roleValue = presets[index].value + formatOptions
            _ = await state.setRoleAndResetHistory(chatKey: chatKey, role: roleValue)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Роль: \(presets[index].display)")
            try await showPage(.role, chatKey: chatKey, callback: callback, message: message)
            return
        }
    }

    private func handleModelAction(
        parts: [String],
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard parts.count >= 2 else { return }
        if parts[1] == "custom" {
            await state.setAdminPendingInput(.init(kind: .chatCustomModel, menuMessageID: message.message_id, payload: nil), chatKey: chatKey)
            let prompt = """
            <b>🤖 Своя модель</b>

            Отправьте название модели одним сообщением:
            <code>openai/gpt-4o</code>

            Через конкретный сервис:
            <code>deepseek/deepseek-v4-pro | deepseek</code>

            <i>Названия моделей — на openrouter.ai. При смене модели переписка очищается.</i>
            """
            let markup = InlineKeyboardMarkup(inline_keyboard: [[menuButton("❌ Отмена", action: "nav:model")]])
            try await editOrAnswer(callback: callback, message: message, text: prompt, markup: markup)
            return
        }
        if parts[1] == "freemodels" {
            await sendOpenRouterFreeModels(chatKey: chatKey, callback: callback)
            return
        }
        guard parts.count >= 3 else { return }
        let modelValue = parts[2]
        if parts[1] == "markfree" {
            guard await state.isSuperAdmin(username: invokerKey(callback)) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
                return
            }
            await state.addFreeModel(modelValue)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🆓 Добавлено в бесплатные")
            try await showPage(.superFreeModels, chatKey: chatKey, callback: callback, message: message)
            return
        } else if parts[1] == "unmarkfree" {
            guard await state.isSuperAdmin(username: invokerKey(callback)) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
                return
            }
            await state.removeFreeModel(modelValue)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Убрано из бесплатных")
            try await showPage(.superFreeModels, chatKey: chatKey, callback: callback, message: message)
            return
        } else if parts[1] == "select" || parts[1] == "gsel" {
            let presets = await state.modelPresets(chatID: chatKey.chatID)
            guard let preset = presets.first(where: { $0.value == modelValue }) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Модель не найдена")
                return
            }
            let effectiveFree = await state.effectiveFreeModelIDs()
            let isPaidModel = effectiveFree.map { !$0.contains(modelValue) } ?? false
            let access = await state.paidModelAccess(username: callback.from.username, userID: callback.from.id, chatID: chatKey.chatID)
            if isPaidModel, case .none = access {
                let price = await state.starsPrice()
                let hint = price.map { " (\($0) ⭐ /buy)" } ?? ""
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "⭐ Это платная модель\(hint)")
                return
            }
            _ = await state.setModelAndResetHistory(chatKey: chatKey, newModel: modelValue, providerRouting: preset.provider)
            let toast = "Модель: \(preset.display)" + (preset.provider.map { " · \($0)" } ?? "")
                + Self.dailyTasteToastSuffix(access, isPaidModel: isPaidModel)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: toast)
            try await showPage(.model, chatKey: chatKey, callback: callback, message: message)
            return
        } else if parts[1] == "csel" {
            let chatPresets = await state.chatPresets(category: .model, chatKey: chatKey)
            guard let preset = chatPresets.first(where: { $0.value == modelValue }) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Модель не найдена")
                return
            }
            let effectiveFree = await state.effectiveFreeModelIDs()
            let isPaidModel = effectiveFree.map { !$0.contains(modelValue) } ?? false
            let access = await state.paidModelAccess(username: callback.from.username, userID: callback.from.id, chatID: chatKey.chatID)
            if isPaidModel, case .none = access {
                let price = await state.starsPrice()
                let hint = price.map { " (\($0) ⭐ /buy)" } ?? ""
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "⭐ Это платная модель\(hint)")
                return
            }
            _ = await state.setModelAndResetHistory(chatKey: chatKey, newModel: modelValue, providerRouting: preset.provider)
            let toast = "Модель: \(preset.display)" + (preset.provider.map { " · \($0)" } ?? "")
                + Self.dailyTasteToastSuffix(access, isPaidModel: isPaidModel)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: toast)
            try await showPage(.model, chatKey: chatKey, callback: callback, message: message)
            return
        }
    }

    /// The live OpenRouter free list, fetched on demand — it is a report,
    /// not a page, so it lands as a plain message.
    private func sendOpenRouterFreeModels(chatKey: ChatKey, callback: CallbackQuery) async {
        try? await telegram.answerCallback(callbackQueryID: callback.id, text: "⏳ Запрашиваю…")
        guard let monitor = modelPriceMonitor else {
            _ = try? await telegram.sendMessage(.init(
                chatID: chatKey.chatID,
                threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                replyTo: nil,
                text: "⚠️ Мониторинг моделей недоступен.",
                replyMarkup: nil
            ))
            return
        }
        do {
            let freeModels = try await monitor.fetchCurrentFreeModels()
            let text: String
            if freeModels.isEmpty {
                text = "Бесплатных моделей на OpenRouter сейчас нет."
            } else {
                let list = freeModels.map { "• <code>\($0.id)</code>" }.joined(separator: "\n")
                text = "<b>🆓 Бесплатные модели OpenRouter сейчас</b> (\(freeModels.count))\n\(list)"
            }
            _ = try? await telegram.sendMessage(.init(
                chatID: chatKey.chatID,
                threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                replyTo: nil,
                text: text,
                replyMarkup: nil
            ))
        } catch {
            logger.error("menu freemodels fetch failed: \(error)")
            _ = try? await telegram.sendMessage(.init(
                chatID: chatKey.chatID,
                threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                replyTo: nil,
                text: "⚠️ Не удалось получить список моделей: \(UserFacingError.message(error))",
                replyMarkup: nil
            ))
        }
    }

    private func handleTempAction(
        parts: [String],
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard parts.count >= 2 else { return }
        if parts[1] == "custom" {
            await state.setAdminPendingInput(.init(kind: .chatCustomTemp, menuMessageID: message.message_id, payload: nil), chatKey: chatKey)
            let prompt = """
            <b>🌡 Свой стиль ответа</b>

            Отправьте число от <code>0.0</code> до <code>2.0</code> одним сообщением.
            <i>0.0 — строго по фактам и предсказуемо · 2.0 — творчески и непредсказуемо</i>
            """
            let markup = InlineKeyboardMarkup(inline_keyboard: [[menuButton("❌ Отмена", action: "nav:temp")]])
            try await editOrAnswer(callback: callback, message: message, text: prompt, markup: markup)
            return
        }
        guard let temp = Float(parts[1]), (0.0...2.0).contains(temp) else { return }
        await state.setTemperature(chatKey: chatKey, value: temp)
        try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Стиль ответа: \(Self.tempBucket(temp))")
        try await showPage(.temp, chatKey: chatKey, callback: callback, message: message)
        return
    }

    private func handleStatsAction(
        parts: [String],
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard parts.count >= 2 else { return }
        if parts[1] == "usage-reset" {
            await state.resetUsage(chatKey: chatKey)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Статистика сброшена")
            try await showPage(.main, chatKey: chatKey, callback: callback, message: message)
            return
        }
        guard parts.count >= 3, parts[1] == "toggle" else { return }
        let toastText: String
        switch parts[2] {
        case "tokens":
            let on = await state.toggleShowStats(chatKey: chatKey)
            toastText = on ? "🟢 Объём текста показываю" : "⚪️ Объём текста не показываю"
        case "cost":
            let on = await state.toggleShowCost(chatKey: chatKey)
            toastText = on ? "🟢 Стоимость включена" : "⚪️ Стоимость выключена"
        case "model":
            let on = await state.toggleShowModel(chatKey: chatKey)
            toastText = on ? "🟢 Модель включена" : "⚪️ Модель выключена"
        case "backup":
            let on = await state.toggleBackupNotify(chatKey: chatKey)
            toastText = on ? "🟢 Отчёты о сохранении включены" : "⚪️ Отчёты о сохранении выключены"
        case "testmode":
            let suffix = await state.toggleTestMode(chatKey: chatKey)
            if let suffix {
                toastText = "🧪 Тест-режим: суффикс \(suffix)"
            } else {
                toastText = "🧪 Тест-режим выключен"
            }
        default:
            toastText = ""
        }
        try? await telegram.answerCallback(callbackQueryID: callback.id, text: toastText.isEmpty ? nil : toastText)
        try await showPage(.stats, chatKey: chatKey, callback: callback, message: message)
        return
    }

    private func handleHistoryAction(
        parts: [String],
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard parts.count >= 2 else { return }
        if parts[1] == "clear" {
            await state.clearHistory(chatKey: chatKey)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Переписка очищена")
            try await showPage(.history, chatKey: chatKey, callback: callback, message: message)
            return
        } else if parts[1] == "dump" {
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: nil)
            await sendHistoryDump(chatKey: chatKey)
            return
        } else if parts[1] == "custom" {
            await state.setAdminPendingInput(.init(kind: .chatCustomHistory, menuMessageID: message.message_id, payload: nil), chatKey: chatKey)
            let prompt = """
            <b>📝 Своё значение памяти</b>

            Отправьте число от <code>1</code> до <code>50</code> одним сообщением — сколько последних сообщений бот держит в голове.
            """
            let markup = InlineKeyboardMarkup(inline_keyboard: [[menuButton("❌ Отмена", action: "nav:history")]])
            try await editOrAnswer(callback: callback, message: message, text: prompt, markup: markup)
            return
        } else if parts.count >= 3, parts[1] == "length", let length = Int(parts[2]), (1...50).contains(length) {
            await state.setMaxHistory(chatKey: chatKey, newMax: length)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Память: \(length) сообщ.")
            try await showPage(.history, chatKey: chatKey, callback: callback, message: message)
            return
        }
    }

    private func handleProviderAction(
        parts: [String],
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard parts.count >= 2 else { return }
        if let provider = ServiceProvider.parse(parts[1]) {
            _ = await state.changeProvider(chatKey: chatKey, newProvider: provider)
            let gateway = try gateways.gateway(for: provider)
            if await state.reasoningEnabled(chatKey: chatKey), !gateway.capabilities.supportsReasoning {
                 await state.setReasoningEffort(chatKey: chatKey, effort: nil)
                try? await telegram.answerCallback(
                    callbackQueryID: callback.id,
                    text: "Сервис ИИ сменён. Обдумывание выключено — он его не умеет."
                )
            } else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Сервис ИИ: \(provider.commandValue)")
            }
        }
        try await showPage(.provider, chatKey: chatKey, callback: callback, message: message)
        return
    }

    private func handleReasoningAction(
        parts: [String],
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard parts.count >= 3, parts[1] == "set" else { return }
        let provider = await state.provider(chatKey: chatKey)
        let gateway = try gateways.gateway(for: provider)
        if gateway.capabilities.supportsReasoning {
            if parts[2] == "off" {
                await state.setReasoningEffort(chatKey: chatKey, effort: nil)
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Обдумывание выключено")
            } else if let effort = ReasoningEffort(rawValue: parts[2]) {
                await state.setReasoningEffort(chatKey: chatKey, effort: effort)
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Обдумывание: \(effort.displayName)")
            }
        } else {
            try? await telegram.answerCallback(
                callbackQueryID: callback.id,
                text: "Сервис \(provider.commandValue) не умеет обдумывать ответ"
            )
        }
        try await showPage(.reasoning, chatKey: chatKey, callback: callback, message: message)
        return
    }
}
