import Foundation

// Per-chat settings pages: role, model, style, memory, provider,
// reasoning — plus the actions behind their buttons.

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

        case "model":
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

        case "temp":
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

        case "stats":
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

        case "history":
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

        case "provider":
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

        case "reasoning":
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

    func renderRole(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let help = await state.fetchHelp(chatKey: chatKey)
        let globalPresets = await state.rolePresets(chatID: chatKey.chatID)
        let chatPresets = await state.chatPresets(category: .role, chatKey: chatKey)
        let activeRole = help.role

        var rows: [[InlineKeyboardButton]] = []

        if !globalPresets.isEmpty {
            var currentRow: [InlineKeyboardButton] = []
            for (i, preset) in globalPresets.enumerated() {
                let isActive = activeRole.hasPrefix(preset.value)
                let label = (isActive ? "✓ " : "") + "🌐 \(preset.display)"
                currentRow.append(menuButton(label, action: "role:gsel:\(i)"))
                if currentRow.count == 2 { rows.append(currentRow); currentRow = [] }
            }
            if !currentRow.isEmpty { rows.append(currentRow) }
        }

        if !chatPresets.isEmpty {
            var currentRow: [InlineKeyboardButton] = []
            for (i, preset) in chatPresets.enumerated() {
                let isActive = activeRole.hasPrefix(preset.value)
                let label = (isActive ? "✓ " : "") + "💬 \(preset.display)"
                currentRow.append(menuButton(label, action: "role:csel:\(i)"))
                if currentRow.count == 2 { rows.append(currentRow); currentRow = [] }
            }
            if !currentRow.isEmpty { rows.append(currentRow) }
        }

        rows.append([menuButton("✏️ Своя роль", action: "role:custom"), menuButton("↺ Стандартная", action: "role:default")])
        rows.append([menuButton("⚙️ Мои заготовки", action: "pm:role")])
        rows.append(navButtons())

        let text = """
        <b>🎭 Роль ассистента</b>

        Текущая:
        <blockquote expandable>\(help.role)</blockquote>

        <i>🌐 — общая для всех чатов · 💬 — только для этого</i>
        ✏️ — своя роль текстом (или /setrole &lt;текст&gt;)
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    func renderModel(chatKey: ChatKey, username: String? = nil) async -> (String, InlineKeyboardMarkup) {
        let help = await state.fetchHelp(chatKey: chatKey)
        let globalPresets = await state.modelPresets(chatID: chatKey.chatID)
        let chatPresets = await state.chatPresets(category: .model, chatKey: chatKey)
        let effectiveFreeModels = await state.effectiveFreeModelIDs()
        let hasFullAccess = await state.hasFullModelAccess(username: username, chatID: chatKey.chatID)
        let restrictionsActive = effectiveFreeModels != nil
        let modelPrices = await state.openRouterModelPrices()
        var rows: [[InlineKeyboardButton]] = []

        func isEffectivelyFree(_ id: String) -> Bool {
            guard let eff = effectiveFreeModels else { return true }
            return eff.contains(id)
        }

        func presetLabel(preset: Preset, scope: String) -> String {
            let isActive = preset.value == help.model && preset.provider == help.modelProviderRouting
            var parts: [String] = []
            if isActive { parts.append("✓") }
            if restrictionsActive { parts.append(isEffectivelyFree(preset.value) ? "🆓" : "⭐") }
            parts.append(scope)
            parts.append(preset.display)
            return parts.joined(separator: " ")
        }

        func appendPresets(_ presets: [Preset], action: String) {
            var currentRow: [InlineKeyboardButton] = []
            for preset in presets {
                let label = presetLabel(preset: preset, scope: action == "gsel" ? "🌐" : "💬")
                currentRow.append(menuButton(label, action: "model:\(action):\(preset.value)"))
                if currentRow.count == 2 { rows.append(currentRow); currentRow = [] }
            }
            if !currentRow.isEmpty { rows.append(currentRow) }
        }

        if !globalPresets.isEmpty { appendPresets(globalPresets, action: "gsel") }
        if !chatPresets.isEmpty { appendPresets(chatPresets, action: "csel") }

        if modelPriceMonitor != nil {
            rows.append([menuButton("🆓 Бесплатные модели OpenRouter", action: "model:freemodels")])
        }
        rows.append([menuButton("✏️ Ввести ID модели", action: "model:custom")])
        rows.append([menuButton("⚙️ Мои заготовки", action: "pm:model")])

        var legendLine = ""
        var accessLine = ""
        if restrictionsActive {
            legendLine = "\n<i>🆓 — доступна всем · ⭐ — умная модель, нужен премиум или баланс</i>"
            if !hasFullAccess {
                // The picker is exactly where someone finds out they cannot
                // have the model they want — telling them to go type /buy
                // loses everyone who is not ready to type.
                let taste = await state.remainingDailyPremium(
                    chatID: chatKey.chatID,
                    userID: chatKey.chatID > 0 ? chatKey.chatID : nil,
                    isGroup: chatKey.chatID < 0
                )
                accessLine = taste.limit > 0
                    ? "\n\n<i>Умные модели (⭐) можно попробовать бесплатно: сегодня осталось \(taste.remaining) из \(taste.limit). Дальше — премиум или баланс.</i>"
                    : "\n\n<i>Умные модели (⭐) открываются премиумом или балансом.</i>"
                rows.append([menuButton("⚡ Открыть умные модели", action: "nav:pay:\(PurchaseSource.model.rawValue)")])
            }
        }
        rows.append(navButtons())

        let allPresets = globalPresets + chatPresets
        var priceSection = ""
        if !modelPrices.isEmpty {
            let multiplier = await state.priceMultiplier()
            let lines = allPresets.compactMap { preset -> String? in
                guard let price = modelPrices[preset.value] else { return nil }
                let inP = Self.formatPriceM(price.inputPerToken * multiplier)
                let outP = Self.formatPriceM(price.outputPerToken * multiplier)
                return "• \(preset.display) — ⬇️$\(inP)/M | ⬆️$\(outP)/M"
            }
            if !lines.isEmpty {
                priceSection = "\n\n" + lines.joined(separator: "\n")
            }
        }

        let routingLine = help.modelProviderRouting.map { "\nСервис · 📡 <code>\($0)</code>" } ?? ""
        let text = """
        <b>🤖 Модель</b>

        Сейчас · <code>\(help.model)</code>\(routingLine)\(legendLine)\(priceSection)

        <i>При смене модели переписка очищается.</i>
        Своя модель — /model &lt;id&gt;
        <i>С конкретным сервисом — /model &lt;id&gt; | &lt;сервис&gt;</i>
        <i>Названия моделей — на openrouter.ai</i>\(accessLine)
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    func renderTemp(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let help = await state.fetchHelp(chatKey: chatKey)
        let globalPresets = await state.tempPresets(chatID: chatKey.chatID)
        let chatPresets = await state.chatPresets(category: .temp, chatKey: chatKey)
        var rows: [[InlineKeyboardButton]] = []

        if !globalPresets.isEmpty {
            var currentRow: [InlineKeyboardButton] = []
            for preset in globalPresets {
                let isActive = Float(preset.value).map { abs($0 - help.temp) < 0.001 } ?? false
                let label = (isActive ? "✓ " : "") + "🌐 \(preset.display)"
                currentRow.append(menuButton(label, action: "temp:\(preset.value)"))
                if currentRow.count == 2 { rows.append(currentRow); currentRow = [] }
            }
            if !currentRow.isEmpty { rows.append(currentRow) }
        }

        if !chatPresets.isEmpty {
            var currentRow: [InlineKeyboardButton] = []
            for preset in chatPresets {
                let isActive = Float(preset.value).map { abs($0 - help.temp) < 0.001 } ?? false
                let label = (isActive ? "✓ " : "") + "💬 \(preset.display)"
                currentRow.append(menuButton(label, action: "temp:\(preset.value)"))
                if currentRow.count == 2 { rows.append(currentRow); currentRow = [] }
            }
            if !currentRow.isEmpty { rows.append(currentRow) }
        }

        rows.append([menuButton("✏️ Своё значение", action: "temp:custom")])
        rows.append([menuButton("⚙️ Мои заготовки", action: "pm:temp")])
        rows.append(navButtons())

        let bucket = Self.tempBucket(help.temp)
        let text = """
        <b>🌡 Стиль ответа</b>

        Сейчас · <b>\(bucket)</b> (\(Self.formatTemp(help.temp)))

        <i>Насколько свободно бот отвечает: 0.0 — строго по фактам и предсказуемо, 2.0 — творчески и непредсказуемо.</i>
        ✏️ — задать своё число (или /settemp &lt;0.0–2.0&gt;)
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    func renderStats(chatKey: ChatKey, username: String? = nil) async -> (String, InlineKeyboardMarkup) {
        let help = await state.fetchHelp(chatKey: chatKey)
        let testModeOn = help.testModeSuffix != nil
        let testLabel: String = {
            if let s = help.testModeSuffix {
                return "🟢 Тест-режим (добавка \(s))"
            }
            return "⚪️ Тест-режим"
        }()
        var rows: [[InlineKeyboardButton]] = [
            [menuButton("\(toggleMark(help.showTokens)) Объём текста", action: "stats:toggle:tokens"),
             menuButton("\(toggleMark(help.showCost)) Стоимость", action: "stats:toggle:cost")],
            [menuButton("\(toggleMark(help.showModel)) Модель", action: "stats:toggle:model")],
        ]
        // Storage reports and the test-mode suffix are operator tools: for a
        // regular user they are two switches that explain nothing and do
        // nothing they want. They stay one tap away for whoever runs the bot.
        let isSuper = await state.isSuperAdmin(username: username)
        let isChatAdmin = await state.isAdmin(username: username, chatID: chatKey.chatID)
        let isOperator = isSuper || isChatAdmin
        if isOperator || help.backupNotify || testModeOn {
            rows.append([menuButton("\(toggleMark(help.backupNotify)) Отчёты о сохранении", action: "stats:toggle:backup")])
            rows.append([menuButton(testLabel, action: "stats:toggle:testmode")])
        }
        rows.append(navButtons())

        let testHint = testModeOn
            ? "\n\n<i>🧪 Тест-режим включён — дописывайте <code>\(help.testModeSuffix!)</code> к командам, чтобы их выполнял именно этот бот.</i>"
            : ""
        let text = """
        <b>📊 Что показывать под ответом</b>

        Бот может подписывать каждый свой ответ короткой строкой. Нажмите, чтобы включить или выключить.
        🟢 — показываю · ⚪️ — не показываю

        <i>Объём текста — сколько текста обработано на этот ответ
        Стоимость — сколько списалось за этот ответ
        Модель — какая модель отвечала</i>\(testHint)
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    func renderHistory(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let help = await state.fetchHelp(chatKey: chatKey)
        let globalPresets = await state.historyLengthPresets(chatID: chatKey.chatID)
        let chatPresets = await state.chatPresets(category: .history, chatKey: chatKey)
        var rows: [[InlineKeyboardButton]] = []

        if !globalPresets.isEmpty {
            var currentRow: [InlineKeyboardButton] = []
            for preset in globalPresets {
                let isActive = Int(preset.value) == help.maxHistory
                let label = (isActive ? "✓ " : "") + "🌐 \(preset.display)"
                currentRow.append(menuButton(label, action: "history:length:\(preset.value)"))
                if currentRow.count == 2 { rows.append(currentRow); currentRow = [] }
            }
            if !currentRow.isEmpty { rows.append(currentRow) }
        }

        if !chatPresets.isEmpty {
            var currentRow: [InlineKeyboardButton] = []
            for preset in chatPresets {
                let isActive = Int(preset.value) == help.maxHistory
                let label = (isActive ? "✓ " : "") + "💬 \(preset.display)"
                currentRow.append(menuButton(label, action: "history:length:\(preset.value)"))
                if currentRow.count == 2 { rows.append(currentRow); currentRow = [] }
            }
            if !currentRow.isEmpty { rows.append(currentRow) }
        }

        rows.append([
            menuButton("📜 Что бот помнит", action: "history:dump"),
            menuButton("🧹 Очистить", action: "history:clear"),
        ])
        rows.append([menuButton("✏️ Своё значение", action: "history:custom")])
        rows.append([menuButton("⚙️ Мои заготовки", action: "pm:history")])
        rows.append(navButtons())

        let text = """
        <b>📝 Память бота</b>

        Помнит последние · <b>\(help.maxHistory) сообщ.</b>

        <i>Сколько прошлых сообщений бот держит в голове. Чем больше — тем лучше он понимает, о чём речь, но ответ медленнее и дороже.</i>
        ✏️ — задать своё число (или /historylength &lt;1–50&gt;)
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    func renderProvider(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let help = await state.fetchHelp(chatKey: chatKey)
        let providers = ServiceProvider.allCases
        var rows: [[InlineKeyboardButton]] = []
        var currentRow: [InlineKeyboardButton] = []
        for provider in providers {
            let label = (provider == help.provider ? "✓ " : "") + provider.rawValue
            currentRow.append(menuButton(label, action: "provider:\(provider.commandValue)"))
            if currentRow.count == 2 {
                rows.append(currentRow)
                currentRow = []
            }
        }
        if !currentRow.isEmpty {
            rows.append(currentRow)
        }
        rows.append(navButtons())
        let text = """
        <b>🔌 Сервис ИИ</b>

        Сейчас · <b>\(help.provider.commandValue)</b>

        <i>Через кого бот ходит к моделям. Обычно менять не нужно — если не знаете, что выбрать, оставьте как есть.</i>

        <i>OpenRouter — тысячи моделей (GPT, Claude, Gemini, DeepSeek…)
        DeepSeek — только модели DeepSeek, напрямую
        Yandex — YandexGPT</i>
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    func renderReasoning(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let help = await state.fetchHelp(chatKey: chatKey)
        let provider = await state.provider(chatKey: chatKey)
        let gateway = try? gateways.gateway(for: provider)
        let supported = gateway?.capabilities.supportsReasoning ?? false
        let current = help.reasoningEffort?.rawValue

        if !supported {
            let rows = [navButtons()]
            let text = """
            <b>🧠 Обдумывание</b>

            Сервис <b>\(provider.commandValue)</b> этого не умеет.
            Смените сервис ИИ, чтобы включить.
            """
            return (text, InlineKeyboardMarkup(inline_keyboard: rows))
        }

        func btn(_ value: String, label: String) -> InlineKeyboardButton {
            let mark = (current == value || (value == "off" && current == nil)) ? "✓ " : ""
            return menuButton(mark + label, action: "reasoning:set:\(value)")
        }

        let rows: [[InlineKeyboardButton]] = [
            [btn("low", label: "Быстро"), btn("medium", label: "Средне"), btn("high", label: "Глубоко")],
            [btn("off", label: "Выключить")],
            navButtons(),
        ]
        let text = """
        <b>🧠 Обдумывание</b>

        Сейчас · <b>\(help.reasoningEffort?.displayName ?? "выключено")</b>

        <i>Модель думает перед тем, как ответить: получается точнее, но медленнее и дороже.
        Быстро — почти без задержки, дёшево
        Средне — разумный компромисс
        Глубоко — самый точный ответ, но ждать дольше</i>
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    func renderHelp(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let rows: [[InlineKeyboardButton]] = [navButtons()]
        return (BotCallbackHandler.faqText, InlineKeyboardMarkup(inline_keyboard: rows))
    }
}
