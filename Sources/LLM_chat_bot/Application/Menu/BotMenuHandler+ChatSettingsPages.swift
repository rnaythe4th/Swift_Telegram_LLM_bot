import Foundation

// The per-chat settings pages themselves: role, model, style of the answer,
// memory, AI service, reasoning. The actions behind their buttons live in
// BotMenuHandler+ChatSettings.swift.

extension BotMenuHandler {
    func renderRole(chatKey: ChatKey) async -> MenuScreen {
        let help = await state.fetchHelp(chatKey: chatKey)
        let globalPresets = await state.rolePresets(chatID: chatKey.chatID)
        let chatPresets = await state.chatPresets(category: .role, chatKey: chatKey)
        let activeRole = help.role

        var rows: Keyboard = []

        if !globalPresets.isEmpty {
            var currentRow: [InlineKeyboardButton] = []
            for (i, preset) in globalPresets.enumerated() {
                let isActive = activeRole.hasPrefix(preset.value)
                let label = (isActive ? "✓ " : "") + "🌐 \(preset.display)"
                currentRow.append(menuButton(label, .role, "gsel", "\(i)"))
                if currentRow.count == 2 { rows.row(currentRow); currentRow = [] }
            }
            if !currentRow.isEmpty { rows.row(currentRow) }
        }

        if !chatPresets.isEmpty {
            var currentRow: [InlineKeyboardButton] = []
            for (i, preset) in chatPresets.enumerated() {
                let isActive = activeRole.hasPrefix(preset.value)
                let label = (isActive ? "✓ " : "") + "💬 \(preset.display)"
                currentRow.append(menuButton(label, .role, "csel", "\(i)"))
                if currentRow.count == 2 { rows.row(currentRow); currentRow = [] }
            }
            if !currentRow.isEmpty { rows.row(currentRow) }
        }

        rows.row([menuButton("✏️ Своя роль", .role, "custom"), menuButton("↺ Стандартная", .role, "default")])
        rows.row([menuButton("⚙️ Мои заготовки", .pm, "role")])
        rows.row(navButtons())

        let text = """
        <b>🎭 Роль ассистента</b>

        Текущая:
        <blockquote expandable>\(help.role)</blockquote>

        <i>🌐 — общая для всех чатов · 💬 — только для этого</i>
        ✏️ — своя роль текстом (или /setrole &lt;текст&gt;)
        """
        return MenuScreen(text, rows)
    }

