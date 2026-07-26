import Foundation

// Onboarding examples: the ready-made prompts shown in the greeting.

extension BotMenuHandler {
    func handleOnboardingAdminAction(
        parts: [String],
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard parts.count >= 2 else {
            try await showPage(.superOnboarding, chatKey: chatKey, callback: callback, message: message)
            return
        }
        var config = await state.onboardingConfig()

        /// The example a positional action refers to; nil answers the callback.
        func example(at index: Int) async -> OnboardingExample? {
            guard index >= 0, index < config.examples.count else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Пример не найден")
                return nil
            }
            return config.examples[index]
        }

        switch parts[1] {
        case "toggle":
            config.enabled.toggle()
            await state.setOnboardingConfig(config)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: config.enabled ? "🟢 Включены" : "⚪️ Выключены")
            try await showPage(.superOnboarding, chatKey: chatKey, callback: callback, message: message)

        case "groups":
            config.showInGroups.toggle()
            await state.setOnboardingConfig(config)
            try? await telegram.answerCallback(
                callbackQueryID: callback.id,
                text: config.showInGroups ? "🟢 И в группах" : "⚪️ Только в личке"
            )
            try await showPage(.superOnboarding, chatKey: chatKey, callback: callback, message: message)

        case "add":
            guard config.examples.count < OnboardingConfig.maxExamples else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Максимум \(OnboardingConfig.maxExamples) примеров")
                return
            }
            await state.setAdminPendingInput(.init(kind: .onboardingAdd, menuMessageID: message.message_id, payload: nil), chatKey: chatKey)
            let prompt = """
            <b>➕ Новый пример-запрос</b>

            Отправьте одним сообщением:
            <code>Кнопка | Текст запроса</code>

            <i>Пример:</i> <code>🍳 Рецепт | Придумай рецепт ужина из курицы и риса за 20 минут</code>

            Кнопка — до \(OnboardingConfig.maxLabelLength) символов, запрос — до \(OnboardingConfig.maxPromptLength). Запрос должен быть самодостаточным: по тапу он уходит модели как есть.
            """
            let markup = InlineKeyboardMarkup(inline_keyboard: [[menuButton("❌ Отмена", action: "nav:superonboarding")]])
            try await editOrAnswer(callback: callback, message: message, text: prompt, markup: markup)

        case "edit":
            guard parts.count >= 3, let index = Int(parts[2]), let item = await example(at: index) else { return }
            await state.setAdminPendingInput(
                .init(kind: .onboardingEdit, menuMessageID: message.message_id, payload: item.id),
                chatKey: chatKey
            )
            let prompt = """
            <b>✏️ Пример · \(OnboardingPresenter.escape(item.label))</b>

            Текущий запрос:
            <blockquote>\(OnboardingPresenter.escape(item.prompt))</blockquote>

            Отправьте новое значение в формате:
            <code>Кнопка | Текст запроса</code>

            <i>Счётчик тапов (\(item.taps)) сохранится.</i>
            """
            let markup = InlineKeyboardMarkup(inline_keyboard: [[menuButton("❌ Отмена", action: "nav:superonboarding")]])
            try await editOrAnswer(callback: callback, message: message, text: prompt, markup: markup)

        case "on":
            guard parts.count >= 3, let index = Int(parts[2]), let item = await example(at: index) else { return }
            let newValue = await state.toggleOnboardingExample(id: item.id)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: newValue == true ? "🟢 Показывается" : "⚪️ Скрыт")
            try await showPage(.superOnboarding, chatKey: chatKey, callback: callback, message: message)

        case "place":
            guard parts.count >= 3, let index = Int(parts[2]), let item = await example(at: index) else { return }
            let placement = await state.cycleOnboardingExamplePlacement(id: item.id)
            try? await telegram.answerCallback(
                callbackQueryID: callback.id,
                text: placement.map { "📍 Показывать: \($0.shortLabel)" } ?? "Пример не найден"
            )
            try await showPage(.superOnboarding, chatKey: chatKey, callback: callback, message: message)

        case "up":
            guard parts.count >= 3, let index = Int(parts[2]), let item = await example(at: index) else { return }
            let moved = await state.moveOnboardingExampleUp(id: item.id)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: moved ? "↑ Выше" : "Уже первый")
            try await showPage(.superOnboarding, chatKey: chatKey, callback: callback, message: message)

        case "del":
            guard parts.count >= 3, let index = Int(parts[2]), let item = await example(at: index) else { return }
            let removed = await state.removeOnboardingExample(id: item.id)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: removed ? "🗑 Удалён" : "Пример не найден")
            try await showPage(.superOnboarding, chatKey: chatKey, callback: callback, message: message)

        case "preview":
            // Renders the real buttons for the room the preview is opened in;
            // tapping one runs a real generation here (that is the point — the
            // super-admin sees exactly what users get).
            let isGroup = chatKey.chatID < 0
            let rows = OnboardingPresenter.exampleRows(config, inGroup: isGroup)
            guard !rows.isEmpty else {
                try? await telegram.answerCallback(
                    callbackQueryID: callback.id,
                    text: isGroup ? "Для групп активных примеров нет" : "Для лички активных примеров нет"
                )
                return
            }
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: nil)
            _ = try? await telegram.sendMessage(.init(
                chatID: chatKey.chatID,
                threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                replyTo: nil,
                text: "👁 <i>Так это видит пользователь\(isGroup ? " в группе" : " в личке"):</i>\n\n" + OnboardingPresenter.invitation,
                replyMarkup: InlineKeyboardMarkup(inline_keyboard: rows)
            ))

        case "reset":
            await state.resetOnboardingExamplesToDefaults()
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "↺ Стандартный набор")
            try await showPage(.superOnboarding, chatKey: chatKey, callback: callback, message: message)

        case "clearstats":
            await state.resetOnboardingTapStats()
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🗑 Счётчики обнулены")
            try await showPage(.superOnboarding, chatKey: chatKey, callback: callback, message: message)

        default:
            try await showPage(.superOnboarding, chatKey: chatKey, callback: callback, message: message)
        }
    }

    /// Onboarding examples (roadmap step 9): the whole set is edited here — no
    /// example text lives in code — plus the monitoring that says which prompt
    /// actually gets tapped (taps per example, share of the total).
    func renderSuperOnboarding(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let config = await state.onboardingConfig()
        let report = await state.funnelReport()
        let shown = report.count(.onboardingShown)
        let tapped = report.count(.exampleTapped)
        let totalTaps = config.examples.reduce(0) { $0 + $1.taps }

        func pct(_ num: Int, _ den: Int) -> String {
            guard den > 0 else { return "—" }
            return String(format: "%.0f%%", Double(num) / Double(den) * 100)
        }

        var rows: [[InlineKeyboardButton]] = [
            [menuButton(config.enabled ? "🟢 Примеры включены" : "⚪️ Примеры выключены", action: "onb:toggle")],
            [menuButton(config.showInGroups ? "🟢 Показывать в группах" : "⚪️ Только в личке", action: "onb:groups")],
        ]
        // Two rows per example: five buttons squeezed into one row left the
        // example's own name unreadable, which is the one thing you need to
        // see to know which row you are editing.
        for (index, example) in config.examples.enumerated() {
            rows.append([
                menuButton("\(example.enabled ? "🟢" : "⚪️") \(example.label)", action: "onb:on:\(index)"),
            ])
            rows.append([
                menuButton("📍 \(example.placement.shortLabel)", action: "onb:place:\(index)"),
                menuButton("✏️ Изменить", action: "onb:edit:\(index)"),
                menuButton("↑ Выше", action: "onb:up:\(index)"),
                menuButton("❌ Удалить", action: "onb:del:\(index)"),
            ])
        }
        if config.examples.count < OnboardingConfig.maxExamples {
            rows.append([menuButton("➕ Добавить пример", action: "onb:add")])
        }
        rows.append([menuButton("👁 Предпросмотр", action: "onb:preview"),
                     menuButton("↺ Стандартные", action: "onb:reset")])
        if totalTaps > 0 {
            rows.append([menuButton("🗑 Обнулить счётчики тапов", action: "onb:clearstats")])
        }
        rows.append([menuButton("← К супер-админу", action: "nav:superadmin")])

        var lines: [String] = [
            "<b>💡 Примеры-запросы (онбординг)</b>",
            "",
            "Статус · <b>\(config.enabled ? "включены" : "выключены")</b> · в приветствии группы · <b>\(config.showInGroups ? "да" : "нет")</b>",
            "Показов приветствия с примерами · <b>\(shown)</b> · тапов · <b>\(tapped)</b> · вовлечение <b>\(pct(tapped, shown))</b>",
            "",
        ]

        if config.examples.isEmpty {
            lines.append("<i>Список пуст — пользователь увидит приветствие без кнопок-примеров.</i>")
        } else {
            for example in config.examples {
                let share = totalTaps > 0 ? " · \(pct(example.taps, totalTaps))" : ""
                lines.append("\(example.enabled ? "🟢" : "⚪️") <b>\(OnboardingPresenter.escape(example.label))</b> · 📍\(example.placement.shortLabel) · тапов \(example.taps)\(share)")
                lines.append("<blockquote>\(OnboardingPresenter.escape(example.prompt))</blockquote>")
            }
            let inPrivate = config.activeExamples(inGroup: false).count
            let inGroups = config.activeExamples(inGroup: true).count
            lines.append("")
            lines.append("Показывается кнопок · в личке <b>\(inPrivate)</b> · в группах <b>\(config.showInGroups ? "\(inGroups)" : "0")</b>")
        }

        lines.append("")
        lines.append("<i>Тап по примеру = обычный запрос: работают лимиты, биллинг и история чата. 📍 задаёт, где кнопка видна: личка, группы или везде — в общем чате и в личке нужны разные примеры. Тексты и порядок правятся здесь, без передеплоя. Команда — /examples.</i>")

        return (lines.joined(separator: "\n"), InlineKeyboardMarkup(inline_keyboard: rows))
    }
}
