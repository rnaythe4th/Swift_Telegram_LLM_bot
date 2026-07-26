import Foundation

// Presets (заготовки): management pages and the actions behind them.

extension BotMenuHandler {
    /// Preset management (заготовки) for the four categories.
    func processPresetAction(
        command: String,
        parts: [String],
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        switch command {
        case "pm":
            guard parts.count >= 2, let category = PresetCategory(rawValue: parts[1]) else { return }
            await state.clearPendingInput(chatKey: chatKey)
            let canManageGlobal = await state.isAdmin(username: invokerKey(callback), chatID: chatKey.chatID)

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
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Заготовка не найдена")
                    return
                }
                let pending = PendingInput(category: category, scope: .chat, kind: .edit(index: index), menuMessageID: message.message_id)
                await state.setPendingInput(pending, chatKey: chatKey)
                let (text, markup) = renderAwaitingInput(category: category, scope: .chat, kind: .edit(index: index), preset: chatPresets[index])
                try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)
            case "del":
                guard parts.count >= 4, let index = Int(parts[3]) else { return }
                let removed = await state.removeChatPresetByIndex(category: category, chatKey: chatKey, index: index)
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: removed ? "Заготовка удалена" : "Заготовка не найдена")
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
                let scopeText = "<b>➕ Добавить заготовку · \(category.displayName)</b>\n\nКуда добавить?"
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
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Заготовка не найдена")
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
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: removed ? "Заготовка удалена" : "Заготовка не найдена")
                let (text, markup) = await renderPresetManagement(category: category, chatKey: chatKey, canManageGlobal: canManageGlobal)
                try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)

            default:
                return
            }
            return

        default:
            break
        }
    }

    // MARK: - Preset management renderers

    func renderPresetManagement(category: PresetCategory, chatKey: ChatKey, canManageGlobal: Bool) async -> (String, InlineKeyboardMarkup) {
        let globalPresets = await state.presets(for: category, chatID: chatKey.chatID)
        let chatPresets = await state.chatPresets(category: category, chatKey: chatKey)
        let modelPrices = category == .model ? await state.openRouterModelPrices() : [:]
        let priceMultiplier = await state.priceMultiplier()

        var text = "<b>📋 Мои заготовки · \(category.displayName)</b>\n\n"

        if globalPresets.isEmpty {
            text += "🌐 <b>Общие — во всех чатах</b> — <i>нет</i>\n"
        } else {
            text += "🌐 <b>Общие — во всех чатах</b> (меняет администратор)\n"
            for (i, preset) in globalPresets.enumerated() {
                if category == .role {
                    text += "\(i + 1). <b>\(preset.display)</b>\n<blockquote expandable>\(preset.value)</blockquote>\n"
                } else {
                    var line = "\(i + 1). <b>\(preset.display)</b> · <code>\(preset.value)</code>"
                    if let provider = preset.provider {
                        line += " · 📡 <code>\(provider)</code>"
                    }
                    if let price = modelPrices[preset.value] {
                        line += " — ⬇️$\(Self.formatPriceM(price.inputPerToken * priceMultiplier))/M | ⬆️$\(Self.formatPriceM(price.outputPerToken * priceMultiplier))/M"
                    }
                    text += line + "\n"
                }
            }
        }

        text += "\n"

        if chatPresets.isEmpty {
            text += "💬 <b>Заготовки этого чата</b> — <i>нет</i>"
        } else {
            text += "💬 <b>Заготовки этого чата</b>\n"
            for (i, preset) in chatPresets.enumerated() {
                if category == .role {
                    text += "\(i + 1). <b>\(preset.display)</b>\n<blockquote expandable>\(preset.value)</blockquote>\n"
                } else {
                    var line = "\(i + 1). <b>\(preset.display)</b> · <code>\(preset.value)</code>"
                    if let provider = preset.provider {
                        line += " · 📡 <code>\(provider)</code>"
                    }
                    if let price = modelPrices[preset.value] {
                        line += " — ⬇️$\(Self.formatPriceM(price.inputPerToken * priceMultiplier))/M | ⬆️$\(Self.formatPriceM(price.outputPerToken * priceMultiplier))/M"
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
        rows.append([menuButton("➕ Добавить заготовку", action: addAction)])

        rows.append([
            menuButton("← К выбору", action: "nav:\(category.rawValue)"),
            menuButton("✕ Закрыть", action: "close"),
        ])

        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderAwaitingInput(category: PresetCategory, scope: PendingInput.Scope, kind: PendingInput.Kind, preset: Preset?) -> (String, InlineKeyboardMarkup) {
        let scopeLabel = scope == .global ? "🌐 Общая" : "💬 Только этот чат"
        let text: String
        let formatLine = category == .model
            ? "<code>Название | Значение | Сервис</code>\n<i>Сервис можно не указывать.</i>"
            : "<code>Название | Значение</code>"
        switch kind {
        case .add:
            text = """
            <b>➕ Новая заготовка · \(scopeLabel) · \(category.displayName)</b>

            Отправьте сообщение в формате:
            \(formatLine)

            Пример: <code>\(category.addExample)</code>
            """
        case .edit:
            let currentValue = (preset?.value ?? "") + (preset?.provider.map { " | \($0)" } ?? "")
            text = """
            <b>✏️ Редактирование · \(scopeLabel) · \(preset?.display ?? "")</b>

            Текущее значение:
            <code>\(currentValue)</code>

            Отправьте новое в формате:
            \(formatLine)
            """
        }

        let rows: [[InlineKeyboardButton]] = [
            [menuButton("❌ Отмена", action: "pm:\(category.rawValue)")],
        ]
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }
}