    func renderModel(chatKey: ChatKey, invoker: UserKey? = nil) async -> MenuScreen {
        let help = await state.fetchHelp(chatKey: chatKey)
        let globalPresets = await state.modelPresets(chatID: chatKey.chatID)
        let chatPresets = await state.chatPresets(category: .model, chatKey: chatKey)
        // What a free-tier chat may run: the zero-cost catalogue plus whatever
        // the super-admin put behind a 🆓 mode.
        let effectiveFreeModels = await state.allowedFreeModelIDs()
        // Group menus are one shared message, so the legend and the upsell
        // describe the chat's access, never the tapper's own (CLAUDE.md §13).
        let hasFullAccess = await state.hasFullModelAccess(
            key: chatKey.chatID < 0 ? nil : invoker,
            chatID: chatKey.chatID
        )
        let restrictionsActive = effectiveFreeModels != nil
        let modelPrices = await state.openRouterModelPrices()
        var rows: Keyboard = []

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
                currentRow.append(menuButton(label, .model, action, preset.value))
                if currentRow.count == 2 { rows.row(currentRow); currentRow = [] }
            }
            if !currentRow.isEmpty { rows.row(currentRow) }
        }

        if !globalPresets.isEmpty { appendPresets(globalPresets, action: "gsel") }
        if !chatPresets.isEmpty { appendPresets(chatPresets, action: "csel") }

        if modelPriceMonitor != nil {
            rows.row([menuButton("🆓 Бесплатные модели OpenRouter", .model, "freemodels")])
        }
        rows.row([menuButton("✏️ Ввести ID модели", .model, "custom")])
        rows.row([menuButton("⚙️ Мои заготовки", .pm, "model")])
        // Free models are genuinely poor. Someone who tried one and did not
        // like it needs one tap back to a combination that works, not a walk
        // through the settings.
        if await state.defaultMode() != nil {
            rows.row([menuButton("↺ Рабочий режим", .mode, "reset")])
        }

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
                rows.row([buyButton("⚡ Открыть умные модели", source: .model)])
            }
        }
        rows.row(navButtons())

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
        return MenuScreen(text, rows)
    }

    func renderTemp(chatKey: ChatKey) async -> MenuScreen {
        let help = await state.fetchHelp(chatKey: chatKey)
        let globalPresets = await state.tempPresets(chatID: chatKey.chatID)
        let chatPresets = await state.chatPresets(category: .temp, chatKey: chatKey)
        var rows: Keyboard = []

        if !globalPresets.isEmpty {
            var currentRow: [InlineKeyboardButton] = []
            for preset in globalPresets {
                let isActive = Float(preset.value).map { abs($0 - help.temp) < 0.001 } ?? false
                let label = (isActive ? "✓ " : "") + "🌐 \(preset.display)"
                currentRow.append(menuButton(label, .temp, "\(preset.value)"))
                if currentRow.count == 2 { rows.row(currentRow); currentRow = [] }
            }
            if !currentRow.isEmpty { rows.row(currentRow) }
        }

        if !chatPresets.isEmpty {
            var currentRow: [InlineKeyboardButton] = []
            for preset in chatPresets {
                let isActive = Float(preset.value).map { abs($0 - help.temp) < 0.001 } ?? false
                let label = (isActive ? "✓ " : "") + "💬 \(preset.display)"
                currentRow.append(menuButton(label, .temp, "\(preset.value)"))
                if currentRow.count == 2 { rows.row(currentRow); currentRow = [] }
            }
            if !currentRow.isEmpty { rows.row(currentRow) }
        }

        rows.row([menuButton("✏️ Своё значение", .temp, "custom")])
        rows.row([menuButton("⚙️ Мои заготовки", .pm, "temp")])
        rows.row(navButtons())

        let bucket = Self.tempBucket(help.temp)
        let text = """
        <b>🌡 Стиль ответа</b>

        Сейчас · <b>\(bucket)</b> (\(Self.formatTemp(help.temp)))

        <i>Насколько свободно бот отвечает: 0.0 — строго по фактам и предсказуемо, 2.0 — творчески и непредсказуемо.</i>
        ✏️ — задать своё число (или /settemp &lt;0.0–2.0&gt;)
        """
        return MenuScreen(text, rows)
    }

    func renderStats(chatKey: ChatKey, invoker: UserKey? = nil) async -> MenuScreen {
        let help = await state.fetchHelp(chatKey: chatKey)
        let testModeOn = help.testModeSuffix != nil
        let testLabel: String = {
            if let s = help.testModeSuffix {
                return "🟢 Тест-режим (добавка \(s))"
            }
            return "⚪️ Тест-режим"
        }()
        var rows: Keyboard = [
            [menuButton("\(toggleMark(help.showTokens)) Объём текста", .stats, "toggle", "tokens"),
             menuButton("\(toggleMark(help.showCost)) Стоимость", .stats, "toggle", "cost")],
            [menuButton("\(toggleMark(help.showModel)) Модель", .stats, "toggle", "model")],
        ]
        // Storage reports and the test-mode suffix are operator tools: for a
        // regular user they are two switches that explain nothing and do
        // nothing they want. They stay one tap away for whoever runs the bot.
        let isSuper = await state.isSuperAdmin(invoker)
        let isChatAdmin = await state.isAdmin(invoker, chatID: chatKey.chatID)
        let isOperator = isSuper || isChatAdmin
        if isOperator || help.backupNotify || testModeOn {
            rows.row([menuButton("\(toggleMark(help.backupNotify)) Отчёты о сохранении", .stats, "toggle", "backup")])
            rows.row([menuButton(testLabel, .stats, "toggle", "testmode")])
        }
        // Lives here rather than on the settings page: it is about the numbers
        // this page controls, and on the main page it was one more button
        // competing with the modes.
        if help.cumulativeUsage.generationCount > 0 {
            rows.row([menuButton("🗑 Сбросить статистику", .stats, "usage-reset")])
        }
        rows.row(navButtons())

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
        return MenuScreen(text, rows)
    }

    func renderHistory(chatKey: ChatKey, invoker: UserKey? = nil) async -> MenuScreen {
        let help = await state.fetchHelp(chatKey: chatKey)
        // Memory length multiplies the cost of *every* answer: each extra
        // remembered message is re-sent to the model on each turn. It is the
        // owner's lever, not a user preference — the picker is operator-only,
        // the value and "what does it remember" stay visible to everyone.
        let isOperator = await state.isAdmin(invoker, chatID: chatKey.chatID)
        let globalPresets = isOperator ? await state.historyLengthPresets(chatID: chatKey.chatID) : []
        let chatPresets = isOperator ? await state.chatPresets(category: .history, chatKey: chatKey) : []
        var rows: Keyboard = []

        if !globalPresets.isEmpty {
            var currentRow: [InlineKeyboardButton] = []
            for preset in globalPresets {
                let isActive = Int(preset.value) == help.maxHistory
                let label = (isActive ? "✓ " : "") + "🌐 \(preset.display)"
                currentRow.append(menuButton(label, .history, "length", "\(preset.value)"))
                if currentRow.count == 2 { rows.row(currentRow); currentRow = [] }
            }
            if !currentRow.isEmpty { rows.row(currentRow) }
        }

        if !chatPresets.isEmpty {
            var currentRow: [InlineKeyboardButton] = []
            for preset in chatPresets {
                let isActive = Int(preset.value) == help.maxHistory
                let label = (isActive ? "✓ " : "") + "💬 \(preset.display)"
                currentRow.append(menuButton(label, .history, "length", "\(preset.value)"))
                if currentRow.count == 2 { rows.row(currentRow); currentRow = [] }
            }
            if !currentRow.isEmpty { rows.row(currentRow) }
        }

        rows.row([
            menuButton("📜 Что бот помнит", .history, "dump"),
            menuButton("🧹 Очистить", .history, "clear"),
        ])
        if isOperator {
            rows.row([menuButton("✏️ Своё значение", .history, "custom")])
            rows.row([menuButton("⚙️ Мои заготовки", .pm, "history")])
        }
        rows.row(navButtons())

        let hint = isOperator
            ? "✏️ — задать своё число (или /historylength &lt;1–50&gt;)"
            : "<i>Длину памяти задаёт владелец бота — она влияет на стоимость каждого ответа.</i>"
        let text = """
        <b>📝 Память бота</b>

        Помнит последние · <b>\(help.maxHistory) сообщ.</b>

        <i>Сколько прошлых сообщений бот держит в голове. Чем больше — тем лучше он понимает, о чём речь, но ответ медленнее и дороже.</i>
        \(hint)
        """
        return MenuScreen(text, rows)
    }

    func renderProvider(chatKey: ChatKey) async -> MenuScreen {
        let help = await state.fetchHelp(chatKey: chatKey)
        let providers = ServiceProvider.allCases
        var rows: Keyboard = []
        var currentRow: [InlineKeyboardButton] = []
        for provider in providers {
            let label = (provider == help.provider ? "✓ " : "") + provider.rawValue
            currentRow.append(menuButton(label, .provider, "\(provider.commandValue)"))
            if currentRow.count == 2 {
                rows.row(currentRow)
                currentRow = []
            }
        }
        if !currentRow.isEmpty {
            rows.row(currentRow)
        }
        rows.row(navButtons())
        let text = """
        <b>🔌 Сервис ИИ</b>

        Сейчас · <b>\(help.provider.commandValue)</b>

        <i>Через кого бот ходит к моделям. Обычно менять не нужно — если не знаете, что выбрать, оставьте как есть.</i>

        <i>OpenRouter — тысячи моделей (GPT, Claude, Gemini, DeepSeek…)
        DeepSeek — только модели DeepSeek, напрямую
        Yandex — YandexGPT</i>
        """
        return MenuScreen(text, rows)
    }

    func renderReasoning(chatKey: ChatKey) async -> MenuScreen {
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
            return MenuScreen(text, rows)
        }

        func btn(_ value: String, label: String) -> InlineKeyboardButton {
            let mark = (current == value || (value == "off" && current == nil)) ? "✓ " : ""
            return menuButton(mark + label, .reasoning, "set", "\(value)")
        }

        let rows: Keyboard = [
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
        return MenuScreen(text, rows)
    }

    func renderHelp(chatKey: ChatKey) async -> MenuScreen {
        let rows: Keyboard = [navButtons()]
        return MenuScreen(BotCallbackHandler.faqText, rows)
    }
}
