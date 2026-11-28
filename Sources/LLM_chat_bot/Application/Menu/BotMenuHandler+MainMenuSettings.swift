extension MainMenuButton {
    var label: String {
        switch self {
        case .role: return "🎭 Роль"
        case .model: return "🤖 Модель"
        case .style: return "🌡 Стиль ответа"
        case .history: return "📝 Память"
        case .reasoning: return "🧠 Размышления / DeepThink"
        case .search: return "🌐 Поиск"
        case .listen: return "🎧 Прослушка беседы"
        case .tuning: return "⚙️ Тонкая настройка"
        case .presets: return "🎛 Пресеты"
        case .separator: return "Разделитель"
        case .examples: return "💡 Примеры-запросы"
        case .purchase: return "⚡ Купить / продлить премиум"
        case .addToGroup: return "➕ Добавить в свой чат"
        case .referral: return "🎁 Пригласить друга"
        case .help: return "❓ Справка"
        case .admin: return "⚡ Мой премиум"
        case .superAdmin: return "🛡 Супер-админ"
        case .close: return Texts.close
        }
    }
}

extension BotMenuHandler {
    func renderMainMenuAudiences() -> MenuScreen {
        var rows = MainMenuAudience.allCases.map { audience in
            [menuButton(audience.label, .mainmenu, "edit", audience)]
        }
        rows.append([backButton(to: .superAdmin)])
        return MenuScreen("<b>⚙️ Кнопки главного меню</b>\n\nВыберите, чьё меню хотите настроить.", rows)
    }

    func processMainMenuEdit(route: MenuRoute, callback: CallbackQuery, message: MaybeInaccessibleMessage) async throws {
        guard let audience = route.arg(2).flatMap(MainMenuAudience.init(rawValue:)) else {
            return try await staleTap(callback)
        }
        if route.sub != "edit" {
            guard let edit = MainMenuEdit(rawValue: route.sub), await state.editMainMenu(
                edit, button: route.arg(3).flatMap(MainMenuButton.init(rawValue:)),
                audience: audience, by: invokerKey(callback)
            ) else { return try await staleTap(callback) }
        }
        let screen = await renderMainMenuEditor(audience)
        try await editOrAnswer(callback: callback, message: message, screen: screen)
    }

    private func renderMainMenuEditor(_ audience: MainMenuAudience) async -> MenuScreen {
        let entries = await state.mainMenuEntries(for: audience)
        var rows: Keyboard = []
        for (index, entry) in entries.enumerated() {
            let id = entry.button
            var row: [InlineKeyboardButton]
            if id.isRequired(for: audience) {
                row = [menuButton("🔒 \(id.label)", command: .noop)]
            } else {
                let status = entry.visible ? "✅" : "◻️"
                let edit: MainMenuEdit = entry.visible ? .hide : .show
                row = [menuButton("\(status) \(id.label)", .mainmenu, edit, audience, id)]
            }
            if index > 0 { row.append(menuButton("↑", .mainmenu, MainMenuEdit.up, audience, id)) }
            if index < entries.count - 1 { row.append(menuButton("↓", .mainmenu, MainMenuEdit.down, audience, id)) }
            rows.row(row)
        }
        if entries != MainMenuConfig.defaults(for: audience) {
            rows.row(menuButton("↺ Восстановить по умолчанию", .mainmenu, MainMenuEdit.reset, audience))
        }
        rows.row(backButton(to: .superMainMenu))
        var text = """
        <b>⚙️ Кнопки главного меню · \(audience.label)</b>

        Нажмите на название, чтобы показать или скрыть кнопку. Стрелки ↑ ↓ меняют порядок.
        Кнопки появляются при подходящем сервисе ИИ и доступных функциях. Изменения видны при следующем открытии меню.
        """
        if audience == .superAdmin {
            text += "\n🔒 Кнопка «Супер-админ» в личке всегда доступна."
        }
        return MenuScreen(text, rows)
    }
}
