import Foundation

// Onboarding examples: the ready-made prompts shown in the greeting.

extension BotMenuHandler {
    func handleOnboardingAdminAction(
        route: MenuRoute,
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard !route.sub.isEmpty else {
            try await showPage(.superOnboarding, chatKey: chatKey, callback: callback, message: message)
            return
        }
        var config = await state.onboardingConfig()

        /// The example a button points at, by its id; nil answers the callback.
        ///
        /// Not by position: the page reorders ("↑ Выше") and deletes its own
        /// list, so a row number describes the keyboard rather than the example
        /// it was drawn for — and «❌ Удалить» would then remove the neighbour.
        func example() async -> OnboardingExample? {
            guard let id = route.arg(2), let found = config.examples.first(where: { $0.id == id }) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: Texts.exampleNotFound)
                return nil
            }
            return found
        }

        switch route.sub {
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
            await state.setPending(.admin(.init(kind: .onboardingAdd)), menuMessageID: message.message_id, chatKey: chatKey)
            let prompt = """
            <b>➕ Новый пример-запрос</b>

            Отправьте одним сообщением:
            <code>Кнопка | Текст запроса</code>

            <i>Пример:</i> <code>🍳 Рецепт | Придумай рецепт ужина из курицы и риса за 20 минут</code>

            Кнопка — до \(OnboardingConfig.maxLabelLength) символов, запрос — до \(OnboardingConfig.maxPromptLength). Запрос должен быть самодостаточным: по тапу он уходит модели как есть.
            """
            let markup: Keyboard = [[cancelButton(to: .superOnboarding)]]
            try await editOrAnswer(callback: callback, message: message, screen: MenuScreen(prompt, markup))

        case "edit":
            guard let item = await example() else { return }
            await state.setPending(
                .admin(.init(kind: .onboardingEdit, payload: item.id)),
                menuMessageID: message.message_id,
                chatKey: chatKey
            )
            let prompt = """
            <b>✏️ Пример · \(item.escapedLabel)</b>

            Текущий запрос:
            <blockquote>\(item.escapedPrompt)</blockquote>

            Отправьте новое значение в формате:
            <code>Кнопка | Текст запроса</code>

            <i>Счётчик тапов (\(item.taps)) сохранится.</i>
            """
            let markup: Keyboard = [[cancelButton(to: .superOnboarding)]]
            try await editOrAnswer(callback: callback, message: message, screen: MenuScreen(prompt, markup))

        case "on":
            guard let item = await example() else { return }
            let newValue = await state.toggleOnboardingExample(id: item.id)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: newValue == true ? "🟢 Показывается" : "⚪️ Скрыт")
            try await showPage(.superOnboarding, chatKey: chatKey, callback: callback, message: message)

        case "place":
            guard let item = await example() else { return }
            let placement = await state.cycleOnboardingExamplePlacement(id: item.id)
            try? await telegram.answerCallback(
                callbackQueryID: callback.id,
                text: placement.map { "📍 Показывать: \($0.shortLabel)" } ?? Texts.exampleNotFound
            )
            try await showPage(.superOnboarding, chatKey: chatKey, callback: callback, message: message)

        case "up":
            guard let item = await example() else { return }
            let moved = await state.moveOnboardingExampleUp(id: item.id)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: moved ? "↑ Выше" : "Уже первый")
            try await showPage(.superOnboarding, chatKey: chatKey, callback: callback, message: message)

        case "del":
            guard let item = await example() else { return }
            let removed = await state.removeOnboardingExample(id: item.id)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: removed ? "🗑 Удалён" : Texts.exampleNotFound)
            try await showPage(.superOnboarding, chatKey: chatKey, callback: callback, message: message)

        case "preview":
            // Renders the real buttons for the room the preview is opened in;
            // tapping one runs a real generation here (that is the point — the
            // super-admin sees exactly what users get).
            let isGroup = chatKey.chatID.isGroup
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
    func renderSuperOnboarding(chatKey: ChatKey) async -> MenuScreen {
        let config = await state.onboardingConfig()
        let report = await state.funnelReport()
        let shown = report.count(.onboardingShown)
        let tapped = report.count(.exampleTapped)
        let totalTaps = config.examples.reduce(0) { $0 + $1.taps }

        func pct(_ num: Int, _ den: Int) -> String {
            guard den > 0 else { return "—" }
            return String(format: "%.0f%%", Double(num) / Double(den) * 100)
        }

        var rows: Keyboard = [
            [menuButton(config.enabled ? "🟢 Примеры включены" : "⚪️ Примеры выключены", .onb, "toggle")],
            [menuButton(config.showInGroups ? "🟢 Показывать в группах" : "⚪️ Только в личке", .onb, "groups")],
        ]
        // Two rows per example: five buttons squeezed into one row left the
        // example's own name unreadable, which is the one thing you need to
        // see to know which row you are editing.
        // The example's id, not its row: the list is reordered and deleted
        // from this very page (see `example()`).
        for example in config.examples {
            rows.row([
                menuButton("\(example.enabled ? "🟢" : "⚪️") \(example.label)", .onb, "on", example.id),
            ])
            rows.row([
                menuButton("📍 \(example.placement.shortLabel)", .onb, "place", example.id),
                menuButton("✏️ Изменить", .onb, "edit", example.id),
                menuButton("↑ Выше", .onb, "up", example.id),
                menuButton("❌ Удалить", .onb, "del", example.id),
            ])
        }
        if config.examples.count < OnboardingConfig.maxExamples {
            rows.row([menuButton("➕ Добавить пример", .onb, "add")])
        }
        rows.row([menuButton("👁 Предпросмотр", .onb, "preview"),
                     menuButton("↺ Стандартные", .onb, "reset")])
        if totalTaps > 0 {
            rows.row([menuButton("🗑 Обнулить счётчики тапов", .onb, "clearstats")])
        }
        rows.row([backButton(to: .superAdmin)])

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
                lines.append("\(example.enabled ? "🟢" : "⚪️") <b>\(example.escapedLabel)</b> · 📍\(example.placement.shortLabel) · тапов \(example.taps)\(share)")
                lines.append("<blockquote>\(example.escapedPrompt)</blockquote>")
            }
            let inPrivate = config.activeExamples(inGroup: false).count
            let inGroups = config.activeExamples(inGroup: true).count
            lines.append("")
            lines.append("Показывается кнопок · в личке <b>\(inPrivate)</b> · в группах <b>\(config.showInGroups ? "\(inGroups)" : "0")</b>")
        }

        lines.append("")
        lines.append("<i>Тап по примеру = обычный запрос: работают лимиты, биллинг и история чата. 📍 задаёт, где кнопка видна: личка, группы или везде — в общем чате и в личке нужны разные примеры. Тексты и порядок правятся здесь, без передеплоя. Команда — /examples.</i>")

        return MenuScreen(lines.joined(separator: "\n"), rows)
    }
}
