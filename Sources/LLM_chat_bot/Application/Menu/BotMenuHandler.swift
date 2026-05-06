import Foundation

private enum MenuPage: String {
    case main
    case role
    case model
    case temp
    case stats
    case history
    case provider
    case reasoning
    case helpPage = "help"
    case superAdmin = "superadmin"
    case close
}

final class BotMenuHandler: @unchecked Sendable {
    private let telegram: TelegramGatewayPort
    private let state: ChatContextStore
    private let gateways: ProviderGatewayRegistry
    private let logger: LoggerPort
    private let formatOptions: String
    private let modelPriceMonitor: ModelPriceMonitor?

    init(
        telegram: TelegramGatewayPort,
        state: ChatContextStore,
        gateways: ProviderGatewayRegistry,
        logger: LoggerPort,
        formatOptions: String,
        modelPriceMonitor: ModelPriceMonitor? = nil
    ) {
        self.telegram = telegram
        self.state = state
        self.gateways = gateways
        self.logger = logger
        self.formatOptions = formatOptions
        self.modelPriceMonitor = modelPriceMonitor
    }

    func handle(action rawAction: String, callback: CallbackQuery) async {
        guard let message = callback.message else {
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Сообщение недоступно")
            return
        }

        let chatKey = ChatKey(chatID: message.chat.id, threadID: message.message_thread_id ?? 0)
        let action = rawAction.isEmpty ? "open" : rawAction
        let parts = action.split(separator: ":", omittingEmptySubsequences: false).map(String.init)

        do {
            try await processAction(parts: parts, chatKey: chatKey, callback: callback, message: message)
        } catch {
            logger.error("menu action failed: \(error)")
            let alertText = UserFacingError.shortMessage(error, context: "Ошибка")
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: alertText)
        }
    }

    func processTextInput(text: String, chatKey: ChatKey, username: String?) async -> Bool {
        if text.hasPrefix("/") { return false }

        if await state.hasPendingStarsPriceInput(chatKey: chatKey) {
            guard let menuMessageID = await state.consumePendingStarsPriceInput(chatKey: chatKey) else { return true }
            guard await state.isSuperAdmin(username: username) else {
                _ = try? await telegram.sendMessage(.init(
                    chatID: chatKey.chatID,
                    threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                    replyTo: nil,
                    text: "🔒 Только суперадмин может изменить цену.",
                    replyMarkup: nil
                ))
                return true
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = Int(trimmed), value >= 0 {
                await state.setStarsPrice(value > 0 ? value : nil)
                let confirmText = value > 0 ? "✓ Цена доступа: <b>\(value) ⭐</b>" : "✓ Продажи отключены."
                let (menuText, markup) = await renderSuperAdmin(chatKey: chatKey)
                try? await telegram.editMessage(.init(
                    chatID: chatKey.chatID,
                    messageID: menuMessageID,
                    text: menuText,
                    replyMarkup: markup
                ))
                _ = try? await telegram.sendMessage(.init(
                    chatID: chatKey.chatID,
                    threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                    replyTo: nil,
                    text: confirmText,
                    replyMarkup: nil
                ))
            } else {
                await state.setPendingStarsPriceInput(menuMessageID: menuMessageID, chatKey: chatKey)
                _ = try? await telegram.sendMessage(.init(
                    chatID: chatKey.chatID,
                    threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                    replyTo: nil,
                    text: "⚠️ Введите целое число (например <code>50</code>) или <code>0</code> для отключения.",
                    replyMarkup: nil
                ))
            }
            return true
        }

        if await state.hasPendingFreeModelInput(chatKey: chatKey) {
            guard let menuMessageID = await state.consumePendingFreeModelInput(chatKey: chatKey) else { return true }
            guard await state.isSuperAdmin(username: username) else { return true }
            let modelID = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !modelID.isEmpty {
                let added = await state.addFreeModel(modelID)
                let toast = added ? "✓ Добавлено: \(modelID)" : "Уже в списке: \(modelID)"
                let (menuText, markup) = await renderSuperAdmin(chatKey: chatKey)
                try? await telegram.editMessage(.init(chatID: chatKey.chatID, messageID: menuMessageID, text: menuText, replyMarkup: markup))
                _ = try? await telegram.sendMessage(.init(
                    chatID: chatKey.chatID,
                    threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                    replyTo: nil,
                    text: toast,
                    replyMarkup: nil
                ))
            } else {
                await state.setPendingFreeModelInput(menuMessageID: menuMessageID, chatKey: chatKey)
            }
            return true
        }

        guard await state.hasPendingInput(chatKey: chatKey) else { return false }
        guard let pending = await state.consumePendingInput(chatKey: chatKey) else { return false }

        let canManageGlobal = await state.isAdmin(username: username, chatID: chatKey.chatID)

        if pending.scope == .global, !canManageGlobal {
            _ = try? await telegram.sendMessage(
                .init(
                    chatID: chatKey.chatID,
                    threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                    replyTo: nil,
                    text: "🔒 Только администратор может редактировать глобальные пресеты.",
                    replyMarkup: nil
                )
            )
            return true
        }

        let components = text.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard components.count == 2, !components[0].isEmpty, !components[1].isEmpty else {
            await state.setPendingInput(pending, chatKey: chatKey)
            _ = try? await telegram.sendMessage(
                .init(
                    chatID: chatKey.chatID,
                    threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                    replyTo: nil,
                    text: "⚠️ Неверный формат. Используйте: <code>Название | Значение</code>",
                    replyMarkup: nil
                )
            )
            return true
        }

        let display = components[0]
        let value = components[1]
        let toastText: String

        if pending.category == .model {
            await modelPriceMonitor?.refreshPricesIfNeeded(for: value)
        }

        switch (pending.scope, pending.kind) {
        case (.global, .add):
            _ = await state.addPreset(category: pending.category, display: display, value: value, chatID: chatKey.chatID)
            toastText = "✓ Глобальный пресет добавлен: \(display)"
        case (.global, .edit(let index)):
            let ok = await state.editPreset(category: pending.category, index: index, display: display, value: value, chatID: chatKey.chatID)
            toastText = ok ? "✓ Обновлён: \(display)" : "⚠️ Пресет не найден"
        case (.chat, .add):
            _ = await state.addChatPreset(category: pending.category, chatKey: chatKey, display: display, value: value)
            toastText = "✓ Пресет чата добавлен: \(display)"
        case (.chat, .edit(let index)):
            let ok = await state.editChatPreset(category: pending.category, chatKey: chatKey, index: index, display: display, value: value)
            toastText = ok ? "✓ Обновлён: \(display)" : "⚠️ Пресет не найден"
        }

        let (menuText, markup) = await renderPresetManagement(category: pending.category, chatKey: chatKey, canManageGlobal: canManageGlobal)
        try? await telegram.editMessage(
            .init(
                chatID: chatKey.chatID,
                messageID: pending.menuMessageID,
                text: menuText,
                replyMarkup: markup
            )
        )

        _ = try? await telegram.sendMessage(
            .init(
                chatID: chatKey.chatID,
                threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                replyTo: nil,
                text: toastText,
                replyMarkup: nil
            )
        )

        return true
    }

    func sendMenu(chatKey: ChatKey, username: String? = nil) async {
        await state.clearPendingInput(chatKey: chatKey)
        await state.clearPendingStarsPriceInput(chatKey: chatKey)
        await state.clearPendingFreeModelInput(chatKey: chatKey)
        let (text, markup) = await renderPage(.main, chatKey: chatKey, username: username)
        _ = try? await telegram.sendMessage(
            .init(
                chatID: chatKey.chatID,
                threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                replyTo: nil,
                text: text,
                replyMarkup: markup
            )
        )
    }

    private func processAction(
        parts: [String],
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard let command = parts.first, !command.isEmpty else {
            try await showPage(.main, chatKey: chatKey, callback: callback, message: message)
            return
        }

        switch command {
        case "open":
            await state.clearPendingInput(chatKey: chatKey)
            await state.clearPendingStarsPriceInput(chatKey: chatKey)
            await state.clearPendingFreeModelInput(chatKey: chatKey)
            try await showPage(.main, chatKey: chatKey, callback: callback, message: message)

        case "close":
            try await closeMenu(callback: callback, message: message)

        case "nav":
            guard parts.count >= 2 else {
                try await showPage(.main, chatKey: chatKey, callback: callback, message: message)
                return
            }
            let page = parts[1].lowercased()
            guard let menuPage = MenuPage(rawValue: page) else {
                try await showPage(.main, chatKey: chatKey, callback: callback, message: message)
                return
            }
            try await showPage(menuPage, chatKey: chatKey, callback: callback, message: message)

        case "role":
            guard parts.count >= 2 else { return }
            if parts[1] == "default" {
                let defaultRole = await state.defaultRole(chatID: chatKey.chatID)
                _ = await state.setRoleAndResetHistory(chatKey: chatKey, role: defaultRole)
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Роль по умолчанию")
                try await showPage(.role, chatKey: chatKey, callback: callback, message: message)
                return
            } else if parts[1] == "gsel", parts.count >= 3, let index = Int(parts[2]) {
                let presets = await state.rolePresets(chatID: chatKey.chatID)
                guard index >= 0, index < presets.count else {
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Пресет не найден")
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
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Пресет не найден")
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
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Пресет не найден")
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
                guard await state.isSuperAdmin(username: callback.from.username) else {
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
                    return
                }
                await state.addFreeModel(modelValue)
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🆓 Добавлено в бесплатные")
                try await showPage(.model, chatKey: chatKey, callback: callback, message: message)
                return
            } else if parts[1] == "unmarkfree" {
                guard await state.isSuperAdmin(username: callback.from.username) else {
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
                    return
                }
                await state.removeFreeModel(modelValue)
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Убрано из бесплатных")
                try await showPage(.model, chatKey: chatKey, callback: callback, message: message)
                return
            } else if parts[1] == "select" || parts[1] == "gsel" {
                let presets = await state.modelPresets(chatID: chatKey.chatID)
                guard let preset = presets.first(where: { $0.value == modelValue }) else {
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Модель не найдена")
                    return
                }
                let effectiveFree = await state.effectiveFreeModelIDs()
                let hasAccess = await state.hasFullModelAccess(username: callback.from.username)
                if !hasAccess, let eff = effectiveFree, !eff.contains(modelValue) {
                    let price = await state.starsPrice()
                    let hint = price.map { " (\($0) ⭐ /buy)" } ?? ""
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "⭐ Эта модель требует полного доступа\(hint)")
                    return
                }
                _ = await state.setModelAndResetHistory(chatKey: chatKey, newModel: modelValue)
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Модель: \(preset.display)")
                try await showPage(.model, chatKey: chatKey, callback: callback, message: message)
                return
            } else if parts[1] == "csel" {
                let chatPresets = await state.chatPresets(category: .model, chatKey: chatKey)
                guard let preset = chatPresets.first(where: { $0.value == modelValue }) else {
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Модель не найдена")
                    return
                }
                let effectiveFree = await state.effectiveFreeModelIDs()
                let hasAccess = await state.hasFullModelAccess(username: callback.from.username)
                if !hasAccess, let eff = effectiveFree, !eff.contains(modelValue) {
                    let price = await state.starsPrice()
                    let hint = price.map { " (\($0) ⭐ /buy)" } ?? ""
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "⭐ Эта модель требует полного доступа\(hint)")
                    return
                }
                _ = await state.setModelAndResetHistory(chatKey: chatKey, newModel: modelValue)
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Модель: \(preset.display)")
                try await showPage(.model, chatKey: chatKey, callback: callback, message: message)
                return
            }

        case "temp":
            guard parts.count >= 2, let temp = Float(parts[1]), (0.0...2.0).contains(temp) else { return }
            await state.setTemperature(chatKey: chatKey, value: temp)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Темп: \(Self.formatTemp(temp))")
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
                toastText = on ? "🟢 Токены включены" : "⚪️ Токены выключены"
            case "cost":
                let on = await state.toggleShowCost(chatKey: chatKey)
                toastText = on ? "🟢 Стоимость включена" : "⚪️ Стоимость выключена"
            case "model":
                let on = await state.toggleShowModel(chatKey: chatKey)
                toastText = on ? "🟢 Модель включена" : "⚪️ Модель выключена"
            case "backup":
                let on = await state.toggleBackupNotify(chatKey: chatKey)
                toastText = on ? "🟢 Уведомления включены" : "⚪️ Уведомления выключены"
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
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "История очищена")
                try await showPage(.history, chatKey: chatKey, callback: callback, message: message)
                return
            } else if parts.count >= 3, parts[1] == "length", let length = Int(parts[2]), (1...50).contains(length) {
                await state.setMaxHistory(chatKey: chatKey, newMax: length)
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Длина истории: \(length)")
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
                        text: "Провайдер сменён. Reasoning отключён — не поддерживается."
                    )
                } else {
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Провайдер: \(provider.commandValue)")
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
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Reasoning отключён")
                } else if let effort = ReasoningEffort(rawValue: parts[2]) {
                    await state.setReasoningEffort(chatKey: chatKey, effort: effort)
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Reasoning: \(effort.rawValue)")
                }
            } else {
                try? await telegram.answerCallback(
                    callbackQueryID: callback.id,
                    text: "Провайдер \(provider.commandValue) не поддерживает reasoning"
                )
            }
            try await showPage(.reasoning, chatKey: chatKey, callback: callback, message: message)
            return

        case "reset":
            await state.clearPendingInput(chatKey: chatKey)
            await state.clearPendingStarsPriceInput(chatKey: chatKey)
            await state.clearPendingFreeModelInput(chatKey: chatKey)
            await state.resetChat(chatKey: chatKey)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Настройки сброшены")
            try await showPage(.main, chatKey: chatKey, callback: callback, message: message)
            return

        case "help":
            try await showPage(.helpPage, chatKey: chatKey, callback: callback, message: message)

        case "freemodels":
            guard await state.isSuperAdmin(username: callback.from.username) else {
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
                        [menuButton("❌ Отмена", action: "nav:superadmin")]
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
                    try await showPage(.superAdmin, chatKey: chatKey, callback: callback, message: message)
                default:
                    try await showPage(.superAdmin, chatKey: chatKey, callback: callback, message: message)
                }
            } else {
                try await showPage(.superAdmin, chatKey: chatKey, callback: callback, message: message)
            }
            return

        case "stars":
            guard await state.isSuperAdmin(username: callback.from.username) else {
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
                        [menuButton("❌ Отмена", action: "nav:superadmin")]
                    ])
                    try await editOrAnswer(callback: callback, message: message, text: promptText, markup: markup)
                case "disable":
                    await state.setStarsPrice(nil)
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Продажи отключены")
                    try await showPage(.superAdmin, chatKey: chatKey, callback: callback, message: message)
                default:
                    try await showPage(.superAdmin, chatKey: chatKey, callback: callback, message: message)
                }
            } else {
                try await showPage(.superAdmin, chatKey: chatKey, callback: callback, message: message)
            }
            return

        case "noop":
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: nil)
            return

        case "pm":
            guard parts.count >= 2, let category = PresetCategory(rawValue: parts[1]) else { return }
            await state.clearPendingInput(chatKey: chatKey)
            let canManageGlobal = await state.isAdmin(username: callback.from.username, chatID: chatKey.chatID)

            if parts.count == 2 {
                let (text, markup) = await renderPresetManagement(category: category, chatKey: chatKey, canManageGlobal: canManageGlobal)
                try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)
                return
            }

            switch parts[2] {
            // Per-chat actions (anyone)
            case "add":
                let pending = PendingInput(category: category, scope: .chat, kind: .add, menuMessageID: message.message_id)
                await state.setPendingInput(pending, chatKey: chatKey)
                let (text, markup) = renderAwaitingInput(category: category, scope: .chat, kind: .add, preset: nil)
                try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)
            case "edit":
                guard parts.count >= 4, let index = Int(parts[3]) else { return }
                let chatPresets = await state.chatPresets(category: category, chatKey: chatKey)
                guard index >= 0, index < chatPresets.count else {
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Пресет не найден")
                    return
                }
                let pending = PendingInput(category: category, scope: .chat, kind: .edit(index: index), menuMessageID: message.message_id)
                await state.setPendingInput(pending, chatKey: chatKey)
                let (text, markup) = renderAwaitingInput(category: category, scope: .chat, kind: .edit(index: index), preset: chatPresets[index])
                try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)
            case "del":
                guard parts.count >= 4, let index = Int(parts[3]) else { return }
                let removed = await state.removeChatPresetByIndex(category: category, chatKey: chatKey, index: index)
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: removed ? "Пресет удалён" : "Пресет не найден")
                let (text, markup) = await renderPresetManagement(category: category, chatKey: chatKey, canManageGlobal: canManageGlobal)
                try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)

            // Scope picker shown to admins when clicking "Add preset"
            case "scopesel":
                guard canManageGlobal else {
                    let pending = PendingInput(category: category, scope: .chat, kind: .add, menuMessageID: message.message_id)
                    await state.setPendingInput(pending, chatKey: chatKey)
                    let (text, markup) = renderAwaitingInput(category: category, scope: .chat, kind: .add, preset: nil)
                    try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)
                    return
                }
                let scopeText = "<b>➕ Добавить пресет · \(category.displayName)</b>\n\nКуда добавить?"
                let scopeMarkup = InlineKeyboardMarkup(inline_keyboard: [
                    [menuButton("🌐 Глобальный (для всех чатов)", action: "pm:\(category.rawValue):gadd")],
                    [menuButton("💬 Только этот чат", action: "pm:\(category.rawValue):add")],
                    [menuButton("❌ Отмена", action: "pm:\(category.rawValue)")],
                ])
                try await editOrAnswer(callback: callback, message: message, text: scopeText, markup: scopeMarkup)
                return

            // Global actions (admin+)
            case "gadd":
                guard canManageGlobal else {
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только администратор")
                    return
                }
                let pending = PendingInput(category: category, scope: .global, kind: .add, menuMessageID: message.message_id)
                await state.setPendingInput(pending, chatKey: chatKey)
                let (text, markup) = renderAwaitingInput(category: category, scope: .global, kind: .add, preset: nil)
                try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)
            case "gedit":
                guard canManageGlobal else {
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только администратор")
                    return
                }
                guard parts.count >= 4, let index = Int(parts[3]) else { return }
                let globalPresets = await state.presets(for: category, chatID: chatKey.chatID)
                guard index >= 0, index < globalPresets.count else {
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Пресет не найден")
                    return
                }
                let pending = PendingInput(category: category, scope: .global, kind: .edit(index: index), menuMessageID: message.message_id)
                await state.setPendingInput(pending, chatKey: chatKey)
                let (text, markup) = renderAwaitingInput(category: category, scope: .global, kind: .edit(index: index), preset: globalPresets[index])
                try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)
            case "gdel":
                guard canManageGlobal else {
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только администратор")
                    return
                }
                guard parts.count >= 4, let index = Int(parts[3]) else { return }
                let removed = await state.removePresetByIndex(category: category, index: index, chatID: chatKey.chatID)
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: removed ? "Пресет удалён" : "Пресет не найден")
                let (text, markup) = await renderPresetManagement(category: category, chatKey: chatKey, canManageGlobal: canManageGlobal)
                try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)

            default:
                return
            }
            return

        default:
            try await telegram.answerCallback(callbackQueryID: callback.id, text: "Неизвестное действие")
        }
    }

    private func showPage(_ page: MenuPage, chatKey: ChatKey, callback: CallbackQuery, message: MaybeInaccessibleMessage) async throws {
        let (text, markup) = await renderPage(page, chatKey: chatKey, username: callback.from.username)
        try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)
    }

    private func closeMenu(callback: CallbackQuery, message: MaybeInaccessibleMessage) async throws {
        let chatKey = ChatKey(chatID: message.chat.id, threadID: message.message_thread_id ?? 0)
        await state.clearPendingInput(chatKey: chatKey)
        await state.clearPendingStarsPriceInput(chatKey: chatKey)
        await state.clearPendingFreeModelInput(chatKey: chatKey)
        try await telegram.editMessage(
            .init(
                chatID: message.chat.id,
                messageID: message.message_id,
                text: "Меню закрыто. Откройте снова — /menu",
                replyMarkup: InlineKeyboardMarkup(inline_keyboard: [])
            )
        )
        try? await telegram.answerCallback(callbackQueryID: callback.id, text: nil)
    }

    private func editOrAnswer(
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage,
        text: String,
        markup: InlineKeyboardMarkup
    ) async throws {
        do {
            try await telegram.editMessage(
                .init(
                    chatID: message.chat.id,
                    messageID: message.message_id,
                    text: text,
                    replyMarkup: markup
                )
            )
        } catch {
            _ = try? await telegram.sendMessage(
                .init(
                    chatID: message.chat.id,
                    threadID: message.message_thread_id,
                    replyTo: nil,
                    text: text,
                    replyMarkup: markup
                )
            )
        }
        try? await telegram.answerCallback(callbackQueryID: callback.id, text: nil)
    }

    private func renderPage(_ page: MenuPage, chatKey: ChatKey, username: String? = nil) async -> (String, InlineKeyboardMarkup) {
        switch page {
        case .main:
            return await renderMain(chatKey: chatKey, username: username)
        case .role:
            return await renderRole(chatKey: chatKey)
        case .model:
            return await renderModel(chatKey: chatKey, username: username)
        case .temp:
            return await renderTemp(chatKey: chatKey)
        case .stats:
            return await renderStats(chatKey: chatKey)
        case .history:
            return await renderHistory(chatKey: chatKey)
        case .provider:
            return await renderProvider(chatKey: chatKey)
        case .reasoning:
            return await renderReasoning(chatKey: chatKey)
        case .helpPage:
            return await renderHelp(chatKey: chatKey)
        case .superAdmin:
            return await renderSuperAdmin(chatKey: chatKey)
        case .close:
            return ("Меню закрыто. Откройте снова — /menu", InlineKeyboardMarkup(inline_keyboard: []))
        }
    }

    // MARK: - Renderers

    private func renderMain(chatKey: ChatKey, username: String? = nil) async -> (String, InlineKeyboardMarkup) {
        let help = await state.fetchHelp(chatKey: chatKey)
        let provider = await state.provider(chatKey: chatKey)
        let gateway = try? gateways.gateway(for: provider)
        let reasoningSupported = gateway?.capabilities.supportsReasoning ?? false
        let reasoningLabel = help.reasoningEffort?.rawValue ?? "выкл"
        let usage = help.cumulativeUsage
        let usageLine: String
        if usage.generationCount == 0 {
            usageLine = "📈 Запросов пока нет"
        } else {
            var parts: [String] = ["запросов <b>\(usage.generationCount)</b>"]
            if usage.totalTokens > 0 {
                parts.append("токенов <b>\(ResponseFooterFormatter.formatTokenValue(usage.totalTokens))</b>")
            }
            if usage.totalCost > 0 {
                parts.append("итого <b>$\(Self.formatCost(usage.totalCost))</b>")
            }
            usageLine = "📈 " + parts.joined(separator: " · ")
        }

        let text = """
        <b>⚙️ Настройки чата</b>

        🔌 Провайдер · <b>\(help.provider.commandValue)</b>
        🤖 Модель · <b>\(help.model)</b>
        🌡 Темп · <b>\(Self.formatTemp(help.temp))</b>
        📝 История · <b>\(help.maxHistory) сообщ.</b>\
        \(reasoningSupported ? "\n🧠 Reasoning · <b>\(reasoningLabel)</b>" : "")

        \(usageLine)
        """

        var rows: [[InlineKeyboardButton]] = [
            [menuButton("🤖 Модель", action: "nav:model"), menuButton("🎭 Роль", action: "nav:role")],
            [menuButton("🌡 Температура", action: "nav:temp"), menuButton("📝 История", action: "nav:history")],
            [menuButton("🔌 Провайдер", action: "nav:provider")],
        ]
        if reasoningSupported {
            rows[2].append(menuButton("🧠 Reasoning", action: "nav:reasoning"))
        }
        rows.append([menuButton("📊 Что показывать в ответе", action: "nav:stats")])
        if usage.generationCount > 0 {
            rows.append([menuButton("🗑 Сбросить статистику", action: "stats:usage-reset")])
        }
        rows.append([menuButton("❓ Справка", action: "nav:help"), menuButton("↺ Сбросить", action: "reset")])
        if await state.isSuperAdmin(username: username) {
            let price = await state.starsPrice()
            let starsLabel = price.map { "💫 Stars · \($0) ⭐" } ?? "💫 Продажа (выкл)"
            rows.append([menuButton(starsLabel, action: "nav:superadmin")])
        }
        rows.append([menuButton("✕ Закрыть", action: "close")])

        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    static func formatPriceM(_ perTokenPrice: Double) -> String {
        let perM = perTokenPrice * 1_000_000
        if perM == 0 { return "0" }
        if perM >= 1 { return String(format: "%.2f", perM) }
        if perM >= 0.01 { return String(format: "%.4f", perM) }
        return String(format: "%.6f", perM)
    }

    private static func formatCost(_ cost: Double) -> String {
        if cost == 0 { return "0" }
        if cost < 0.0001 { return String(format: "%.6f", cost) }
        if cost < 0.01 { return String(format: "%.5f", cost) }
        return String(format: "%.4f", cost)
    }

    private func renderRole(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
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

        rows.append([menuButton("↺ Стандартная роль", action: "role:default")])
        rows.append([menuButton("⚙️ Управление пресетами", action: "pm:role")])
        rows.append(navButtons())

        let text = """
        <b>🎭 Роль ассистента</b>

        Текущая:
        <blockquote expandable>\(help.role)</blockquote>

        <i>🌐 — общая для всех чатов · 💬 — только для этого</i>
        Своя роль — /setrole &lt;текст&gt;
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderModel(chatKey: ChatKey, username: String? = nil) async -> (String, InlineKeyboardMarkup) {
        let help = await state.fetchHelp(chatKey: chatKey)
        let globalPresets = await state.modelPresets(chatID: chatKey.chatID)
        let chatPresets = await state.chatPresets(category: .model, chatKey: chatKey)
        let effectiveFreeModels = await state.effectiveFreeModelIDs()
        let pinnedModels = Set(await state.freeModelIDs())
        let hasFullAccess = await state.hasFullModelAccess(username: username)
        let isSuperAdmin = await state.isSuperAdmin(username: username)
        let restrictionsActive = effectiveFreeModels != nil
        let modelPrices = await state.openRouterModelPrices()
        var rows: [[InlineKeyboardButton]] = []

        func isEffectivelyFree(_ id: String) -> Bool {
            guard let eff = effectiveFreeModels else { return true }
            return eff.contains(id)
        }

        func presetLabel(preset: Preset, scope: String) -> String {
            let isActive = preset.value == help.model
            var parts: [String] = []
            if isActive { parts.append("✓") }
            if restrictionsActive { parts.append(isEffectivelyFree(preset.value) ? "🆓" : "⭐") }
            parts.append(scope)
            parts.append(preset.display)
            return parts.joined(separator: " ")
        }

        func appendPresets(_ presets: [Preset], action: String) {
            if isSuperAdmin {
                for preset in presets {
                    let isPinned = pinnedModels.contains(preset.value)
                    let selectLabel = presetLabel(preset: preset, scope: action == "gsel" ? "🌐" : "💬")
                    let toggleLabel = isPinned ? "－🆓" : "＋🆓"
                    let toggleAction = isPinned ? "model:unmarkfree:\(preset.value)" : "model:markfree:\(preset.value)"
                    rows.append([
                        menuButton(selectLabel, action: "model:\(action):\(preset.value)"),
                        menuButton(toggleLabel, action: toggleAction),
                    ])
                }
            } else {
                var currentRow: [InlineKeyboardButton] = []
                for preset in presets {
                    let label = presetLabel(preset: preset, scope: action == "gsel" ? "🌐" : "💬")
                    currentRow.append(menuButton(label, action: "model:\(action):\(preset.value)"))
                    if currentRow.count == 2 { rows.append(currentRow); currentRow = [] }
                }
                if !currentRow.isEmpty { rows.append(currentRow) }
            }
        }

        if !globalPresets.isEmpty { appendPresets(globalPresets, action: "gsel") }
        if !chatPresets.isEmpty { appendPresets(chatPresets, action: "csel") }

        if modelPriceMonitor != nil {
            rows.append([menuButton("🆓 Бесплатные модели OpenRouter", action: "model:freemodels")])
        }
        rows.append([menuButton("⚙️ Управление пресетами", action: "pm:model")])
        rows.append(navButtons())

        var legendLine = ""
        var accessLine = ""
        if restrictionsActive {
            legendLine = "\n🆓 — для всех · ⭐ — полный доступ"
            if !hasFullAccess {
                accessLine = "\n\n<i>Модели с ⭐ доступны после покупки — /buy</i>"
            }
        }
        if isSuperAdmin {
            let pinnedHint = pinnedModels.isEmpty
                ? "<i>Нет закреплённых бесплатных моделей. Нажмите ＋🆓 чтобы закрепить.</i>"
                : "<i>＋🆓 — закрепить бесплатной · －🆓 — открепить</i>"
            accessLine = "\n\n\(pinnedHint)"
        }

        let allPresets = globalPresets + chatPresets
        var priceSection = ""
        if !modelPrices.isEmpty {
            let lines = allPresets.compactMap { preset -> String? in
                guard let price = modelPrices[preset.value] else { return nil }
                let inP = Self.formatPriceM(price.inputPerToken)
                let outP = Self.formatPriceM(price.outputPerToken)
                return "• \(preset.display) — ⬇️$\(inP)/M | ⬆️$\(outP)/M"
            }
            if !lines.isEmpty {
                priceSection = "\n\n" + lines.joined(separator: "\n")
            }
        }

        let text = """
        <b>🤖 Модель</b>

        Текущая · <code>\(help.model)</code>\(legendLine)\(priceSection)

        <i>Смена модели очистит историю.</i>
        Своя модель — /model &lt;id&gt;
        <i>ID моделей можно найти на openrouter.ai</i>\(accessLine)
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderTemp(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
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

        rows.append([menuButton("⚙️ Управление пресетами", action: "pm:temp")])
        rows.append(navButtons())

        let bucket = Self.tempBucket(help.temp)
        let text = """
        <b>🌡 Температура</b>

        Текущая · <b>\(Self.formatTemp(help.temp))</b> — \(bucket)

        <i>0.0 — точно и предсказуемо · 2.0 — креативно и хаотично</i>
        Своё значение — /settemp &lt;0.0–2.0&gt;
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderStats(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let help = await state.fetchHelp(chatKey: chatKey)
        let rows: [[InlineKeyboardButton]] = [
            [menuButton("\(toggleMark(help.showTokens)) Токены", action: "stats:toggle:tokens"),
             menuButton("\(toggleMark(help.showCost)) Стоимость", action: "stats:toggle:cost")],
            [menuButton("\(toggleMark(help.showModel)) Модель", action: "stats:toggle:model")],
            [menuButton("\(toggleMark(help.backupNotify)) Уведомления о бэкапе", action: "stats:toggle:backup")],
            navButtons(),
        ]
        let text = """
        <b>📊 Что показывать в ответе</b>

        🟢 — включено · ⚪️ — выключено

        <i>Токены — сколько слов обработано
        Стоимость — цена одного запроса в $
        Модель — какая модель ответила</i>

        Нажмите, чтобы переключить.
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderHistory(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
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

        rows.append([menuButton("🧹 Очистить историю", action: "history:clear")])
        rows.append([menuButton("⚙️ Управление пресетами", action: "pm:history")])
        rows.append(navButtons())

        let text = """
        <b>📝 Память бота</b>

        Помнит последние · <b>\(help.maxHistory) сообщ.</b>

        <i>Чем больше, тем лучше контекст, но дороже и медленнее.</i>
        Своё значение — /historylength &lt;1–50&gt;
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderProvider(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
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
        <b>🔌 Провайдер AI</b>

        Текущий · <b>\(help.provider.commandValue)</b>

        <i>OpenRouter — тысячи моделей (GPT, Claude, Gemini, DeepSeek…)
        DeepSeek — только модели DeepSeek, напрямую
        Yandex — YandexGPT</i>
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderReasoning(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let help = await state.fetchHelp(chatKey: chatKey)
        let provider = await state.provider(chatKey: chatKey)
        let gateway = try? gateways.gateway(for: provider)
        let supported = gateway?.capabilities.supportsReasoning ?? false
        let current = help.reasoningEffort?.rawValue

        if !supported {
            let rows = [navButtons()]
            let text = """
            <b>🧠 Reasoning</b>

            Провайдер <b>\(provider.commandValue)</b> не поддерживает reasoning.
            Смените провайдера, чтобы включить.
            """
            return (text, InlineKeyboardMarkup(inline_keyboard: rows))
        }

        func btn(_ value: String, label: String) -> InlineKeyboardButton {
            let mark = (current == value || (value == "off" && current == nil)) ? "✓ " : ""
            return menuButton(mark + label, action: "reasoning:set:\(value)")
        }

        let rows: [[InlineKeyboardButton]] = [
            [btn("low", label: "Low"), btn("medium", label: "Medium"), btn("high", label: "High")],
            [btn("off", label: "Выключить")],
            navButtons(),
        ]
        let text = """
        <b>🧠 Reasoning — глубина рассуждений</b>

        Текущий · <b>\(current ?? "выкл")</b>

        <i>Модель «думает» перед ответом — результат точнее.
        Low — быстро и дёшево
        Medium — баланс скорости и качества
        High — максимальная точность, медленнее</i>
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderHelp(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let help = await state.fetchHelp(chatKey: chatKey)
        let rows: [[InlineKeyboardButton]] = [
            [InlineKeyboardButton(text: "📘 Полная инструкция", callback_data: BotCallbackAction.faq.rawData)],
            navButtons(),
        ]
        return (formatHelpText(help), InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderSuperAdmin(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let price = await state.starsPrice()
        let priceLabel = price.map { "<b>\($0) ⭐</b>" } ?? "<b>отключена</b>"
        let freeModels = await state.freeModelIDs()
        let freeModelsText = freeModels.isEmpty
            ? "<i>не ограничены (все бесплатны)</i>"
            : freeModels.map { "• <code>\($0)</code>" }.joined(separator: "\n")

        var rows: [[InlineKeyboardButton]] = [
            [menuButton("✏️ Изменить цену Stars", action: "stars:setprice")],
        ]
        if price != nil {
            rows.append([menuButton("⛔ Отключить продажи", action: "stars:disable")])
        }
        rows.append([menuButton("🆓 Добавить бесплатную модель", action: "freemodels:add")])
        for (i, modelID) in freeModels.enumerated() {
            let shortID = modelID.count > 28 ? "…" + modelID.suffix(25) : modelID
            rows.append([
                menuButton("🗑 \(shortID)", action: "freemodels:remove:\(i)")
            ])
        }
        rows.append(navButtons())

        let text = """
        <b>💫 Продажа доступа (Telegram Stars)</b>

        Цена: \(priceLabel)

        <b>🆓 Бесплатные модели:</b>
        \(freeModelsText)

        Пользователи без доступа видят только бесплатные модели.
        Покупка даёт полный доступ — /buy
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    // MARK: - Preset management renderers

    private func renderPresetManagement(category: PresetCategory, chatKey: ChatKey, canManageGlobal: Bool) async -> (String, InlineKeyboardMarkup) {
        let globalPresets = await state.presets(for: category, chatID: chatKey.chatID)
        let chatPresets = await state.chatPresets(category: category, chatKey: chatKey)
        let modelPrices = category == .model ? await state.openRouterModelPrices() : [:]

        var text = "<b>📋 Управление пресетами · \(category.displayName)</b>\n\n"

        if globalPresets.isEmpty {
            text += "🌐 <b>Глобальные</b> — <i>нет</i>\n"
        } else {
            text += "🌐 <b>Глобальные</b> (только администратор)\n"
            for (i, preset) in globalPresets.enumerated() {
                if category == .role {
                    text += "\(i + 1). <b>\(preset.display)</b>\n<blockquote expandable>\(preset.value)</blockquote>\n"
                } else {
                    var line = "\(i + 1). <b>\(preset.display)</b> · <code>\(preset.value)</code>"
                    if let price = modelPrices[preset.value] {
                        line += " — ⬇️$\(Self.formatPriceM(price.inputPerToken))/M | ⬆️$\(Self.formatPriceM(price.outputPerToken))/M"
                    }
                    text += line + "\n"
                }
            }
        }

        text += "\n"

        if chatPresets.isEmpty {
            text += "💬 <b>Пресеты чата</b> — <i>нет</i>"
        } else {
            text += "💬 <b>Пресеты чата</b>\n"
            for (i, preset) in chatPresets.enumerated() {
                if category == .role {
                    text += "\(i + 1). <b>\(preset.display)</b>\n<blockquote expandable>\(preset.value)</blockquote>\n"
                } else {
                    var line = "\(i + 1). <b>\(preset.display)</b> · <code>\(preset.value)</code>"
                    if let price = modelPrices[preset.value] {
                        line += " — ⬇️$\(Self.formatPriceM(price.inputPerToken))/M | ⬆️$\(Self.formatPriceM(price.outputPerToken))/M"
                    }
                    text += line + "\n"
                }
            }
        }

        var rows: [[InlineKeyboardButton]] = []

        if canManageGlobal {
            for (i, preset) in globalPresets.enumerated() {
                rows.append([
                    menuButton("🌐 ✏️ \(preset.display)", action: "pm:\(category.rawValue):gedit:\(i)"),
                    menuButton("❌", action: "pm:\(category.rawValue):gdel:\(i)"),
                ])
            }
        }

        for (i, preset) in chatPresets.enumerated() {
            rows.append([
                menuButton("💬 ✏️ \(preset.display)", action: "pm:\(category.rawValue):edit:\(i)"),
                menuButton("❌", action: "pm:\(category.rawValue):del:\(i)"),
            ])
        }

        let addAction = canManageGlobal ? "pm:\(category.rawValue):scopesel" : "pm:\(category.rawValue):add"
        rows.append([menuButton("➕ Добавить пресет", action: addAction)])

        rows.append([
            menuButton("← К выбору", action: "nav:\(category.rawValue)"),
            menuButton("✕ Закрыть", action: "close"),
        ])

        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderAwaitingInput(category: PresetCategory, scope: PendingInput.Scope, kind: PendingInput.Kind, preset: Preset?) -> (String, InlineKeyboardMarkup) {
        let scopeLabel = scope == .global ? "🌐 Глобальный" : "💬 Пресет чата"
        let text: String
        switch kind {
        case .add:
            text = """
            <b>➕ Новый пресет · \(scopeLabel) · \(category.displayName)</b>

            Отправьте сообщение в формате:
            <code>Название | Значение</code>

            Пример: <code>\(category.addExample)</code>
            """
        case .edit:
            text = """
            <b>✏️ Редактирование · \(scopeLabel) · \(preset?.display ?? "")</b>

            Текущее значение:
            <code>\(preset?.value ?? "")</code>

            Отправьте новое в формате:
            <code>Название | Значение</code>
            """
        }

        let rows: [[InlineKeyboardButton]] = [
            [menuButton("❌ Отмена", action: "pm:\(category.rawValue)")],
        ]
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    // MARK: - Helpers

    private func menuButton(_ text: String, action: String) -> InlineKeyboardButton {
        .init(text: text, callback_data: BotCallbackAction.menu(action: action).rawData)
    }

    private func navButtons() -> [InlineKeyboardButton] {
        [
            menuButton("← Назад", action: "open"),
            menuButton("✕ Закрыть", action: "close"),
        ]
    }

    private func toggleMark(_ value: Bool) -> String {
        value ? "🟢" : "⚪️"
    }

    static func formatTemp(_ value: Float) -> String {
        if value.rounded() == value {
            return String(format: "%.1f", value)
        }
        return String(format: "%.2f", value)
    }

    static func tempBucket(_ value: Float) -> String {
        switch value {
        case ..<0.4: return "точно"
        case ..<0.9: return "сдержанно"
        case ..<1.3: return "сбалансировано"
        case ..<1.7: return "креативно"
        default: return "хаотично"
        }
    }

    private func formatHelpText(_ help: HelpData) -> String {
        let reasoningLabel = help.reasoningEffort?.rawValue ?? "выкл"
        let suffix = help.testModeSuffix.map(String.init) ?? "выкл"
        return """
        <b>⚙️ Настройки чата</b>

        🔌 Провайдер · <b>\(help.provider.commandValue)</b>
        🤖 Модель · <b>\(help.model)</b>
        🌡 Темп · <b>\(Self.formatTemp(help.temp))</b> — \(Self.tempBucket(help.temp))
        📝 История · <b>\(help.maxHistory) сообщ.</b>
        🧠 Reasoning · <b>\(reasoningLabel)</b>

        <b>Показ в ответе:</b>
        \(yesNo(help.showTokens)) Токены
        \(yesNo(help.showCost)) Стоимость
        \(yesNo(help.showModel)) Модель
        \(yesNo(help.backupNotify)) Уведомления о бэкапе

        <b>🎭 Роль:</b>
        <blockquote expandable>\(help.role)</blockquote>

        <b>Роль по умолчанию:</b>
        <blockquote expandable>\(help.defaultRole)</blockquote>

        <i>Тест-режим · \(suffix)</i>
        """
    }

    private func yesNo(_ value: Bool) -> String {
        value ? "✓" : "·"
    }
}

extension ServiceProvider: CaseIterable {
    public static var allCases: [ServiceProvider] {
        [.openrouter, .deepseek, .yandex]
    }
}
