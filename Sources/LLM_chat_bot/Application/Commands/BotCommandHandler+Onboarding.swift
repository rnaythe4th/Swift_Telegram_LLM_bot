import Foundation

// /examples: the ready-made prompts shown in the greeting.

extension BotCommandHandler {
    // MARK: - Onboarding examples (roadmap step 9)

    /// `/examples` — re-sends the ready-made prompt buttons to anyone (the
    /// greeting scrolls away fast). Super-admins get the same switches the
    /// super-menu page has, so the feature is controllable without the UI.
    func handleExamples(chatKey: ChatKey, argument: String, fromUser: TelegramUser?) async throws {
        let parts = argument.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let subcommand = (parts.first ?? "").lowercased()
        let isSuper = await isSuperAdmin(fromUser)

        if isSuper, !subcommand.isEmpty {
            var config = await state.onboardingConfig()
            switch subcommand {
            case "on", "off":
                config.enabled = subcommand == "on"
                await state.setOnboardingConfig(config)
                try await sendUserFeedback(chatKey: chatKey, text: "✓ Примеры в приветствии: <b>\(onOff(config.enabled))</b>")
                return
            case "groups":
                config.showInGroups.toggle()
                await state.setOnboardingConfig(config)
                try await sendUserFeedback(chatKey: chatKey, text: "✓ Примеры в приветствии группы: <b>\(onOff(config.showInGroups))</b>")
                return
            case "reset":
                await state.resetOnboardingExamplesToDefaults()
                try await sendUserFeedback(chatKey: chatKey, text: "✓ Стандартный набор примеров восстановлен.")
                return
            case "clearstats":
                await state.resetOnboardingTapStats()
                try await sendUserFeedback(chatKey: chatKey, text: "✓ Счётчики тапов обнулены.")
                return
            case "stats":
                let fresh = await state.onboardingConfig()
                var lines = ["<b>💡 Примеры-запросы · статистика</b>", ""]
                lines.append("Статус · <b>\(onOff(fresh.enabled))</b> · в группах · <b>\(onOff(fresh.showInGroups))</b>")
                if fresh.examples.isEmpty {
                    lines.append("<i>Список пуст.</i>")
                } else {
                    for example in fresh.examples {
                        lines.append("\(example.enabled ? "🟢" : "⚪️") \(OnboardingPresenter.escape(example.label)) · \(example.placement.shortLabel) · тапов <b>\(example.taps)</b> · <code>\(example.id)</code>")
                    }
                }
                lines.append("")
                lines.append("<i>Редактирование — /menu → 🛡 Супер-админ → 💡 Примеры-запросы</i>")
                try await sendUserFeedback(chatKey: chatKey, text: lines.joined(separator: "\n"))
                return
            default:
                try await sendUserFeedback(chatKey: chatKey, text: """
                    <b>💡 Примеры-запросы</b>

                    <code>/examples</code> — показать примеры
                    <code>/examples stats</code> — тапы и размещение по каждому примеру
                    <code>/examples on|off</code> — показывать в приветствии
                    <code>/examples groups</code> — показывать при входе в группу
                    <code>/examples reset</code> — вернуть стандартный набор
                    <code>/examples clearstats</code> — обнулить счётчики

                    Тексты, порядок и размещение (личка / группы / везде) правятся кнопками: /menu → 🛡 Супер-админ → 💡 Примеры-запросы
                    """)
                return
            }
        }

        let onboarding = await state.onboardingConfig()
        let rows = OnboardingPresenter.exampleRows(onboarding, inGroup: chatKey.chatID < 0)
        guard !rows.isEmpty else {
            try await sendUserFeedback(chatKey: chatKey, text: "Готовых примеров сейчас нет — просто напишите свой вопрос, я отвечу.")
            return
        }
        _ = try await telegram.sendMessage(.init(
            chatID: chatKey.chatID,
            threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
            replyTo: nil,
            text: OnboardingPresenter.invitation,
            replyMarkup: InlineKeyboardMarkup(inline_keyboard: rows)
        ))
        await state.bumpFunnel(.onboardingShown)
    }

    func onOff(_ v: Bool) -> String { v ? "вкл" : "выкл" }
}
