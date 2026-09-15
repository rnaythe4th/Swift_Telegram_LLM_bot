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
            guard let id = route.arg(3) else { return }
            let chatPresets = await state.chatPresets(category: category, chatKey: chatKey)
            guard let preset = chatPresets.first(where: { $0.id == id }) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: Texts.presetNotFound)
                return
            }
            let pending = PresetInput(category: category, scope: .chat, kind: .edit(id: id))
            await state.setPending(.preset(pending), menuMessageID: message.message_id, chatKey: chatKey)
            try await editOrAnswer(callback: callback, message: message, screen: renderAwaitingInput(category: category, scope: .chat, kind: .edit(id: id), preset: preset))
        case "del":
            guard let id = route.arg(3) else { return }
            let removed = await state.removeChatPreset(category: category, chatKey: chatKey, id: id)
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
            guard let id = route.arg(3) else { return }
            let globalPresets = await state.presets(for: category, chatID: chatKey.chatID)
            guard let preset = globalPresets.first(where: { $0.id == id }) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: Texts.presetNotFound)
                return
            }
            let pending = PresetInput(category: category, scope: .global, kind: .edit(id: id))
            await state.setPending(.preset(pending), menuMessageID: message.message_id, chatKey: chatKey)
            try await editOrAnswer(callback: callback, message: message, screen: renderAwaitingInput(category: category, scope: .global, kind: .edit(id: id), preset: preset))
        case "gdel":
            guard canManageGlobal else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: Texts.adminOnly)
                return
            }
            guard let id = route.arg(3) else { return }
            let removed = await state.removePreset(category: category, id: id, chatID: chatKey.chatID)
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

        // Preset text is somebody's arbitrary input on its way into an HTML
        // message, so it goes in escaped (`Preset.escapedDisplay`); the buttons
        // below take the caption raw, because a caption is not markup.
        func lines(_ presets: [Preset]) -> String {
            var text = ""
            for (i, preset) in presets.enumerated() {
                if category == .role {
                    text += "\(i + 1). <b>\(preset.escapedDisplay)</b>\n<blockquote expandable>\(preset.escapedValue)</blockquote>\n"
                    continue
                }
                var line = "\(i + 1). <b>\(preset.escapedDisplay)</b> · <code>\(preset.escapedValue)</code>"
                if let provider = preset.escapedProvider {
                    line += " · 📡 <code>\(provider)</code>"
                }
                if let price = modelPrices[preset.value] {
                    line += " — ⬇️$\(Self.formatPriceM(price.inputPerToken * priceMultiplier))/M | ⬆️$\(Self.formatPriceM(price.outputPerToken * priceMultiplier))/M"
                }
                text += line + "\n"
            }
            return text
        }

        var text = "<b>📋 Мои заготовки · \(category.displayName)</b>\n\n"

        if globalPresets.isEmpty {
            text += "🌐 <b>Общие — во всех чатах</b> — <i>нет</i>\n"
        } else {
            text += "🌐 <b>Общие — во всех чатах</b> (меняет администратор)\n"
            text += lines(globalPresets)
        }

        text += "\n"

        if chatPresets.isEmpty {
            text += "💬 <b>Заготовки этого чата</b> — <i>нет</i>"
        } else {
            text += "💬 <b>Заготовки этого чата</b>\n"
            text += lines(chatPresets)
        }

        var rows: Keyboard = []

        // Buttons carry the preset's id, not its position: this keyboard
        // describes the list as it was when the page was drawn, and a delete
        // addressed by position removes whatever has slid into that slot since.
        if canManageGlobal {
            for preset in globalPresets {
                rows.row([
                    menuButton("🌐 ✏️ \(preset.display)", .pm, "\(category.rawValue)", "gedit", preset.id),
                    menuButton("❌", .pm, "\(category.rawValue)", "gdel", preset.id),
                ])
            }
        }

        for preset in chatPresets {
            rows.row([
                menuButton("💬 ✏️ \(preset.display)", .pm, "\(category.rawValue)", "edit", preset.id),
                menuButton("❌", .pm, "\(category.rawValue)", "del", preset.id),
            ])
        }

        // Both lists full means every "add" would be refused; saying so beats a
        // button that answers with a complaint.
        let scope = canManageGlobal ? "scopesel" : "add"
        let canAddMore = chatPresets.count < PresetList.maxCount
            || (canManageGlobal && globalPresets.count < PresetList.maxCount)
        if canAddMore {
            rows.row([menuButton("➕ Добавить заготовку", .pm, category.rawValue, scope)])
        } else {
            text += "\n\n<i>Список заполнен: \(PresetList.maxCount) заготовок. Удалите ненужную, чтобы добавить новую.</i>"
        }

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
            let currentValue = (preset?.escapedValue ?? "") + (preset?.escapedProvider.map { " | \($0)" } ?? "")
            text = """
            <b>✏️ Редактирование · \(scopeLabel) · \(preset?.escapedDisplay ?? "")</b>

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
