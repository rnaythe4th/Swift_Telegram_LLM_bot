import Foundation

// Per-chat settings pages: role, model, style, memory, provider,
// reasoning — plus the actions behind their buttons. The command switch is a
// dispatcher; each command keeps its own body, where a bare `return` still
// means "done with this tap".

extension BotMenuHandler {
    /// Per-chat settings: role, model, temperature, memory, footer toggles.
    func processChatSettingsAction(
        route: MenuRoute,
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        switch route.command {
        case .role:
            try await handleRoleAction(route: route, chatKey: chatKey, callback: callback, message: message)

        case .model:
            try await handleModelAction(route: route, chatKey: chatKey, callback: callback, message: message)

        case .temp:
            try await handleTempAction(route: route, chatKey: chatKey, callback: callback, message: message)

        case .stats:
            try await handleStatsAction(route: route, chatKey: chatKey, callback: callback, message: message)

        case .history:
            try await handleHistoryAction(route: route, chatKey: chatKey, callback: callback, message: message)

        case .provider:
            try await handleProviderAction(route: route, chatKey: chatKey, callback: callback, message: message)

        case .reasoning:
            try await handleReasoningAction(route: route, chatKey: chatKey, callback: callback, message: message)

        case .reset:
            await state.clearPending(chatKey: chatKey)
            await state.resetChat(chatKey: chatKey)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Настройки сброшены")
            try await showPage(.main, chatKey: chatKey, callback: callback, message: message)
            return

        case .help:
            try await showPage(.helpPage, chatKey: chatKey, callback: callback, message: message)

        default:
            break
        }
    }

