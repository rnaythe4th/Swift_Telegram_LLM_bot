import Foundation

// Reference modes: the settings bundle a user picks in one tap, and the
// super-admin page that authors the set.
//
// A user picks "🧠 Умный", not "temperature 0.7 and reasoning=medium". The ⭐
// modes stay visible to everyone on purpose — a ceiling nobody can see is a
// ceiling nobody pays to lift (GROWTH.md §1).

extension BotMenuHandler {

    // MARK: - Dispatcher

    func processModeAction(
        route: MenuRoute,
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        switch route.command {
        case .mode:
            try await handleModePick(route: route, chatKey: chatKey, callback: callback, message: message)
        case .smode:
            guard await requireSuperAdmin(callback) else { return }
            try await handleModeAdminAction(route: route, chatKey: chatKey, callback: callback, message: message)
        default:
            break
        }
    }

    // MARK: - Picking a mode

    private func handleModePick(
        route: MenuRoute,
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        switch route.sub {
        case "pick":
            guard let id = route.arg(2), let mode = await state.mode(id: id) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: Texts.modeNotFound)
                return
            }
            let isPaid = mode.tier == .premium
            var access = ChatContextStore.PaidModelAccess.full
            if isPaid {
                access = await state.paidModelAccess(
                    username: invokerKey(callback),
                    userID: callback.from.id,
                    chatID: chatKey.chatID
                )
                if case .none = access {
                    // The pain point, met while reaching for the thing: answer
                    // with the offer, not with a dead-end toast (GROWTH.md P0.4).
                    await state.bumpFunnel(.capHit)
                    try? await telegram.answerCallback(
                        callbackQueryID: callback.id,
                        text: "⭐ \(mode.title) — с премиумом или балансом"
                    )
                    try await showPage(.pay, chatKey: chatKey, callback: callback, message: message, purchaseSource: .mode)
                    return
                }
            }
            guard let applied = await state.applyMode(chatKey: chatKey, modeID: id) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: Texts.modeUnavailable)
                return
            }
            await state.noteModeTap(id: id)
            let suffix = Self.dailyTasteToastSuffix(access, isPaidModel: isPaid)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ \(applied.title)\(suffix)")
            try await showPage(.main, chatKey: chatKey, callback: callback, message: message)

        case "reset":
            // "↺ Рабочий режим": one tap back to something that answers well.
            // A chat parked on a free model after the daily cap is a chat about
            // to be abandoned, and the way out must not be five taps deep.
            guard let working = await state.defaultMode(),
                  await state.applyMode(chatKey: chatKey, modeID: working.id) != nil else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: Texts.modeUnavailable)
                return
            }
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "↺ \(working.title)")
            try await showPage(.main, chatKey: chatKey, callback: callback, message: message)

        default:
            try await showPage(.main, chatKey: chatKey, callback: callback, message: message)
        }
    }

    /// The mode buttons on the settings page, two per row, plus the way back to
    /// the working mode when the chat has drifted off it.
    func modeRows(config: ModePresetConfig, activeID: String?, hasFullAccess: Bool) -> Keyboard {
        var rows: Keyboard = []
        var current: [InlineKeyboardButton] = []
        for mode in config.activeModes {
            var label = mode.title
            if mode.id == activeID {
                label = "✓ " + label
            } else if mode.tier == .premium, !hasFullAccess {
                label += " ⭐"
            }
            current.append(menuButton(label, .mode, "pick", mode.id))
            if current.count == 2 { rows.row(current); current = [] }
        }
        if !current.isEmpty { rows.row(current) }
        return rows
    }

    // MARK: - Fine tuning (behind full access)

    /// Everything a mode sets, taken apart. The page opens for anyone; the
    /// controls that cost money carry a ⭐ and lead to the offer instead
    /// (`MenuPage.requiresFullAccess`, enforced on both the nav path and the
    /// redraw-after-input path).
    func renderTuning(chatKey: ChatKey, username: String? = nil) async -> MenuScreen {
        let help = await state.fetchHelp(chatKey: chatKey)
        let provider = await state.provider(chatKey: chatKey)
        let gateway = try? gateways.gateway(for: provider)
        let reasoningSupported = gateway?.capabilities.supportsReasoning ?? false
        let isOperator = await state.isAdmin(username: username, chatID: chatKey.chatID)
        // A fact about the chat, not about the tapper: in a group this page is
        // one shared message (CLAUDE.md §13).
        let hasFullAccess = await state.hasFullModelAccess(
            username: chatKey.chatID < 0 ? nil : username,
            chatID: chatKey.chatID
        )
        let lock = hasFullAccess ? "" : " ⭐"

        var rows: Keyboard = [
            [menuButton("🤖 Модель", page: .model), menuButton("🌡 Стиль ответа" + lock, page: .temp)],
        ]
        if reasoningSupported {
            rows.row([menuButton("🧠 Обдумывание" + lock, page: .reasoning)])
        }
        rows.row([menuButton("📊 Что показывать под ответом", page: .stats)])
        // Memory and the AI service are the owner's levers: memory multiplies
        // the cost of every answer, and the service silently decides which
        // models and which reasoning are available at all.
        if isOperator {
            rows.row([menuButton("📝 Память", page: .history), menuButton("🔌 Сервис ИИ", page: .provider)])
        } else {
            rows.row([menuButton("📜 Что бот помнит", page: .history)])
        }
        if !hasFullAccess {
            rows.row([buyButton("⚡ Открыть тонкую настройку", source: .tuning)])
        }
        rows.row(navButtons())

        let reasoningLine = reasoningSupported
            ? "\n🧠 Обдумывание · <b>\(help.reasoningEffort?.displayName ?? "выключено")</b>"
            : ""
        let footer = hasFullAccess
            ? "<i>Здесь настройки правятся по отдельности. Вернуться к проверенной связке — «↺ Рабочий режим» в настройках.</i>"
            : "<i>⭐ — правится с премиумом или балансом. Без них работают готовые режимы: связка настроек в один тап.</i>"
        let text = """
        <b>⚙️ Тонкая настройка</b>

        🤖 Модель · <code>\(help.model)</code>
        🌡 Стиль ответа · <b>\(Self.tempBucket(help.temp))</b>
        📝 Память · <b>\(help.maxHistory) сообщ.</b>\(reasoningLine)

        \(footer)
        """
        return MenuScreen(text, rows)
    }

    // MARK: - Super-admin editor

    private func handleModeAdminAction(
        route: MenuRoute,
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard !route.sub.isEmpty else {
            try await showPage(.superModes, chatKey: chatKey, callback: callback, message: message)
            return
        }
        let config = await state.modeConfig()

        /// The mode a positional action refers to; nil answers the callback.
        func mode(at index: Int) async -> ModePreset? {
            guard index >= 0, index < config.modes.count else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: Texts.modeNotFound)
                return nil
            }
            return config.modes[index]
        }

        switch route.sub {
        case "toggle":
            await state.setModesEnabled(!config.enabled)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: config.enabled ? "⚪️ Выключены" : "🟢 Включены")

        case "add":
            guard config.modes.count < ModePresetConfig.maxModes else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Максимум \(ModePresetConfig.maxModes) режимов")
                return
            }
            await state.setPending(.admin(.init(kind: .modeAdd)), menuMessageID: message.message_id, chatKey: chatKey)
            try await editOrAnswer(
                callback: callback,
                message: message,
                screen: MenuScreen(Self.modeInputPrompt(title: "➕ Новый режим", current: nil), [[cancelButton(to: .superModes)]])
            )
            return

        case "edit":
            guard let index = route.int(2), let item = await mode(at: index) else { return }
            await state.setPending(
                .admin(.init(kind: .modeEdit, payload: item.id)),
                menuMessageID: message.message_id,
                chatKey: chatKey
            )
            try await editOrAnswer(
                callback: callback,
                message: message,
                screen: MenuScreen(
                    Self.modeInputPrompt(title: "✏️ Режим · \(OnboardingPresenter.escape(item.title))", current: item),
                    [[cancelButton(to: .superModes)]]
                )
            )
            return

        case "role":
            guard let index = route.int(2), let item = await mode(at: index) else { return }
            await state.setPending(
                .admin(.init(kind: .modeRole, payload: item.id)),
                menuMessageID: message.message_id,
                chatKey: chatKey
            )
            let currentRole = item.role.map { "<blockquote expandable>\(OnboardingPresenter.escape($0))</blockquote>" }
                ?? "<i>не задана — режим не трогает роль чата</i>"
            let prompt = """
            <b>🎭 Роль режима · \(OnboardingPresenter.escape(item.title))</b>

            Сейчас:
            \(currentRole)

            Отправьте текст роли одним сообщением, или <code>-</code>, чтобы режим не менял роль чата.
            """
            try await editOrAnswer(callback: callback, message: message, screen: MenuScreen(prompt, [[cancelButton(to: .superModes)]]))
            return

        case "on":
            guard let index = route.int(2), let item = await mode(at: index) else { return }
            await state.toggleModeEnabled(id: item.id)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: item.enabled ? "⚪️ Скрыт" : "🟢 Показывается")

        case "tier":
            guard let index = route.int(2), let item = await mode(at: index) else { return }
            await state.cycleModeTier(id: item.id)
            let now = item.tier.next
            try? await telegram.answerCallback(
                callbackQueryID: callback.id,
                text: now == .free ? "🆓 Доступен всем" : "⭐ Только с премиумом"
            )

        case "work":
            guard let index = route.int(2), let item = await mode(at: index) else { return }
            await state.setDefaultMode(id: item.id)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🎯 Рабочий режим · \(item.title)")

        case "up":
            guard let index = route.int(2), let item = await mode(at: index) else { return }
            await state.moveModeUp(id: item.id)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: index == 0 ? "Уже первый" : "↑ Выше")

        case "del":
            guard let index = route.int(2), let item = await mode(at: index) else { return }
            let removed = await state.removeMode(id: item.id)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: removed ? "🗑 Удалён" : Texts.modeNotFound)

        case "reset":
            await state.resetModes()
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "↺ Стандартный набор")

        case "clearstats":
            await state.clearModeTaps()
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🗑 Счётчики обнулены")

        default:
            break
        }
        try await showPage(.superModes, chatKey: chatKey, callback: callback, message: message)
    }

    /// One prompt for both add and edit: the format is the thing being taught,
    /// so it must not drift between the two.
    static func modeInputPrompt(title: String, current: ModePreset?) -> String {
        let example = current.map(Self.modeInputLine) ?? "🧠 Умный | разбирается в сложном | google/gemini-3-flash-preview | 0.7 | 20 | средне"
        let tapsNote = current.map { "\n<i>Тариф, роль и счётчик тапов (\($0.taps)) сохранятся.</i>" } ?? ""
        return """
        <b>\(title)</b>

        Отправьте одним сообщением:
        <code>Название | Подпись | модель | стиль | память | обдумывание</code>

        <i>Сейчас/пример:</i>
        <code>\(OnboardingPresenter.escape(example))</code>

        <i>модель — ID с openrouter.ai, или <code>-</code> = любая бесплатная (для 🆓-режима).
        Через конкретный сервис: <code>deepseek/deepseek-v4-pro@deepseek</code>
        стиль — 0.0–2.0 · память — 1–50 · обдумывание — <code>-</code>, быстро, средне, глубоко</i>\(tapsNote)
        """
    }

    /// The mode rendered back into the input format, so "edit" starts from what
    /// is actually stored rather than from a generic example.
    static func modeInputLine(_ mode: ModePreset) -> String {
        let model = mode.model.map { id in
            mode.modelProviderRouting.map { "\(id)@\($0)" } ?? id
        } ?? "-"
        return [
            mode.title,
            mode.subtitle,
            model,
            Self.formatTemp(mode.temp),
            String(mode.maxHistory),
            mode.reasoning?.displayName ?? "-",
        ].joined(separator: " | ")
    }

    /// Reference modes: what the free tier may run, what premium unlocks, and
    /// which of them people actually pick.
    func renderSuperModes(chatKey: ChatKey) async -> MenuScreen {
        let config = await state.modeConfig()
        let prices = await state.openRouterModelPrices()
        let multiplier = await state.priceMultiplier()
        let fallback = await state.fallbackFreeModel()
        let totalTaps = config.modes.reduce(0) { $0 + $1.taps }

        var rows: Keyboard = [
            [menuButton(config.enabled ? "🟢 Режимы включены" : "⚪️ Режимы выключены", .smode, "toggle")],
        ]
        for (index, mode) in config.modes.enumerated() {
            let isWorking = config.defaultModeID == mode.id
            rows.row([
                menuButton("\(mode.enabled ? "🟢" : "⚪️") \(mode.title)\(isWorking ? " · 🎯" : "")", .smode, "on", "\(index)"),
            ])
            rows.row([
                menuButton(mode.tier.badge, .smode, "tier", "\(index)"),
                menuButton("✏️", .smode, "edit", "\(index)"),
                menuButton("🎭", .smode, "role", "\(index)"),
                menuButton("🎯", .smode, "work", "\(index)"),
                menuButton("↑", .smode, "up", "\(index)"),
                menuButton("❌", .smode, "del", "\(index)"),
            ])
        }
        if config.modes.count < ModePresetConfig.maxModes {
            rows.row([menuButton("➕ Добавить режим", .smode, "add")])
        }
        rows.row([menuButton("↺ Стандартные", .smode, "reset")])
        if totalTaps > 0 {
            rows.row([menuButton("🗑 Обнулить счётчики", .smode, "clearstats")])
        }
        rows.row([backButton(to: .superAdmin)])

        func pct(_ num: Int, _ den: Int) -> String {
            guard den > 0 else { return "—" }
            return String(format: "%.0f%%", Double(num) / Double(den) * 100)
        }

        var lines: [String] = [
            "<b>🎛 Режимы бота</b>",
            "",
            "Статус · <b>\(config.enabled ? "включены" : "выключены")</b>",
            "Бесплатный фолбэк · <code>\(fallback ?? "нет")</code>",
            "",
        ]

        if config.modes.isEmpty {
            lines.append("<i>Список пуст — пользователь увидит обычные кнопки настроек.</i>")
        } else {
            for mode in config.modes {
                let share = totalTaps > 0 ? " · \(pct(mode.taps, totalTaps))" : ""
                let working = config.defaultModeID == mode.id ? " · 🎯 рабочий" : ""
                lines.append("\(mode.enabled ? "🟢" : "⚪️") \(mode.tier.badge) <b>\(OnboardingPresenter.escape(mode.title))</b>\(working) · тапов \(mode.taps)\(share)")
                let modelID = mode.model ?? fallback
                var detail = "<code>\(OnboardingPresenter.escape(modelID ?? "нет бесплатной"))</code>"
                if mode.model == nil { detail += " <i>(авто)</i>" }
                detail += " · 🌡 \(Self.formatTemp(mode.temp)) · 📝 \(mode.maxHistory)"
                if let reasoning = mode.reasoning { detail += " · 🧠 \(reasoning.displayName)" }
                lines.append(detail)
                // The price of a 🆓 mode is the owner's own bill: it has to be
                // on screen before they put a paid model behind it.
                if let modelID, let price = prices[modelID] {
                    let inP = Self.formatPriceM(price.inputPerToken * multiplier)
                    let outP = Self.formatPriceM(price.outputPerToken * multiplier)
                    lines.append("<i>⬇️$\(inP)/M · ⬆️$\(outP)/M</i>")
                }
                if let role = mode.role {
                    lines.append("<blockquote expandable>🎭 \(OnboardingPresenter.escape(role))</blockquote>")
                }
            }
        }

        lines.append("")
        lines.append("<i>🆓 — режим доступен всем, включая бесплатных: его модель автоматически разрешена без подписки. ⭐ — только с премиумом, балансом или на дневную порцию. 🎯 — рабочий режим: к нему возвращают «↺ Рабочий режим» и сброс настроек.</i>")

        return MenuScreen(lines.joined(separator: "\n"), rows)
    }
}
