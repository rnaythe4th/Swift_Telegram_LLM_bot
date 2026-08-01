import Foundation

// Presets (заготовки): management pages and the actions behind them.

extension BotMenuHandler {
    /// Preset management (заготовки) for the four categories.
    func processPresetAction(
        route: MenuRoute,
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard route.command == .pm else { return }
        guard let category = PresetCategory(rawValue: route.sub) else { return }
        await state.clearPending(chatKey: chatKey)
        let canManageGlobal = await state.isAdmin(invokerKey(callback), chatID: chatKey.chatID)

        guard let subAction = route.arg(2) else {
            try await editOrAnswer(callback: callback, message: message, screen: await renderPresetManagement(category: category, chatKey: chatKey, canManageGlobal: canManageGlobal))
            return
        }

        switch subAction {
        // Per-chat actions (anyone)
        case "add":
            let pending = PresetInput(category: category, scope: .chat, kind: .add)
            await state.setPending(.preset(pending), menuMessageID: message.message_id, chatKey: chatKey)
            try await editOrAnswer(callback: callback, message: message, screen: renderAwaitingInput(category: category, scope: .chat, kind: .add, preset: nil))
        case "edit":
            guard let index = route.int(3) else { return }
            let chatPresets = await state.chatPresets(category: category, chatKey: chatKey)
            guard index >= 0, index < chatPresets.count else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: Texts.presetNotFound)
                return
            }
            let pending = PresetInput(category: category, scope: .chat, kind: .edit(index: index))
            await state.setPending(.preset(pending), menuMessageID: message.message_id, chatKey: chatKey)
            try await editOrAnswer(callback: callback, message: message, screen: renderAwaitingInput(category: category, scope: .chat, kind: .edit(index: index), preset: chatPresets[index]))
        case "del":
            guard let index = route.int(3) else { return }
            let removed = await state.removeChatPresetByIndex(category: category, chatKey: chatKey, index: index)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: removed ? "Заготовка удалена" : Texts.presetNotFound)
            try await editOrAnswer(callback: callback, message: message, screen: await renderPresetManagement(category: category, chatKey: chatKey, canManageGlobal: canManageGlobal))

        // Scope picker shown to admins when clicking "Add preset"
        case "scopesel":
            guard canManageGlobal else {
                let pending = PresetInput(category: category, scope: .chat, kind: .add)
                await state.setPending(.preset(pending), menuMessageID: message.message_id, chatKey: chatKey)
                try await editOrAnswer(callback: callback, message: message, screen: renderAwaitingInput(category: category, scope: .chat, kind: .add, preset: nil))
                return
            }
            let scopeText = "<b>➕ Добавить заготовку · \(category.displayName)</b>\n\nКуда добавить?"
            let scopeMarkup: Keyboard = [
                [menuButton("🌐 Глобальный (для всех чатов)", .pm, "\(category.rawValue)", "gadd")],
                [menuButton("💬 Только этот чат", .pm, "\(category.rawValue)", "add")],
                [menuButton(Texts.cancel, .pm, "\(category.rawValue)")],
            ]
            try await editOrAnswer(callback: callback, message: message, screen: MenuScreen(scopeText, scopeMarkup))
            return

        // Global actions (admin+)
        case "gadd":
            guard canManageGlobal else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: Texts.adminOnly)
                return
            }
            let pending = PresetInput(category: category, scope: .global, kind: .add)
            await state.setPending(.preset(pending), menuMessageID: message.message_id, chatKey: chatKey)
            try await editOrAnswer(callback: callback, message: message, screen: renderAwaitingInput(category: category, scope: .global, kind: .add, preset: nil))
        case "gedit":
            guard canManageGlobal else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: Texts.adminOnly)
                return
            }
            guard let index = route.int(3) else { return }
            let globalPresets = await state.presets(for: category, chatID: chatKey.chatID)
            guard index >= 0, index < globalPresets.count else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: Texts.presetNotFound)
                return
            }
            let pending = PresetInput(category: category, scope: .global, kind: .edit(index: index))
            await state.setPending(.preset(pending), menuMessageID: message.message_id, chatKey: chatKey)
            try await editOrAnswer(callback: callback, message: message, screen: renderAwaitingInput(category: category, scope: .global, kind: .edit(index: index), preset: globalPresets[index]))
        case "gdel":
            guard canManageGlobal else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: Texts.adminOnly)
                return
            }
            guard let index = route.int(3) else { return }
            let removed = await state.removePresetByIndex(category: category, index: index, chatID: chatKey.chatID)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: removed ? "Заготовка удалена" : Texts.presetNotFound)
            try await editOrAnswer(callback: callback, message: message, screen: await renderPresetManagement(category: category, chatKey: chatKey, canManageGlobal: canManageGlobal))

        default:
            return
        }
    }

    // MARK: - Preset management renderers

    func renderPresetManagement(category: PresetCategory, chatKey: ChatKey, canManageGlobal: Bool) async -> MenuScreen {
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

        var rows: Keyboard = []

        if canManageGlobal {
            for (i, preset) in globalPresets.enumerated() {
                rows.row([
                    menuButton("🌐 ✏️ \(preset.display)", .pm, "\(category.rawValue)", "gedit", "\(i)"),
                    menuButton("❌", .pm, "\(category.rawValue)", "gdel", "\(i)"),
                ])
            }
        }

        for (i, preset) in chatPresets.enumerated() {
            rows.row([
                menuButton("💬 ✏️ \(preset.display)", .pm, "\(category.rawValue)", "edit", "\(i)"),
                menuButton("❌", .pm, "\(category.rawValue)", "del", "\(i)"),
            ])
        }

        rows.row([menuButton(
            "➕ Добавить заготовку",
            .pm, category.rawValue, canManageGlobal ? "scopesel" : "add"
        )])

        rows.row([
            backButton(to: MenuPage(category: category)),
            menuButton(Texts.close, command: .close),
        ])

        return MenuScreen(text, rows)
    }

    private func renderAwaitingInput(category: PresetCategory, scope: PresetInput.Scope, kind: PresetInput.Kind, preset: Preset?) -> MenuScreen {
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

        let rows: Keyboard = [
            [menuButton(Texts.cancel, .pm, "\(category.rawValue)")],
        ]
        return MenuScreen(text, rows)
    }
}