    private func handleRoleAction(
        route: MenuRoute,
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard !route.sub.isEmpty else { return }
        if route.sub == "custom" {
            await state.setPending(.admin(.init(kind: .chatCustomRole)), menuMessageID: message.message_id, chatKey: chatKey)
            let prompt = """
            <b>🎭 Своя роль</b>

            Отправьте текст роли одним сообщением.
            <i>Пример:</i> <code>Ты — эксперт по математике, отвечай кратко.</code>

            ⚠️ Переписка в этом чате будет очищена.
            """
            let markup: Keyboard = [[cancelButton(to: .role)]]
            try await editOrAnswer(callback: callback, message: message, screen: MenuScreen(prompt, markup))
            return
        } else if route.sub == "default" {
            let defaultRole = await state.defaultRole(chatID: chatKey.chatID)
            _ = await state.setRoleAndResetHistory(chatKey: chatKey, role: defaultRole)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Роль по умолчанию")
            try await showPage(.role, chatKey: chatKey, callback: callback, message: message)
            return
        } else if route.sub == "gsel", let index = route.int(2) {
            let presets = await state.rolePresets(chatID: chatKey.chatID)
            guard index >= 0, index < presets.count else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: Texts.presetNotFound)
                return
            }
            let roleValue = presets[index].value + formatOptions
            _ = await state.setRoleAndResetHistory(chatKey: chatKey, role: roleValue)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Роль: \(presets[index].display)")
            try await showPage(.role, chatKey: chatKey, callback: callback, message: message)
            return
        } else if route.sub == "csel", let index = route.int(2) {
            let presets = await state.chatPresets(category: .role, chatKey: chatKey)
            guard index >= 0, index < presets.count else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: Texts.presetNotFound)
                return
            }
            let roleValue = presets[index].value + formatOptions
            _ = await state.setRoleAndResetHistory(chatKey: chatKey, role: roleValue)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Роль: \(presets[index].display)")
            try await showPage(.role, chatKey: chatKey, callback: callback, message: message)
            return
        } else if route.sub == "select", let index = route.int(2) {
            // Legacy: treat as global
            let presets = await state.rolePresets(chatID: chatKey.chatID)
            guard index >= 0, index < presets.count else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: Texts.presetNotFound)
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
        route: MenuRoute,
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard !route.sub.isEmpty else { return }
        if route.sub == "custom" {
            await state.setPending(.admin(.init(kind: .chatCustomModel)), menuMessageID: message.message_id, chatKey: chatKey)
            let prompt = """
            <b>🤖 Своя модель</b>

            Отправьте название модели одним сообщением:
            <code>openai/gpt-4o</code>

            Через конкретный сервис:
            <code>deepseek/deepseek-v4-pro | deepseek</code>

            <i>Названия моделей — на openrouter.ai. При смене модели переписка очищается.</i>
            """
            let markup: Keyboard = [[cancelButton(to: .model)]]
            try await editOrAnswer(callback: callback, message: message, screen: MenuScreen(prompt, markup))
            return
        }
        if route.sub == "freemodels" {
            await sendOpenRouterFreeModels(chatKey: chatKey, callback: callback)
            return
        }
        guard let token = route.arg(2) else { return }
        if route.sub == "markfree" || route.sub == "unmarkfree" {
            guard await requireSuperAdmin(callback) else { return }
            let listed = await state.modelPresets(chatID: chatKey.chatID)
                + state.chatPresets(category: .model, chatKey: chatKey)
            guard let preset = Self.presetTarget(token, in: listed) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: Texts.modelNotFound)
                return
            }
            let pinning = route.sub == "markfree"
            if pinning {
                await state.addFreeModel(preset.value)
            } else {
                await state.removeFreeModel(preset.value)
            }
            try? await telegram.answerCallback(
                callbackQueryID: callback.id,
                text: pinning ? "🆓 Добавлено в бесплатные" : "🔒 Убрано из бесплатных"
            )
            try await showPage(.superFreeModels, chatKey: chatKey, callback: callback, message: message)
            return
        } else if route.sub == "select" || route.sub == "gsel" || route.sub == "csel" {
            // `select` is the legacy alias of `gsel`; the only difference
            // between the branches is which list the value is looked up in.
            let presets = route.sub == "csel"
                ? await state.chatPresets(category: .model, chatKey: chatKey)
                : await state.modelPresets(chatID: chatKey.chatID)
            guard let preset = Self.presetTarget(token, in: presets) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: Texts.modelNotFound)
                return
            }
            let modelValue = preset.value
            let gate = await paidModelGate(modelValue, callback: callback, chatKey: chatKey)
            if gate.isPaid, case .none = gate.access {
                let price = await state.starsPrice()
                let hint = price.map { " (\($0) ⭐ /buy)" } ?? ""
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "⭐ Это платная модель\(hint)")
                return
            }
            _ = await state.setModelAndResetHistory(chatKey: chatKey, newModel: modelValue, providerRouting: preset.provider)
            let toast = "Модель: \(preset.display)" + (preset.provider.map { " · \($0)" } ?? "")
                + Self.dailyTasteToastSuffix(gate.access, isPaidModel: gate.isPaid)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: toast)
            try await showPage(.model, chatKey: chatKey, callback: callback, message: message)
            return
        }
    }

    /// The preset a model button points at.
    ///
    /// Buttons carry the preset's position, because a model id does not fit:
    /// `menu:model:gsel:` plus an OpenRouter id over 48 characters exceeds
    /// Telegram's 64-byte `callback_data`, and the API then refuses the whole
    /// message — the page simply never opens. Buttons in messages sent by an
    /// older build still carry the value, so both are accepted; a numeric token
    /// is a position first, which is why the value lookup runs second.
    static func presetTarget(_ token: String, in presets: [Preset]) -> Preset? {
        if let index = Int(token), presets.indices.contains(index) { return presets[index] }
        return presets.first { $0.value == token }
    }

    /// One answer to "may this person point the chat at this model right now".
    ///
    /// An unknown catalogue counts as **paid** — the same fail-closed rule the
    /// generation gate uses. The pickers used to read it the other way round
    /// (`?? false`), so while OpenRouter was unreachable they handed out every
    /// model the gate would then refuse, at the owner's expense.
    func paidModelGate(
        _ modelID: String,
        callback: CallbackQuery,
        chatKey: ChatKey
    ) async -> (isPaid: Bool, access: ChatContextStore.PaidModelAccess) {
        let allowedFree = await state.allowedFreeModelIDs()
        let isPaid = allowedFree.map { !$0.contains(modelID) } ?? true
        let access = await state.paidModelAccess(
            key: invokerKey(callback),
            userID: callback.from.id,
            chatID: chatKey.chatID
        )
        return (isPaid, access)
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
        route: MenuRoute,
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard !route.sub.isEmpty else { return }
        if route.sub == "custom" {
            await state.setPending(.admin(.init(kind: .chatCustomTemp)), menuMessageID: message.message_id, chatKey: chatKey)
            let prompt = """
            <b>🌡 Свой стиль ответа</b>

            Отправьте число от <code>0.0</code> до <code>2.0</code> одним сообщением.
            <i>0.0 — строго по фактам и предсказуемо · 2.0 — творчески и непредсказуемо</i>
            """
            let markup: Keyboard = [[cancelButton(to: .temp)]]
            try await editOrAnswer(callback: callback, message: message, screen: MenuScreen(prompt, markup))
            return
        }
        guard let temp = Float(route.sub), ChatContext.tempRange.contains(temp) else { return }
        await state.setTemperature(chatKey: chatKey, value: temp)
        try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Стиль ответа: \(Self.tempBucket(temp))")
        try await showPage(.temp, chatKey: chatKey, callback: callback, message: message)
        return
    }

    private func handleStatsAction(
        route: MenuRoute,
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard !route.sub.isEmpty else { return }
        if route.sub == "usage-reset" {
            await state.resetUsage(chatKey: chatKey)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Статистика сброшена")
            try await showPage(.main, chatKey: chatKey, callback: callback, message: message)
            return
        }
        guard route.sub == "toggle" else { return }
        let toastText: String
        switch route.arg(2) ?? "" {
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
        route: MenuRoute,
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard !route.sub.isEmpty else { return }
        if route.sub == "clear" {
            await state.clearHistory(chatKey: chatKey)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Переписка очищена")
            try await showPage(.history, chatKey: chatKey, callback: callback, message: message)
            return
        } else if route.sub == "dump" {
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: nil)
            await sendHistoryDump(chatKey: chatKey)
            return
        }
        // Changing the memory length is the owner's call: it re-sends every
        // remembered message on every turn, so it multiplies the cost of each
        // answer. The buttons are already hidden from users — this is the gate
        // for a callback that arrives anyway (an old menu message, a crafted
        // payload).
        guard await requireOperator(callback, chatKey: chatKey, refusal: "🔒 Память настраивает владелец бота") else { return }
        if route.sub == "custom" {
            await state.setPending(.admin(.init(kind: .chatCustomHistory)), menuMessageID: message.message_id, chatKey: chatKey)
            let prompt = """
            <b>📝 Своё значение памяти</b>

            Отправьте число от <code>1</code> до <code>50</code> одним сообщением — сколько последних сообщений бот держит в голове.
            """
            let markup: Keyboard = [[cancelButton(to: .history)]]
            try await editOrAnswer(callback: callback, message: message, screen: MenuScreen(prompt, markup))
            return
        } else if route.sub == "length", let length = route.int(2), ChatContext.historyRange.contains(length) {
            await state.setMaxHistory(chatKey: chatKey, newMax: length)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Память: \(length) сообщ.")
            try await showPage(.history, chatKey: chatKey, callback: callback, message: message)
            return
        }
    }

    private func handleProviderAction(
        route: MenuRoute,
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard !route.sub.isEmpty else { return }
        if let provider = ServiceProvider.parse(route.sub) {
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
        route: MenuRoute,
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard route.sub == "set" else { return }
        let provider = await state.provider(chatKey: chatKey)
        let gateway = try gateways.gateway(for: provider)
        if gateway.capabilities.supportsReasoning {
            if route.arg(2) == "off" {
                await state.setReasoningEffort(chatKey: chatKey, effort: nil)
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Обдумывание выключено")
            } else if let effort = route.arg(2).flatMap(ReasoningEffort.init(rawValue:)) {
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
