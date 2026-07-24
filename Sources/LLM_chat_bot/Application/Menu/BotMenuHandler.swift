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
    case pay
    case adminPanel = "admin"
    case adminHelp = "adminhelp"
    case adminChats = "adminchats"
    case adminUsers = "adminusers"
    case adminWhitelist = "adminwl"
    case adminDefaults = "admindef"
    case superAdmin = "superadmin"
    case superAdminHelp = "superadminhelp"
    case superStars = "superstars"
    case superCrypto = "supercrypto"
    case superCard = "supercard"
    case superFreeModels = "superfreemodels"
    case superTenants = "supertenants"
    case superAdmins = "superadmins"
    case superSimulate = "supersim"
    case superChats = "superchats"
    case superAds = "superads"
    case superBalances = "superbal"
    case superFunnel = "superfunnel"
    case adminInvite = "admininvite"
    case close
}

final class BotMenuHandler: @unchecked Sendable {
    private let telegram: TelegramGatewayPort
    private let state: ChatContextStore
    private let gateways: ProviderGatewayRegistry
    private let logger: LoggerPort
    private let formatOptions: String
    private let botUsername: String
    private let modelPriceMonitor: ModelPriceMonitor?
    private let cryptoService: CryptoPaymentService?

    init(
        telegram: TelegramGatewayPort,
        state: ChatContextStore,
        gateways: ProviderGatewayRegistry,
        logger: LoggerPort,
        formatOptions: String,
        botUsername: String = "",
        modelPriceMonitor: ModelPriceMonitor? = nil,
        cryptoService: CryptoPaymentService? = nil
    ) {
        self.telegram = telegram
        self.state = state
        self.gateways = gateways
        self.logger = logger
        self.formatOptions = formatOptions
        self.botUsername = botUsername
        self.modelPriceMonitor = modelPriceMonitor
        self.cryptoService = cryptoService
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
                let (menuText, markup) = await renderSuperStars(chatKey: chatKey)
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

        if await state.hasPendingStarsPerUsdInput(chatKey: chatKey) {
            guard let menuMessageID = await state.consumePendingStarsPerUsdInput(chatKey: chatKey) else { return true }
            guard await state.isSuperAdmin(username: username) else {
                _ = try? await telegram.sendMessage(.init(
                    chatID: chatKey.chatID,
                    threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                    replyTo: nil,
                    text: "🔒 Только суперадмин может изменить курс.",
                    replyMarkup: nil
                ))
                return true
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = Int(trimmed), value >= 1 {
                await state.setStarsPerUsd(value)
                let (menuText, markup) = await renderSuperStars(chatKey: chatKey)
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
                    text: "✓ Курс кредитов: <b>\(value) ⭐ за $1</b>",
                    replyMarkup: nil
                ))
            } else {
                await state.setPendingStarsPerUsdInput(menuMessageID: menuMessageID, chatKey: chatKey)
                _ = try? await telegram.sendMessage(.init(
                    chatID: chatKey.chatID,
                    threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                    replyTo: nil,
                    text: "⚠️ Введите целое число ≥ 1 (например <code>77</code>).",
                    replyMarkup: nil
                ))
            }
            return true
        }

        if await state.hasPendingCryptoPriceInput(chatKey: chatKey) {
            guard let menuMessageID = await state.consumePendingCryptoPriceInput(chatKey: chatKey) else { return true }
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
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
            if trimmed == "0" || trimmed.lowercased() == "off" {
                await state.setCryptoPriceUsdCents(nil)
                let confirm = "✓ Крипто-оплата отключена."
                let (menuText, markup) = await renderSuperCrypto(chatKey: chatKey)
                try? await telegram.editMessage(.init(chatID: chatKey.chatID, messageID: menuMessageID, text: menuText, replyMarkup: markup))
                _ = try? await telegram.sendMessage(.init(
                    chatID: chatKey.chatID,
                    threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                    replyTo: nil,
                    text: confirm,
                    replyMarkup: nil
                ))
            } else if let usd = Double(trimmed), usd > 0 {
                let cents = Int((usd * 100.0).rounded())
                await state.setCryptoPriceUsdCents(cents)
                let confirm = String(format: "✓ Цена в крипто: <b>$%.2f</b>", Double(cents) / 100.0)
                let (menuText, markup) = await renderSuperCrypto(chatKey: chatKey)
                try? await telegram.editMessage(.init(chatID: chatKey.chatID, messageID: menuMessageID, text: menuText, replyMarkup: markup))
                _ = try? await telegram.sendMessage(.init(
                    chatID: chatKey.chatID,
                    threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                    replyTo: nil,
                    text: confirm,
                    replyMarkup: nil
                ))
            } else {
                await state.setPendingCryptoPriceInput(menuMessageID: menuMessageID, chatKey: chatKey)
                _ = try? await telegram.sendMessage(.init(
                    chatID: chatKey.chatID,
                    threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                    replyTo: nil,
                    text: "⚠️ Введите сумму в долларах (например <code>9.99</code>) или <code>0</code>.",
                    replyMarkup: nil
                ))
            }
            return true
        }

        if await state.hasPendingCryptoPoolAddInput(chatKey: chatKey) {
            guard let pending = await state.consumePendingCryptoPoolAddInput(chatKey: chatKey) else { return true }
            guard await state.isSuperAdmin(username: username) else { return true }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let toast: String
            if trimmed.isEmpty {
                toast = "⚠️ Адрес пустой."
            } else {
                let added = await state.addCryptoPoolAddress(pending.chain, address: trimmed)
                toast = added
                    ? "✓ В пул \(pending.chain.displayName) добавлен: \(trimmed)"
                    : "Адрес уже в пуле: \(trimmed)"
            }
            let (menuText, markup) = await renderSuperCrypto(chatKey: chatKey)
            try? await telegram.editMessage(.init(chatID: chatKey.chatID, messageID: pending.menuMessageID, text: menuText, replyMarkup: markup))
            _ = try? await telegram.sendMessage(.init(
                chatID: chatKey.chatID,
                threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                replyTo: nil,
                text: toast,
                replyMarkup: nil
            ))
            return true
        }

        if await state.hasPendingCryptoAddressInput(chatKey: chatKey) {
            guard let pending = await state.consumePendingCryptoAddressInput(chatKey: chatKey) else { return true }
            guard await state.isSuperAdmin(username: username) else { return true }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "-" || trimmed.isEmpty {
                await state.setCryptoAddress(pending.chain, address: nil)
            } else {
                await state.setCryptoAddress(pending.chain, address: trimmed)
            }
            let (menuText, markup) = await renderSuperCrypto(chatKey: chatKey)
            try? await telegram.editMessage(.init(chatID: chatKey.chatID, messageID: pending.menuMessageID, text: menuText, replyMarkup: markup))
            _ = try? await telegram.sendMessage(.init(
                chatID: chatKey.chatID,
                threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                replyTo: nil,
                text: trimmed == "-" || trimmed.isEmpty
                    ? "✓ Адрес для \(pending.chain.displayName) удалён."
                    : "✓ Адрес для \(pending.chain.displayName): <code>\(trimmed)</code>",
                replyMarkup: nil
            ))
            return true
        }

        if await state.hasPendingFreeModelInput(chatKey: chatKey) {
            guard let menuMessageID = await state.consumePendingFreeModelInput(chatKey: chatKey) else { return true }
            guard await state.isSuperAdmin(username: username) else { return true }
            let modelID = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !modelID.isEmpty {
                let added = await state.addFreeModel(modelID)
                let toast = added ? "✓ Добавлено: \(modelID)" : "Уже в списке: \(modelID)"
                let (menuText, markup) = await renderSuperFreeModels(chatKey: chatKey)
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

        if await state.hasAdminPendingInput(chatKey: chatKey) {
            return await processAdminPendingInput(text: text, chatKey: chatKey, username: username)
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

        // Model presets accept a third part: OpenRouter upstream provider pin.
        let maxParts = pending.category == .model ? 2 : 1
        let components = text.split(separator: "|", maxSplits: maxParts).map { $0.trimmingCharacters(in: .whitespaces) }
        guard (2...(maxParts + 1)).contains(components.count), components.allSatisfy({ !$0.isEmpty }) else {
            await state.setPendingInput(pending, chatKey: chatKey)
            let format = pending.category == .model
                ? "<code>Название | Значение | Провайдер</code> (провайдер опционален)"
                : "<code>Название | Значение</code>"
            _ = try? await telegram.sendMessage(
                .init(
                    chatID: chatKey.chatID,
                    threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                    replyTo: nil,
                    text: "⚠️ Неверный формат. Используйте: \(format)",
                    replyMarkup: nil
                )
            )
            return true
        }

        let display = components[0]
        let value = components[1]
        let provider = components.count > 2 ? components[2] : nil
        let toastText: String
        let providerSuffix = provider.map { " · \($0)" } ?? ""

        if pending.category == .model {
            await modelPriceMonitor?.refreshPricesIfNeeded(for: value)
        }

        switch (pending.scope, pending.kind) {
        case (.global, .add):
            _ = await state.addPreset(category: pending.category, display: display, value: value, provider: provider, chatID: chatKey.chatID)
            toastText = "✓ Глобальный пресет добавлен: \(display)\(providerSuffix)"
        case (.global, .edit(let index)):
            let ok = await state.editPreset(category: pending.category, index: index, display: display, value: value, provider: provider, chatID: chatKey.chatID)
            toastText = ok ? "✓ Обновлён: \(display)\(providerSuffix)" : "⚠️ Пресет не найден"
        case (.chat, .add):
            _ = await state.addChatPreset(category: pending.category, chatKey: chatKey, display: display, value: value, provider: provider)
            toastText = "✓ Пресет чата добавлен: \(display)\(providerSuffix)"
        case (.chat, .edit(let index)):
            let ok = await state.editChatPreset(category: pending.category, chatKey: chatKey, index: index, display: display, value: value, provider: provider)
            toastText = ok ? "✓ Обновлён: \(display)\(providerSuffix)" : "⚠️ Пресет не найден"
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

    func sendCryptoAssetChoice(chatKey: ChatKey) async {
        guard let service = cryptoService else {
            _ = try? await telegram.sendMessage(.init(
                chatID: chatKey.chatID,
                threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                replyTo: nil,
                text: "ℹ️ Крипто-оплата не настроена.",
                replyMarkup: nil
            ))
            return
        }
        let assets = await service.availableAssets()
        guard !assets.isEmpty else {
            _ = try? await telegram.sendMessage(.init(
                chatID: chatKey.chatID,
                threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                replyTo: nil,
                text: "ℹ️ Адреса для приёма крипто-оплаты не настроены.",
                replyMarkup: nil
            ))
            return
        }
        var rows: [[InlineKeyboardButton]] = []
        for asset in assets {
            rows.append([menuButton(asset.displayLabel, action: "buy:asset:\(asset.rawValue)")])
        }
        rows.append([menuButton("✕ Отмена", action: "close")])

        let cents = await state.cryptoPriceUsdCents() ?? 0
        let usd = String(format: "%.2f", Double(cents) / 100.0)
        let text = """
        <b>🪙 Оплата криптой</b>

        Сумма к оплате: <b>$\(usd)</b>

        Выберите валюту/сеть:
        """
        _ = try? await telegram.sendMessage(.init(
            chatID: chatKey.chatID,
            threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
            replyTo: nil,
            text: text,
            replyMarkup: InlineKeyboardMarkup(inline_keyboard: rows)
        ))
    }

    private func clearAllPendingInputs(chatKey: ChatKey) async {
        await state.clearPendingInput(chatKey: chatKey)
        await state.clearPendingStarsPriceInput(chatKey: chatKey)
        await state.clearPendingStarsPerUsdInput(chatKey: chatKey)
        await state.clearPendingFreeModelInput(chatKey: chatKey)
        await state.clearPendingCryptoPriceInput(chatKey: chatKey)
        await state.clearPendingCryptoAddressInput(chatKey: chatKey)
        await state.clearPendingCryptoPoolAddInput(chatKey: chatKey)
        await state.clearAdminPendingInput(chatKey: chatKey)
    }

    func sendMenu(chatKey: ChatKey, username: String? = nil) async {
        await clearAllPendingInputs(chatKey: chatKey)
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
            await clearAllPendingInputs(chatKey: chatKey)
            try await showPage(.main, chatKey: chatKey, callback: callback, message: message)

        case "close":
            await clearAllPendingInputs(chatKey: chatKey)
            try await closeMenu(callback: callback, message: message)

        case "nav":
            // Navigating away abandons any text-input prompt (incl. the
            // "❌ Отмена" buttons, which all point at nav:*).
            await clearAllPendingInputs(chatKey: chatKey)
            guard parts.count >= 2 else {
                try await showPage(.main, chatKey: chatKey, callback: callback, message: message)
                return
            }
            let page = parts[1].lowercased()
            guard let menuPage = MenuPage(rawValue: page) else {
                try await showPage(.main, chatKey: chatKey, callback: callback, message: message)
                return
            }
            switch menuPage {
            case .superAdmin, .superAdminHelp, .superStars, .superCrypto, .superCard, .superFreeModels, .superTenants, .superAdmins, .superSimulate, .superChats, .superAds, .superBalances, .superFunnel:
                guard await state.isSuperAdmin(username: callback.from.username) else {
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
                    return
                }
            case .adminPanel, .adminHelp, .adminChats, .adminUsers, .adminWhitelist, .adminDefaults, .adminInvite:
                guard await state.isAdmin(username: callback.from.username, chatID: chatKey.chatID) else {
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только администратор")
                    return
                }
            default:
                break
            }
            try await showPage(menuPage, chatKey: chatKey, callback: callback, message: message)

        case "role":
            guard parts.count >= 2 else { return }
            if parts[1] == "custom" {
                await state.setAdminPendingInput(.init(kind: .chatCustomRole, menuMessageID: message.message_id, payload: nil), chatKey: chatKey)
                let prompt = """
                <b>🎭 Своя роль</b>

                Отправьте текст роли одним сообщением.
                <i>Пример:</i> <code>Ты — эксперт по математике, отвечай кратко.</code>

                ⚠️ История чата будет очищена.
                """
                let markup = InlineKeyboardMarkup(inline_keyboard: [[menuButton("❌ Отмена", action: "nav:role")]])
                try await editOrAnswer(callback: callback, message: message, text: prompt, markup: markup)
                return
            } else if parts[1] == "default" {
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
            if parts[1] == "custom" {
                await state.setAdminPendingInput(.init(kind: .chatCustomModel, menuMessageID: message.message_id, payload: nil), chatKey: chatKey)
                let prompt = """
                <b>🤖 Своя модель</b>

                Отправьте ID модели одним сообщением:
                <code>openai/gpt-4o</code>

                С провайдером (роутинг OpenRouter):
                <code>deepseek/deepseek-v4-pro | deepseek</code>

                <i>ID моделей — на openrouter.ai. Смена модели очистит историю.</i>
                """
                let markup = InlineKeyboardMarkup(inline_keyboard: [[menuButton("❌ Отмена", action: "nav:model")]])
                try await editOrAnswer(callback: callback, message: message, text: prompt, markup: markup)
                return
            }
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
                try await showPage(.superFreeModels, chatKey: chatKey, callback: callback, message: message)
                return
            } else if parts[1] == "unmarkfree" {
                guard await state.isSuperAdmin(username: callback.from.username) else {
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
                    return
                }
                await state.removeFreeModel(modelValue)
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Убрано из бесплатных")
                try await showPage(.superFreeModels, chatKey: chatKey, callback: callback, message: message)
                return
            } else if parts[1] == "select" || parts[1] == "gsel" {
                let presets = await state.modelPresets(chatID: chatKey.chatID)
                guard let preset = presets.first(where: { $0.value == modelValue }) else {
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Модель не найдена")
                    return
                }
                let effectiveFree = await state.effectiveFreeModelIDs()
                let hasAccess = await state.hasFullModelAccess(username: callback.from.username, userID: callback.from.id, chatID: chatKey.chatID)
                if !hasAccess, let eff = effectiveFree, !eff.contains(modelValue) {
                    let price = await state.starsPrice()
                    let hint = price.map { " (\($0) ⭐ /buy)" } ?? ""
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "⭐ Эта модель требует полного доступа\(hint)")
                    return
                }
                _ = await state.setModelAndResetHistory(chatKey: chatKey, newModel: modelValue, providerRouting: preset.provider)
                let toast = "Модель: \(preset.display)" + (preset.provider.map { " · \($0)" } ?? "")
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: toast)
                try await showPage(.model, chatKey: chatKey, callback: callback, message: message)
                return
            } else if parts[1] == "csel" {
                let chatPresets = await state.chatPresets(category: .model, chatKey: chatKey)
                guard let preset = chatPresets.first(where: { $0.value == modelValue }) else {
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Модель не найдена")
                    return
                }
                let effectiveFree = await state.effectiveFreeModelIDs()
                let hasAccess = await state.hasFullModelAccess(username: callback.from.username, userID: callback.from.id, chatID: chatKey.chatID)
                if !hasAccess, let eff = effectiveFree, !eff.contains(modelValue) {
                    let price = await state.starsPrice()
                    let hint = price.map { " (\($0) ⭐ /buy)" } ?? ""
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "⭐ Эта модель требует полного доступа\(hint)")
                    return
                }
                _ = await state.setModelAndResetHistory(chatKey: chatKey, newModel: modelValue, providerRouting: preset.provider)
                let toast = "Модель: \(preset.display)" + (preset.provider.map { " · \($0)" } ?? "")
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: toast)
                try await showPage(.model, chatKey: chatKey, callback: callback, message: message)
                return
            }

        case "temp":
            guard parts.count >= 2 else { return }
            if parts[1] == "custom" {
                await state.setAdminPendingInput(.init(kind: .chatCustomTemp, menuMessageID: message.message_id, payload: nil), chatKey: chatKey)
                let prompt = """
                <b>🌡 Своя температура</b>

                Отправьте число от <code>0.0</code> до <code>2.0</code> одним сообщением.
                <i>0.0 — точно и предсказуемо · 2.0 — креативно и хаотично</i>
                """
                let markup = InlineKeyboardMarkup(inline_keyboard: [[menuButton("❌ Отмена", action: "nav:temp")]])
                try await editOrAnswer(callback: callback, message: message, text: prompt, markup: markup)
                return
            }
            guard let temp = Float(parts[1]), (0.0...2.0).contains(temp) else { return }
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
            case "testmode":
                let suffix = await state.toggleTestMode(chatKey: chatKey)
                if let suffix {
                    toastText = "🧪 Тест-режим: суффикс \(suffix)"
                } else {
                    toastText = "🧪 Тест-режим выключен"
                }
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
            } else if parts[1] == "dump" {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: nil)
                await sendHistoryDump(chatKey: chatKey)
                return
            } else if parts[1] == "custom" {
                await state.setAdminPendingInput(.init(kind: .chatCustomHistory, menuMessageID: message.message_id, payload: nil), chatKey: chatKey)
                let prompt = """
                <b>📝 Своя длина истории</b>

                Отправьте число от <code>1</code> до <code>50</code> одним сообщением — сколько последних сообщений бот держит в памяти.
                """
                let markup = InlineKeyboardMarkup(inline_keyboard: [[menuButton("❌ Отмена", action: "nav:history")]])
                try await editOrAnswer(callback: callback, message: message, text: prompt, markup: markup)
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
            await clearAllPendingInputs(chatKey: chatKey)
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
                        [menuButton("❌ Отмена", action: "nav:superfreemodels")]
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
                    try await showPage(.superFreeModels, chatKey: chatKey, callback: callback, message: message)
                default:
                    try await showPage(.superFreeModels, chatKey: chatKey, callback: callback, message: message)
                }
            } else {
                try await showPage(.superFreeModels, chatKey: chatKey, callback: callback, message: message)
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
                        [menuButton("❌ Отмена", action: "nav:superstars")]
                    ])
                    try await editOrAnswer(callback: callback, message: message, text: promptText, markup: markup)
                case "setrate":
                    await state.setPendingStarsPerUsdInput(menuMessageID: message.message_id, chatKey: chatKey)
                    let currentRate = await state.starsPerUsd()
                    let promptText = """
                    <b>💫 Курс кредитов — Stars за $1</b>

                    Текущий: <b>\(currentRate) ⭐ за $1</b>

                    Введите целое число ≥ 1. Ориентир <b>77</b>: Telegram платит разработчику ~$0.013/⭐, \
                    поэтому 77⭐/$ покрывает себестоимость ответа и оставляет маржу (30% сверху берётся при списании). \
                    Меньше — дешевле для покупателя, но режет маржу.
                    """
                    let markup = InlineKeyboardMarkup(inline_keyboard: [
                        [menuButton("❌ Отмена", action: "nav:superstars")]
                    ])
                    try await editOrAnswer(callback: callback, message: message, text: promptText, markup: markup)
                case "disable":
                    await state.setStarsPrice(nil)
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Продажи отключены")
                    try await showPage(.superStars, chatKey: chatKey, callback: callback, message: message)
                default:
                    try await showPage(.superStars, chatKey: chatKey, callback: callback, message: message)
                }
            } else {
                try await showPage(.superStars, chatKey: chatKey, callback: callback, message: message)
            }
            return

        case "noop":
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: nil)
            return

        case "tenant":
            try await handleTenantAction(parts: parts, chatKey: chatKey, callback: callback, message: message)
            return

        case "wl":
            guard await state.isAdmin(username: callback.from.username, chatID: chatKey.chatID) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только администратор")
                return
            }
            guard parts.count >= 2 else { return }
            switch parts[1] {
            case "add":
                await state.setAdminPendingInput(.init(kind: .whitelistAdd, menuMessageID: message.message_id, payload: nil), chatKey: chatKey)
                let promptText = """
                <b>👤 Добавить в whitelist</b>

                Отправьте Telegram user ID одним сообщением (целое число).
                """
                let markup = InlineKeyboardMarkup(inline_keyboard: [[menuButton("❌ Отмена", action: "nav:adminwl")]])
                try await editOrAnswer(callback: callback, message: message, text: promptText, markup: markup)
            case "remove":
                guard parts.count >= 3, let id = Int(parts[2]) else { return }
                await state.removeFromWhitelist(userID: id, chatID: chatKey.chatID)
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Убрано")
                try await showPage(.adminWhitelist, chatKey: chatKey, callback: callback, message: message)
            default:
                try await showPage(.adminWhitelist, chatKey: chatKey, callback: callback, message: message)
            }
            return

        case "def":
            guard await state.isAdmin(username: callback.from.username, chatID: chatKey.chatID) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только администратор")
                return
            }
            guard parts.count >= 2 else { return }
            let defs = await state.getDefaults(chatID: chatKey.chatID)
            let kind: AdminPendingInputKind
            let prompt: String
            switch parts[1] {
            case "model":
                kind = .defaultsModel
                prompt = "<b>⚙️ Модель по умолчанию</b>\n\nТекущая: <code>\(defs.model)</code>\n\nОтправьте ID модели одним сообщением."
            case "hist":
                kind = .defaultsHistory
                prompt = "<b>⚙️ Длина истории по умолчанию</b>\n\nТекущая: <b>\(defs.historyLength)</b>\n\nОтправьте число от 1 до 50."
            case "role":
                kind = .defaultsRole
                prompt = "<b>⚙️ Роль по умолчанию</b>\n\nТекущая:\n<blockquote expandable>\(defs.role)</blockquote>\n\nОтправьте новый текст роли одним сообщением."
            default:
                return
            }
            await state.setAdminPendingInput(.init(kind: kind, menuMessageID: message.message_id, payload: nil), chatKey: chatKey)
            let markup = InlineKeyboardMarkup(inline_keyboard: [[menuButton("❌ Отмена", action: "nav:admindef")]])
            try await editOrAnswer(callback: callback, message: message, text: prompt, markup: markup)
            return

        case "sa":
            guard await state.isSuperAdmin(username: callback.from.username) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
                return
            }
            guard parts.count >= 2 else { return }
            switch parts[1] {
            case "add":
                guard await state.isRootSuperAdmin(username: callback.from.username) else {
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только главный суперадмин")
                    return
                }
                await state.setAdminPendingInput(.init(kind: .superAdminAdd, menuMessageID: message.message_id, payload: nil), chatKey: chatKey)
                let prompt = "<b>🛡 Добавить суперадмина</b>\n\nОтправьте @username одним сообщением."
                let markup = InlineKeyboardMarkup(inline_keyboard: [[menuButton("❌ Отмена", action: "nav:superadmins")]])
                try await editOrAnswer(callback: callback, message: message, text: prompt, markup: markup)
            case "rm":
                guard await state.isRootSuperAdmin(username: callback.from.username) else {
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только главный суперадмин")
                    return
                }
                guard parts.count >= 3 else { return }
                let target = parts[2]
                let ok = await state.removeSuperAdmin(target: target)
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: ok ? "✓ Удалён" : "Не удалось")
                try await showPage(.superAdmins, chatKey: chatKey, callback: callback, message: message)
            default:
                try await showPage(.superAdmins, chatKey: chatKey, callback: callback, message: message)
            }
            return

        case "stenant":
            guard await state.isSuperAdmin(username: callback.from.username) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
                return
            }
            guard parts.count >= 2 else { return }
            switch parts[1] {
            case "add":
                await state.setAdminPendingInput(.init(kind: .tenantRegister, menuMessageID: message.message_id, payload: nil), chatKey: chatKey)
                let prompt = "<b>🏢 Зарегистрировать tenant</b>\n\nОтправьте @username одним сообщением."
                let markup = InlineKeyboardMarkup(inline_keyboard: [[menuButton("❌ Отмена", action: "nav:supertenants")]])
                try await editOrAnswer(callback: callback, message: message, text: prompt, markup: markup)
            case "rm":
                guard parts.count >= 3 else { return }
                let target = parts[2]
                let removed = await state.removeTenant(username: target)
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: removed ? "✓ Удалён" : "Нельзя")
                try await showPage(.superTenants, chatKey: chatKey, callback: callback, message: message)
            case "info":
                guard parts.count >= 3 else { return }
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: nil)
                let (text, markup) = await renderSuperTenantInfo(username: parts[2])
                try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)
            case "ext":
                guard parts.count >= 3 else { return }
                if let until = await state.extendTenantSubscription(username: parts[2], days: ChatContextStore.subscriptionDays) {
                    let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy"
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Продлена до \(f.string(from: until))")
                } else {
                    try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Tenant не найден")
                }
                let (text, markup) = await renderSuperTenantInfo(username: parts[2])
                try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)
            case "unlim":
                guard parts.count >= 3 else { return }
                let ok = await state.setTenantUnlimited(username: parts[2])
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: ok ? "✓ Подписка бессрочная" : "Tenant не найден")
                let (text, markup) = await renderSuperTenantInfo(username: parts[2])
                try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)
            case "exp":
                guard parts.count >= 3 else { return }
                let ok = await state.expireTenantSubscription(username: parts[2])
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: ok ? "⛔ Подписка завершена" : "Tenant не найден")
                let (text, markup) = await renderSuperTenantInfo(username: parts[2])
                try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)
            default:
                try await showPage(.superTenants, chatKey: chatKey, callback: callback, message: message)
            }
            return

        case "sim":
            guard await state.isActuallySuperAdmin(username: callback.from.username) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
                return
            }
            guard parts.count >= 2, let username = callback.from.username else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Нужен @username")
                return
            }
            switch parts[1] {
            case "admin":
                _ = await state.setSimulatedRole(username: username, role: .admin)
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Симуляция: админ")
            case "user":
                _ = await state.setSimulatedRole(username: username, role: .regularUser)
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Симуляция: юзер")
            case "off":
                _ = await state.setSimulatedRole(username: username, role: nil)
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Симуляция выкл")
            case "buy":
                let activation = await state.activatePaidSubscription(username: username)
                await state.assignChat(chatID: chatKey.chatID, to: username.lowercased())
                let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy"
                let note: String
                switch activation {
                case .started(let until): note = "🧪 Tenant создан, подписка до \(f.string(from: until))"
                case .extended(let until): note = "🧪 Подписка продлена до \(f.string(from: until))"
                case .alreadyUnlimited: note = "🧪 У вас бессрочный доступ"
                }
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: note)
            default:
                break
            }
            try await showPage(.superSimulate, chatKey: chatKey, callback: callback, message: message)
            return

        case "sinspect":
            guard await state.isSuperAdmin(username: callback.from.username) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
                return
            }
            guard parts.count >= 2, let targetChatID = Int(parts[1]) else { return }
            let (text, markup) = await renderInspect(chatID: targetChatID)
            try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)
            return

        case "ads":
            guard await state.isSuperAdmin(username: callback.from.username) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
                return
            }
            guard parts.count >= 2 else { return }
            switch parts[1] {
            case "add":
                await state.setAdminPendingInput(.init(kind: .adAddText, menuMessageID: message.message_id, payload: nil), chatKey: chatKey)
                let prompt = """
                <b>📣 Новое объявление</b>

                Отправьте текст объявления одним сообщением (HTML разрешён).
                Частота по умолчанию: каждые 10 ответов, пауза 60 минут. Настроить точнее — /ads.
                """
                let markup = InlineKeyboardMarkup(inline_keyboard: [[menuButton("❌ Отмена", action: "nav:superads")]])
                try await editOrAnswer(callback: callback, message: message, text: prompt, markup: markup)
            case "toggle":
                guard parts.count >= 3 else { return }
                let id = parts[2]
                let enabled = await state.adCampaign(id: id)?.enabled ?? false
                _ = await state.setAdCampaignEnabled(id: id, enabled: !enabled)
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: enabled ? "⏸ Выключена" : "▶️ Включена")
                try await showPage(.superAds, chatKey: chatKey, callback: callback, message: message)
            case "rm":
                guard parts.count >= 3 else { return }
                _ = await state.removeAdCampaign(id: parts[2])
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🗑 Удалена")
                try await showPage(.superAds, chatKey: chatKey, callback: callback, message: message)
            default:
                try await showPage(.superAds, chatKey: chatKey, callback: callback, message: message)
            }
            return

        case "markup":
            guard await state.isSuperAdmin(username: callback.from.username) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
                return
            }
            guard parts.count >= 2, parts[1] == "set" else { return }
            await state.setAdminPendingInput(.init(kind: .markupPercent, menuMessageID: message.message_id, payload: nil), chatKey: chatKey)
            let currentPct = await state.markupPercent()
            let markupPrompt = """
            <b>💹 Наценка на цены моделей</b>

            Текущая: <b>\(currentPct)%</b>

            Отправьте число от <code>0</code> до <code>500</code> — процент наценки к ценам провайдера. Применяется ко всем ценам, которые видят пользователи (футер, меню, /model), и к списаниям с балансов.
            """
            let markupMarkup = InlineKeyboardMarkup(inline_keyboard: [[menuButton("❌ Отмена", action: "nav:superadmin")]])
            try await editOrAnswer(callback: callback, message: message, text: markupPrompt, markup: markupMarkup)
            return

        case "sbal":
            guard await state.isSuperAdmin(username: callback.from.username) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
                return
            }
            guard parts.count >= 2 else { return }
            switch parts[1] {
            case "add":
                await state.setAdminPendingInput(.init(kind: .balanceTopUp, menuMessageID: message.message_id, payload: nil), chatKey: chatKey)
                let prompt = """
                <b>💰 Начислить / списать баланс</b>

                Отправьте одним сообщением: <code>@username сумма</code>

                <i>Пример:</i> <code>@user 5</code> — начислить $5
                Отрицательная сумма — списать. Кошелёк создаётся автоматически.
                """
                let markup = InlineKeyboardMarkup(inline_keyboard: [[menuButton("❌ Отмена", action: "nav:superbal")]])
                try await editOrAnswer(callback: callback, message: message, text: prompt, markup: markup)
            case "rm":
                guard parts.count >= 3 else { return }
                let removed = await state.removeBalance(username: parts[2])
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: removed ? "✓ Кошелёк удалён" : "Кошелёк не найден")
                try await showPage(.superBalances, chatKey: chatKey, callback: callback, message: message)
            default:
                try await showPage(.superBalances, chatKey: chatKey, callback: callback, message: message)
            }
            return

        case "buy":
            try await handleBuyAction(parts: parts, chatKey: chatKey, callback: callback, message: message)
            return

        case "crypto":
            guard await state.isSuperAdmin(username: callback.from.username) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
                return
            }
            try await handleCryptoAdminAction(parts: parts, chatKey: chatKey, callback: callback, message: message)
            return

        case "card":
            guard await state.isSuperAdmin(username: callback.from.username) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
                return
            }
            try await handleCardAdminAction(parts: parts, chatKey: chatKey, callback: callback, message: message)
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
        // Funnel: reaching the purchase page counts as "opened purchase".
        if page == .pay { await state.bumpFunnel(.openPurchase) }
        let (text, markup) = await renderPage(page, chatKey: chatKey, username: callback.from.username)
        try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)
    }

    private func closeMenu(callback: CallbackQuery, message: MaybeInaccessibleMessage) async throws {
        let chatKey = ChatKey(chatID: message.chat.id, threadID: message.message_thread_id ?? 0)
        await state.clearPendingInput(chatKey: chatKey)
        await state.clearPendingStarsPriceInput(chatKey: chatKey)
        await state.clearPendingStarsPerUsdInput(chatKey: chatKey)
        await state.clearPendingFreeModelInput(chatKey: chatKey)
        await state.clearPendingCryptoPriceInput(chatKey: chatKey)
        await state.clearPendingCryptoAddressInput(chatKey: chatKey)
        await state.clearPendingCryptoPoolAddInput(chatKey: chatKey)
        await state.clearAdminPendingInput(chatKey: chatKey)
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
        case .pay:
            return await renderPay(chatKey: chatKey, username: username)
        case .adminPanel:
            return await renderAdminPanel(chatKey: chatKey, username: username)
        case .adminHelp:
            return renderAdminHelp()
        case .adminChats:
            return await renderAdminChats(chatKey: chatKey, username: username)
        case .adminUsers:
            return await renderAdminUsers(chatKey: chatKey, username: username)
        case .adminWhitelist:
            return await renderAdminWhitelist(chatKey: chatKey)
        case .adminDefaults:
            return await renderAdminDefaults(chatKey: chatKey)
        case .superAdmin:
            return await renderSuperAdmin(chatKey: chatKey)
        case .superAdminHelp:
            return renderSuperAdminHelp()
        case .superStars:
            return await renderSuperStars(chatKey: chatKey)
        case .superCrypto:
            return await renderSuperCrypto(chatKey: chatKey)
        case .superCard:
            return await renderSuperCard(chatKey: chatKey)
        case .superFreeModels:
            return await renderSuperFreeModels(chatKey: chatKey)
        case .superTenants:
            return await renderSuperTenants(chatKey: chatKey)
        case .superAdmins:
            return await renderSuperAdmins(chatKey: chatKey, username: username)
        case .superSimulate:
            return await renderSuperSimulate(chatKey: chatKey, username: username)
        case .superChats:
            return await renderSuperChats(chatKey: chatKey)
        case .superAds:
            return await renderSuperAds(chatKey: chatKey)
        case .superBalances:
            return await renderSuperBalances(chatKey: chatKey)
        case .superFunnel:
            return await renderSuperFunnel(chatKey: chatKey)
        case .adminInvite:
            return await renderAdminInvite(chatKey: chatKey, username: username)
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
            let billedTotal = await state.billedCost(of: usage)
            if billedTotal > 0 {
                parts.append("итого <b>$\(Self.formatCost(billedTotal))</b>")
            }
            usageLine = "📈 " + parts.joined(separator: " · ")
        }

        // Pay-as-you-go users see their wallet right on the main page.
        let wallet = await state.balance(username: username)
        var balanceLine = ""
        if let wallet {
            let status = wallet.balanceUsd > 0 ? "" : " <i>(исчерпан)</i>"
            balanceLine = String(format: "\n💰 Баланс · <b>$%.4f</b>", wallet.balanceUsd) + status
        }

        let text = """
        <b>⚙️ Настройки чата</b>

        🔌 Провайдер · <b>\(help.provider.commandValue)</b>
        🤖 Модель · <b>\(help.model)</b>
        🌡 Темп · <b>\(Self.formatTemp(help.temp))</b>
        📝 История · <b>\(help.maxHistory) сообщ.</b>\
        \(reasoningSupported ? "\n🧠 Reasoning · <b>\(reasoningLabel)</b>" : "")

        \(usageLine)\(balanceLine)
        🆔 <code>\(chatKey.chatID)</code>
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
        // Monetization entry point: shown whenever there is something to buy
        // or an existing subscription/wallet to inspect.
        let starsPrice = await state.starsPrice()
        let cryptoCents = await state.cryptoPriceUsdCents()
        var isTenant = false
        if let username {
            isTenant = await state.isTenant(username: username)
        }
        if (starsPrice ?? 0) > 0 || cryptoCents != nil || isTenant || wallet != nil {
            let payLabel = isTenant ? "🔄 Продлить премиум" : "⚡ Премиум-доступ"
            rows.append([menuButton(payLabel, action: "nav:pay")])
        }
        // Viral loop: one tap opens Telegram's group picker and adds the bot.
        if !botUsername.isEmpty {
            rows.append([InlineKeyboardButton(text: "➕ Добавить в свой чат", url: "https://t.me/\(botUsername)?startgroup=add")])
        }
        rows.append([menuButton("❓ Справка", action: "nav:help"), menuButton("↺ Сбросить", action: "reset")])
        if await state.isSuperAdmin(username: username) {
            rows.append([
                menuButton("🛠 Админ-панель", action: "nav:admin"),
                menuButton("🛡 Супер-админ", action: "nav:superadmin"),
            ])
        } else if await state.isAdmin(username: username, chatID: chatKey.chatID) {
            rows.append([menuButton("🛠 Админ-панель", action: "nav:admin")])
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

        rows.append([menuButton("✏️ Своя роль", action: "role:custom"), menuButton("↺ Стандартная", action: "role:default")])
        rows.append([menuButton("⚙️ Управление пресетами", action: "pm:role")])
        rows.append(navButtons())

        let text = """
        <b>🎭 Роль ассистента</b>

        Текущая:
        <blockquote expandable>\(help.role)</blockquote>

        <i>🌐 — общая для всех чатов · 💬 — только для этого</i>
        ✏️ — своя роль текстом (или /setrole &lt;текст&gt;)
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderModel(chatKey: ChatKey, username: String? = nil) async -> (String, InlineKeyboardMarkup) {
        let help = await state.fetchHelp(chatKey: chatKey)
        let globalPresets = await state.modelPresets(chatID: chatKey.chatID)
        let chatPresets = await state.chatPresets(category: .model, chatKey: chatKey)
        let effectiveFreeModels = await state.effectiveFreeModelIDs()
        let hasFullAccess = await state.hasFullModelAccess(username: username, chatID: chatKey.chatID)
        let restrictionsActive = effectiveFreeModels != nil
        let modelPrices = await state.openRouterModelPrices()
        var rows: [[InlineKeyboardButton]] = []

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
                currentRow.append(menuButton(label, action: "model:\(action):\(preset.value)"))
                if currentRow.count == 2 { rows.append(currentRow); currentRow = [] }
            }
            if !currentRow.isEmpty { rows.append(currentRow) }
        }

        if !globalPresets.isEmpty { appendPresets(globalPresets, action: "gsel") }
        if !chatPresets.isEmpty { appendPresets(chatPresets, action: "csel") }

        if modelPriceMonitor != nil {
            rows.append([menuButton("🆓 Бесплатные модели OpenRouter", action: "model:freemodels")])
        }
        rows.append([menuButton("✏️ Ввести ID модели", action: "model:custom")])
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

        let routingLine = help.modelProviderRouting.map { "\nПровайдер · 📡 <code>\($0)</code>" } ?? ""
        let text = """
        <b>🤖 Модель</b>

        Текущая · <code>\(help.model)</code>\(routingLine)\(legendLine)\(priceSection)

        <i>Смена модели очистит историю.</i>
        Своя модель — /model &lt;id&gt;
        <i>С провайдером — /model &lt;id&gt; | &lt;провайдер&gt;</i>
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

        rows.append([menuButton("✏️ Своё значение", action: "temp:custom")])
        rows.append([menuButton("⚙️ Управление пресетами", action: "pm:temp")])
        rows.append(navButtons())

        let bucket = Self.tempBucket(help.temp)
        let text = """
        <b>🌡 Температура</b>

        Текущая · <b>\(Self.formatTemp(help.temp))</b> — \(bucket)

        <i>0.0 — точно и предсказуемо · 2.0 — креативно и хаотично</i>
        ✏️ — своё значение (или /settemp &lt;0.0–2.0&gt;)
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderStats(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let help = await state.fetchHelp(chatKey: chatKey)
        let testModeOn = help.testModeSuffix != nil
        let testLabel: String = {
            if let s = help.testModeSuffix {
                return "🟢 Тест-режим (суффикс \(s))"
            }
            return "⚪️ Тест-режим"
        }()
        let rows: [[InlineKeyboardButton]] = [
            [menuButton("\(toggleMark(help.showTokens)) Токены", action: "stats:toggle:tokens"),
             menuButton("\(toggleMark(help.showCost)) Стоимость", action: "stats:toggle:cost")],
            [menuButton("\(toggleMark(help.showModel)) Модель", action: "stats:toggle:model")],
            [menuButton("\(toggleMark(help.backupNotify)) Уведомления о бэкапе", action: "stats:toggle:backup")],
            [menuButton(testLabel, action: "stats:toggle:testmode")],
            navButtons(),
        ]
        let testHint = testModeOn
            ? "\n\n<i>🧪 Тест-режим включён — добавляйте суффикс <code>\(help.testModeSuffix!)</code> к командам, чтобы их выполнял именно этот экземпляр бота.</i>"
            : ""
        let text = """
        <b>📊 Что показывать в ответе</b>

        🟢 — включено · ⚪️ — выключено

        <i>Токены — сколько слов обработано
        Стоимость — цена одного запроса в $
        Модель — какая модель ответила</i>

        Нажмите, чтобы переключить.\(testHint)
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

        rows.append([
            menuButton("📜 Показать историю", action: "history:dump"),
            menuButton("🧹 Очистить", action: "history:clear"),
        ])
        rows.append([menuButton("✏️ Своя длина", action: "history:custom")])
        rows.append([menuButton("⚙️ Управление пресетами", action: "pm:history")])
        rows.append(navButtons())

        let text = """
        <b>📝 Память бота</b>

        Помнит последние · <b>\(help.maxHistory) сообщ.</b>

        <i>Чем больше, тем лучше контекст, но дороже и медленнее.</i>
        ✏️ — своё значение (или /historylength &lt;1–50&gt;)
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
        let rows: [[InlineKeyboardButton]] = [navButtons()]
        return (BotCallbackHandler.faqText, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderPay(chatKey: ChatKey, username: String?) async -> (String, InlineKeyboardMarkup) {
        let starsPrice = await state.starsPrice()
        let cryptoCents = await state.cryptoPriceUsdCents()
        let cryptoAssets: [CryptoAsset] = await {
            guard let service = cryptoService else { return [] }
            return await service.availableAssets()
        }()
        let starsAvailable = (starsPrice ?? 0) > 0
        let cryptoAvailable = cryptoCents != nil && !cryptoAssets.isEmpty
        let card = await state.cardConfig()

        var lines: [String] = ["<b>⚡ Премиум-доступ для этого чата</b>", ""]
        var rows: [[InlineKeyboardButton]] = []
        var unlimited = false

        if let username {
            if await state.isTenant(username: username) {
                let sub = await state.tenantSubscription(ownerUsername: username)
                let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy"
                if sub.paidUntil == nil {
                    lines.append("✅ У вас <b>бессрочный</b> доступ — покупать нечего.")
                    unlimited = true
                } else if let until = sub.paidUntil, sub.isActive {
                    lines.append("💳 Подписка активна до <b>\(f.string(from: until))</b>.")
                    lines.append("<i>Оплата ниже продлит её на \(ChatContextStore.subscriptionDays) дней (срок прибавляется).</i>")
                } else if let until = sub.paidUntil {
                    lines.append("⛔ Подписка истекла <b>\(f.string(from: until))</b>.")
                    lines.append("<i>Оплата ниже возобновит доступ на \(ChatContextStore.subscriptionDays) дней — чаты и настройки сохранены.</i>")
                }
                lines.append("Управление доступом — /menu → 🛠 Админ-панель.")
            } else {
                lines.append("""
                Что открывается:
                • Умные модели — GPT, Claude, Gemini (точнее и способнее бесплатных)
                • Без рекламы
                • Без дневных лимитов
                • Работает у всех в этом чате — и в вашей личке с ботом

                Одна оплата — доступ во всех ваших чатах, на <b>\(ChatContextStore.subscriptionDays) дней</b>.
                """)
            }
            if let wallet = await state.balance(username: username) {
                lines.append("")
                lines.append(String(format: "💰 Баланс · <b>$%.4f</b>", wallet.balanceUsd) + (wallet.balanceUsd > 0 ? "" : " <i>(исчерпан)</i>"))
                lines.append("<i>Баланс — альтернатива подписке: оплата каждого ответа по факту. Детали — /balance.</i>")
            }
        } else {
            lines.append("⚠️ Для покупки нужен <b>@username</b> — установите его в настройках Telegram и откройте меню заново.")
        }

        if !unlimited {
            if starsAvailable, let starsPrice {
                rows.append([menuButton("💫 Оплатить Stars · \(starsPrice) ⭐", action: "buy:stars")])
            }
            if cryptoAvailable, let cents = cryptoCents {
                rows.append([menuButton(String(format: "🪙 Криптовалюта · $%.2f", Double(cents) / 100.0), action: "buy:crypto")])
            }
            if card.isEnabled, let priceLabel = card.priceLabel {
                rows.append([menuButton("💳 Картой · \(priceLabel)", action: "buy:card")])
            }
            if !starsAvailable, !cryptoAvailable, !card.isEnabled {
                lines.append("")
                lines.append("ℹ️ Продажа доступа сейчас недоступна.")
            }

            // Pay-as-you-go credit packs — a lower entry point than a full
            // subscription. Bought with Stars or crypto (same availability).
            if username != nil, starsAvailable || cryptoAvailable {
                lines.append("")
                lines.append("💰 <b>Не готов на месяц?</b> Пополни баланс — платишь по факту за каждый ответ, доступны любые модели.")
                let packRow = CreditPack.centsOptions.map {
                    menuButton(CreditPack.label(cents: $0), action: "buy:credits:\($0)")
                }
                rows.append(packRow)
            }
        }
        rows.append(navButtons())
        return (lines.joined(separator: "\n"), InlineKeyboardMarkup(inline_keyboard: rows))
    }

    // MARK: - Buy flow (user-facing)

    private func handleBuyAction(
        parts: [String],
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard parts.count >= 2 else { return }
        switch parts[1] {
        case "credits":
            // Pack chosen → offer the payment methods available for credits.
            guard parts.count >= 3, let cents = Int(parts[2]), CreditPack.isValid(cents: cents) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Неизвестный пакет")
                return
            }
            var rows: [[InlineKeyboardButton]] = []
            if let price = await state.starsPrice(), price > 0 {
                let stars = await state.starsForCents(cents)
                rows.append([menuButton("💫 Stars · \(stars) ⭐", action: "buy:cstars:\(cents)")])
            }
            let cryptoCents = await state.cryptoPriceUsdCents()
            let cryptoAssets: [CryptoAsset]
            if let service = cryptoService { cryptoAssets = await service.availableAssets() } else { cryptoAssets = [] }
            if cryptoCents != nil, !cryptoAssets.isEmpty {
                rows.append([menuButton("🪙 Криптой", action: "buy:ccrypto:\(cents)")])
            }
            rows.append(navButtons())
            let text = """
            💰 <b>Пополнить баланс на \(CreditPack.label(cents: cents))</b>

            Баланс тратится по факту за каждый ответ — доступны любые модели, остаток виден в футере (включи /show_cost).

            Выбери способ оплаты:
            """
            try await editOrAnswer(callback: callback, message: message, text: text, markup: InlineKeyboardMarkup(inline_keyboard: rows))

        case "cstars":
            // Credit pack via Stars.
            guard parts.count >= 3, let cents = Int(parts[2]), CreditPack.isValid(cents: cents) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Неизвестный пакет")
                return
            }
            guard let price = await state.starsPrice(), price > 0 else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Stars-оплата отключена")
                return
            }
            guard callback.from.username != nil else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Требуется @username")
                return
            }
            let stars = await state.starsForCents(cents)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: nil)
            try await telegram.sendInvoice(.init(
                chatID: chatKey.chatID,
                title: "Пополнение баланса · \(CreditPack.label(cents: cents))",
                description: "Кредиты на баланс: оплата каждого ответа по факту, любые модели",
                payload: "credits_\(cents)",
                starsAmount: stars
            ))
            await state.bumpFunnel(.invoiceSent)

        case "stars":
            guard let price = await state.starsPrice(), price > 0 else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Stars-оплата отключена")
                return
            }
            guard let username = callback.from.username else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Требуется @username")
                return
            }
            // Unlimited tenants have nothing to buy; expiring ones renew.
            let starsSub = await state.tenantSubscription(ownerUsername: username)
            if starsSub.exists, starsSub.paidUntil == nil {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "У вас бессрочный доступ")
                return
            }
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: nil)
            try await telegram.sendInvoice(.init(
                chatID: chatKey.chatID,
                title: "Премиум-доступ · \(ChatContextStore.subscriptionDays) дней",
                description: "Умные модели (GPT, Claude, Gemini), без рекламы и лимитов — для этого чата и вашей лички",
                payload: "buy_access",
                starsAmount: price
            ))
            await state.bumpFunnel(.invoiceSent)

        case "card":
            let card = await state.cardConfig()
            guard card.isEnabled, let token = card.providerToken, let minorUnits = card.priceMinorUnits else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Оплата картой отключена")
                return
            }
            guard let cardUsername = callback.from.username else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Требуется @username")
                return
            }
            let cardSub = await state.tenantSubscription(ownerUsername: cardUsername)
            if cardSub.exists, cardSub.paidUntil == nil {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "У вас бессрочный доступ")
                return
            }
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: nil)
            try await telegram.sendInvoice(.init(
                chatID: chatKey.chatID,
                title: "Премиум-доступ · \(ChatContextStore.subscriptionDays) дней",
                description: "Умные модели (GPT, Claude, Gemini), без рекламы и лимитов — для этого чата и вашей лички",
                payload: "buy_access_card",
                kind: .fiat(currency: card.currency.rawValue, amountMinorUnits: minorUnits, providerToken: token)
            ))
            await state.bumpFunnel(.invoiceSent)

        case "crypto":
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: nil)
            await sendCryptoAssetChoice(chatKey: chatKey)

        case "ccrypto":
            // Credit pack via crypto → pick asset (cents carried in callback).
            guard parts.count >= 3, let cents = Int(parts[2]), CreditPack.isValid(cents: cents) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Неизвестный пакет")
                return
            }
            guard let service = cryptoService else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Крипто-оплата недоступна")
                return
            }
            let assets = await service.availableAssets()
            guard !assets.isEmpty else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Адреса не настроены")
                return
            }
            var assetRows: [[InlineKeyboardButton]] = assets.map {
                [menuButton($0.displayLabel, action: "buy:casset:\($0.rawValue):\(cents)")]
            }
            assetRows.append(navButtons())
            let assetText = """
            🪙 <b>Пополнение баланса на \(CreditPack.label(cents: cents))</b>

            Выбери сеть/актив для оплаты:
            """
            try await editOrAnswer(callback: callback, message: message, text: assetText, markup: InlineKeyboardMarkup(inline_keyboard: assetRows))

        case "casset":
            guard parts.count >= 4, let asset = CryptoAsset(rawValue: parts[2]),
                  let cents = Int(parts[3]), CreditPack.isValid(cents: cents) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Неизвестный актив")
                return
            }
            guard let service = cryptoService else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Крипто-оплата недоступна")
                return
            }
            guard let username = callback.from.username else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Требуется @username")
                return
            }
            do {
                let invoice = try await service.createOrRefreshInvoice(
                    username: username,
                    userChatID: chatKey.chatID,
                    asset: asset,
                    purpose: .credit(cents: cents)
                )
                let (text, markup) = renderInvoice(invoice)
                try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)
            } catch {
                logger.error("crypto credit invoice creation failed: \(error)")
                try? await telegram.answerCallback(
                    callbackQueryID: callback.id,
                    text: UserFacingError.shortMessage(error, context: "Не удалось создать счёт")
                )
            }

        case "asset":
            guard parts.count >= 3, let asset = CryptoAsset(rawValue: parts[2]) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Неизвестный актив")
                return
            }
            guard let service = cryptoService else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Крипто-оплата недоступна")
                return
            }
            guard let username = callback.from.username else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Требуется @username")
                return
            }
            let cryptoSub = await state.tenantSubscription(ownerUsername: username)
            if cryptoSub.exists, cryptoSub.paidUntil == nil {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "У вас бессрочный доступ")
                return
            }
            do {
                let invoice = try await service.createOrRefreshInvoice(
                    username: username,
                    userChatID: chatKey.chatID,
                    asset: asset
                )
                let (text, markup) = renderInvoice(invoice)
                try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)
            } catch {
                logger.error("crypto invoice creation failed: \(error)")
                try? await telegram.answerCallback(
                    callbackQueryID: callback.id,
                    text: UserFacingError.shortMessage(error, context: "Не удалось создать счёт")
                )
            }

        case "refresh":
            guard parts.count >= 3 else { return }
            let invoiceID = parts[2]
            guard let invoice = await state.cryptoInvoice(id: invoiceID) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Счёт не найден")
                return
            }
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: nil)
            let (text, markup) = renderInvoice(invoice)
            try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)

        case "cancel":
            guard parts.count >= 3 else { return }
            let invoiceID = parts[2]
            guard let invoice = await state.cryptoInvoice(id: invoiceID) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Счёт не найден")
                return
            }
            if invoice.username != (callback.from.username?.lowercased() ?? "") {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Не ваш счёт")
                return
            }
            await cryptoService?.cancelInvoice(id: invoiceID)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Счёт отменён")
            try await telegram.editMessage(.init(
                chatID: message.chat.id,
                messageID: message.message_id,
                text: "❌ Счёт отменён.",
                replyMarkup: InlineKeyboardMarkup(inline_keyboard: [])
            ))

        default:
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: nil)
        }
    }

    private func renderInvoice(_ invoice: CryptoInvoice) -> (String, InlineKeyboardMarkup) {
        let amount = CryptoAmountFormatter.format(atomic: invoice.exactAmountAtomic, decimals: invoice.asset.decimals)
        let received = CryptoAmountFormatter.format(atomic: invoice.accumulatedAtomic, decimals: invoice.asset.decimals)
        let remaining = CryptoAmountFormatter.format(atomic: invoice.remainingAtomic, decimals: invoice.asset.decimals)
        let expiresMin = max(0, Int(invoice.expiresAt.timeIntervalSinceNow / 60))

        var statusLine = ""
        switch invoice.status {
        case .open:
            statusLine = "⏳ Ожидаю оплату"
        case .partial:
            statusLine = "⚠️ Частично оплачено"
        case .paid:
            statusLine = "✅ Оплачено"
        case .expired:
            statusLine = "⌛ Истёк"
        case .cancelled:
            statusLine = "❌ Отменён"
        }

        let purposeLine: String
        switch invoice.resolvedPurpose {
        case .subscription:
            purposeLine = "Назначение: <b>Премиум-доступ · \(ChatContextStore.subscriptionDays) дн.</b>"
        case .credit(let cents):
            purposeLine = "Назначение: <b>Пополнение баланса \(CreditPack.label(cents: cents))</b>"
        }
        var lines: [String] = [
            "<b>🪙 Счёт на оплату</b>",
            "",
            purposeLine,
            "Сеть: <b>\(invoice.asset.displayLabel)</b>",
            "К оплате: <b>\(amount) \(invoice.asset.symbol)</b>",
        ]
        if invoice.accumulatedAtomic > 0 {
            lines.append("Получено: <b>\(received) \(invoice.asset.symbol)</b>")
            lines.append("Осталось: <b>\(remaining) \(invoice.asset.symbol)</b>")
        }
        lines.append("")
        lines.append("Адрес:")
        lines.append("<code>\(invoice.receivingAddress)</code>")
        lines.append("")
        lines.append("⚠️ <b>Отправьте РОВНО эту сумму</b> — иначе зачисление потребует ручного разбора.")
        lines.append("")
        lines.append("Срок: <b>\(expiresMin) мин</b>")
        lines.append(statusLine)

        var rows: [[InlineKeyboardButton]] = []
        if invoice.status == .open || invoice.status == .partial {
            rows.append([menuButton("🔄 Обновить статус", action: "buy:refresh:\(invoice.id)")])
            rows.append([menuButton("❌ Отменить счёт", action: "buy:cancel:\(invoice.id)")])
        }
        rows.append([menuButton("✕ Закрыть", action: "close")])

        return (lines.joined(separator: "\n"), InlineKeyboardMarkup(inline_keyboard: rows))
    }

    // MARK: - Card admin actions

    private func handleCardAdminAction(
        parts: [String],
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard parts.count >= 2 else { return }
        switch parts[1] {
        case "settoken":
            await state.setAdminPendingInput(.init(kind: .cardProviderToken, menuMessageID: message.message_id, payload: nil), chatKey: chatKey)
            let card = await state.cardConfig()
            let currentLine = card.maskedToken.map { "Текущий: <code>\($0)</code>" } ?? "Токен ещё не задан."
            let text = """
            <b>🔑 Токен платёжного провайдера</b>

            \(currentLine)

            Отправьте токен одним сообщением. Его выдаёт @BotFather: \
            /mybots → бот → Bot Settings → Payments → выбрать провайдера.
            Формат: <code>123456789:TEST:...</code> или <code>123456789:LIVE:...</code>

            Отправьте <code>-</code> чтобы удалить токен.
            """
            let markup = InlineKeyboardMarkup(inline_keyboard: [
                [menuButton("❌ Отмена", action: "nav:supercard")]
            ])
            try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)

        case "deltoken":
            await state.setCardProviderToken(nil)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Токен удалён")
            try await showPage(.superCard, chatKey: chatKey, callback: callback, message: message)

        case "setprice":
            await state.setAdminPendingInput(.init(kind: .cardPrice, menuMessageID: message.message_id, payload: nil), chatKey: chatKey)
            let card = await state.cardConfig()
            let label = card.priceLabel ?? "не задана"
            let text = """
            <b>💳 Цена подписки картой</b>

            Текущая: <b>\(label)</b> · валюта <b>\(card.currency.rawValue)</b>

            Введите сумму (например <code>499</code> или <code>4.99</code>) или <b>0</b> для отключения продаж.
            """
            let markup = InlineKeyboardMarkup(inline_keyboard: [
                [menuButton("❌ Отмена", action: "nav:supercard")]
            ])
            try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)

        case "currency":
            guard parts.count >= 3, let currency = CardCurrency(rawValue: parts[2]) else { return }
            await state.setCardCurrency(currency)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Валюта: \(currency.rawValue)")
            try await showPage(.superCard, chatKey: chatKey, callback: callback, message: message)

        case "disable":
            await state.setCardPriceMinorUnits(nil)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Продажи картой отключены")
            try await showPage(.superCard, chatKey: chatKey, callback: callback, message: message)

        default:
            try await showPage(.superCard, chatKey: chatKey, callback: callback, message: message)
        }
    }

    // MARK: - Crypto admin actions

    private func handleCryptoAdminAction(
        parts: [String],
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard parts.count >= 2 else { return }
        switch parts[1] {
        case "setprice":
            await state.setPendingCryptoPriceInput(menuMessageID: message.message_id, chatKey: chatKey)
            let cents = await state.cryptoPriceUsdCents()
            let label = cents.map { String(format: "$%.2f", Double($0) / 100.0) } ?? "отключена"
            let text = """
            <b>🪙 Цена в USDT</b>

            Текущая: <b>\(label)</b>

            Введите сумму в долларах (например <code>9.99</code>) или <b>0</b> для отключения.
            """
            let markup = InlineKeyboardMarkup(inline_keyboard: [
                [menuButton("❌ Отмена", action: "nav:supercrypto")]
            ])
            try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)

        case "disableprice":
            await state.setCryptoPriceUsdCents(nil)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Отключено")
            try await showPage(.superCrypto, chatKey: chatKey, callback: callback, message: message)

        case "setaddr":
            guard parts.count >= 3, let chain = CryptoChain(rawValue: parts[2]) else { return }
            await state.setPendingCryptoAddressInput(menuMessageID: message.message_id, chain: chain, chatKey: chatKey)
            let current = await state.cryptoAddress(chain) ?? "<i>не задан</i>"
            let text = """
            <b>🪙 Адрес для приёма · \(chain.displayName)</b>

            Текущий: <code>\(current)</code>

            Отправьте новый адрес одним сообщением. Отправьте <code>-</code> чтобы удалить.
            """
            let markup = InlineKeyboardMarkup(inline_keyboard: [
                [menuButton("❌ Отмена", action: "nav:supercrypto")]
            ])
            try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)

        case "deladdr":
            guard parts.count >= 3, let chain = CryptoChain(rawValue: parts[2]) else { return }
            await state.setCryptoAddress(chain, address: nil)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Адрес удалён")
            try await showPage(.superCrypto, chatKey: chatKey, callback: callback, message: message)

        case "togglemode":
            let current = await state.cryptoMatchMode()
            let next: CryptoMatchMode = current == .amountDelta ? .uniqueAddress : .amountDelta
            await state.setCryptoMatchMode(next)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Режим: \(next.displayName)")
            try await showPage(.superCrypto, chatKey: chatKey, callback: callback, message: message)

        case "pooladd":
            guard parts.count >= 3, let chain = CryptoChain(rawValue: parts[2]) else { return }
            await state.setPendingCryptoPoolAddInput(menuMessageID: message.message_id, chain: chain, chatKey: chatKey)
            let pool = await state.cryptoAddressPool(chain)
            let listing = pool.isEmpty ? "<i>пусто</i>" : pool.enumerated().map { "\($0.offset + 1). <code>\($0.element)</code>" }.joined(separator: "\n")
            let text = """
            <b>🪙 Пул · \(chain.displayName)</b>

            Текущие адреса:
            \(listing)

            Отправьте новый адрес одним сообщением.
            """
            let markup = InlineKeyboardMarkup(inline_keyboard: [
                [menuButton("❌ Отмена", action: "nav:supercrypto")]
            ])
            try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)

        case "poolrm":
            guard parts.count >= 4, let chain = CryptoChain(rawValue: parts[2]), let index = Int(parts[3]) else { return }
            let removed = await state.removeCryptoPoolAddress(chain, at: index)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: removed ? "✓ Удалено" : "Не найдено")
            try await showPage(.superCrypto, chatKey: chatKey, callback: callback, message: message)

        case "invoices":
            let invoices = await state.openCryptoInvoices()
            var text = "<b>🪙 Открытые счета</b> (\(invoices.count))\n"
            if invoices.isEmpty {
                text += "<i>нет</i>"
            } else {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                let sorted = invoices.sorted { $0.createdAt < $1.createdAt }
                for inv in sorted.prefix(20) {
                    let amount = CryptoAmountFormatter.format(atomic: inv.exactAmountAtomic, decimals: inv.asset.decimals)
                    let received = CryptoAmountFormatter.format(atomic: inv.accumulatedAtomic, decimals: inv.asset.decimals)
                    text += "\n• @\(inv.username) · \(inv.asset.displayLabel) · \(received)/\(amount) \(inv.asset.symbol) · \(inv.status.rawValue)"
                }
            }
            let markup = InlineKeyboardMarkup(inline_keyboard: [
                [menuButton("← Назад", action: "nav:superadmin")]
            ])
            try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)

        default:
            try await showPage(.superCrypto, chatKey: chatKey, callback: callback, message: message)
        }
    }

    private func handleTenantAction(
        parts: [String],
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        guard parts.count >= 2 else { return }
        let invokerUsername = callback.from.username
        let invoker = invokerUsername?.lowercased()
        let isSuper = await state.isSuperAdmin(username: invokerUsername)
        let isAdmin = await state.isAdmin(username: invokerUsername, chatID: chatKey.chatID)
        guard isAdmin || isSuper else {
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только админ")
            return
        }

        switch parts[1] {
        case "claim":
            guard let username = invoker else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Нужен @username")
                return
            }
            let ok = await state.assignChat(chatID: chatKey.chatID, to: username)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: ok ? "✓ Чат привязан" : "Лицензия не активна")
            try await showPage(.adminPanel, chatKey: chatKey, callback: callback, message: message)

        case "release":
            let owner = await state.chatOwner(chatID: chatKey.chatID)
            if !isSuper, owner?.lowercased() != invoker {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Не ваш чат")
                return
            }
            _ = await state.unassignChat(chatID: chatKey.chatID)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Чат отвязан")
            try await showPage(.adminPanel, chatKey: chatKey, callback: callback, message: message)

        case "rmchat":
            guard parts.count >= 3, let chatID = Int(parts[2]) else { return }
            let owner = await state.chatOwner(chatID: chatID)
            if !isSuper, owner?.lowercased() != invoker {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Не ваш чат")
                return
            }
            _ = await state.unassignChat(chatID: chatID)
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Отвязан")
            try await showPage(.adminChats, chatKey: chatKey, callback: callback, message: message)

        case "assignprompt":
            guard let invoker else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Нужен @username")
                return
            }
            await state.setAdminPendingInput(.init(kind: .tenantAssignChat, menuMessageID: message.message_id, payload: invoker), chatKey: chatKey)
            let prompt = """
            <b>📥 Привязать чат по ID</b>

            Отправьте chatID одним сообщением (целое число; для групп — отрицательное).
            """
            let markup = InlineKeyboardMarkup(inline_keyboard: [[menuButton("❌ Отмена", action: "nav:adminchats")]])
            try await editOrAnswer(callback: callback, message: message, text: prompt, markup: markup)
            return

        case "adduserprompt":
            guard let invoker else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Нужен @username")
                return
            }
            await state.setAdminPendingInput(.init(kind: .tenantAddUser, menuMessageID: message.message_id, payload: invoker), chatKey: chatKey)
            let prompt = "<b>➕ Добавить пользователя в лицензию</b>\n\nОтправьте @username одним сообщением."
            let markup = InlineKeyboardMarkup(inline_keyboard: [[menuButton("❌ Отмена", action: "nav:adminusers")]])
            try await editOrAnswer(callback: callback, message: message, text: prompt, markup: markup)
            return

        case "rmuser":
            guard parts.count >= 3, let index = Int(parts[2]), let invoker else { return }
            let users = await state.licensedUsers(ownerUsername: invoker)
            guard index >= 0, index < users.count else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Не найдено")
                return
            }
            _ = await state.removeLicensedUser(ownerUsername: invoker, target: users[index])
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Удалён")
            try await showPage(.adminUsers, chatKey: chatKey, callback: callback, message: message)

        case "newinvite":
            guard let invoker else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Нужен @username")
                return
            }
            if await state.regenerateInviteToken(owner: invoker) != nil {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "✓ Новая ссылка создана")
            } else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Лицензия не активна — /buy")
            }
            try await showPage(.adminInvite, chatKey: chatKey, callback: callback, message: message)

        default:
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: nil)
        }
    }

    private func renderSuperAdmin(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let starsPrice = await state.starsPrice()
        let starsLabel = starsPrice.map { "<b>\($0) ⭐</b>" } ?? "<b>отключена</b>"

        let cryptoCents = await state.cryptoPriceUsdCents()
        let cryptoLabel = cryptoCents.map { String(format: "<b>$%.2f</b>", Double($0) / 100.0) } ?? "<b>отключена</b>"
        let cryptoMode = await state.cryptoMatchMode()
        let openInvoices = await state.openCryptoInvoices()

        let freeModels = await state.freeModelIDs()
        let freeCount = freeModels.count

        let globalRoles = await state.rolePresets(chatID: chatKey.chatID).count
        let globalModels = await state.modelPresets(chatID: chatKey.chatID).count
        let globalTemps = await state.tempPresets(chatID: chatKey.chatID).count
        let globalHist = await state.historyLengthPresets(chatID: chatKey.chatID).count

        let starsButtonLabel = starsPrice.map { "💫 Stars · \($0) ⭐" } ?? "💫 Stars · откл"
        let cryptoButtonLabel = cryptoCents.map { String(format: "🪙 Крипто · $%.2f", Double($0) / 100.0) } ?? "🪙 Крипто · откл"

        let card = await state.cardConfig()
        let cardLabel = card.isEnabled ? "<b>\(card.priceLabel ?? "")</b>\(card.isTestToken ? " · тест" : "")" : "<b>отключена</b>"
        let cardButtonLabel = card.isEnabled ? "💳 Карта · \(card.priceLabel ?? "")" : "💳 Карта · откл"

        let tenantStats = await state.tenantStats()
        let totalTenants = tenantStats.count

        let markupPct = await state.markupPercent()
        let balances = await state.allBalances()
        let balancesTotal = balances.reduce(0.0) { $0 + $1.wallet.balanceUsd }
        let marginTotal = balances.reduce(0.0) { $0 + ($1.wallet.spentBilledUsd - $1.wallet.spentRealUsd) }

        let rows: [[InlineKeyboardButton]] = [
            [menuButton(starsButtonLabel, action: "nav:superstars")],
            [menuButton(cryptoButtonLabel, action: "nav:supercrypto")],
            [menuButton(cardButtonLabel, action: "nav:supercard")],
            [menuButton("🆓 Бесплатные модели · \(freeCount)", action: "nav:superfreemodels")],
            [menuButton("🏢 Tenants и статистика · \(totalTenants)", action: "nav:supertenants")],
            [menuButton("👁 Чаты бота", action: "nav:superchats"),
             menuButton("📣 Реклама", action: "nav:superads")],
            [menuButton("🛡 Суперадмины", action: "nav:superadmins"),
             menuButton("🎭 Симуляция", action: "nav:supersim")],
            [menuButton("💰 Балансы · \(balances.count)", action: "nav:superbal"),
             menuButton("💹 Наценка · \(markupPct)%", action: "markup:set")],
            [menuButton("📊 Воронка и аналитика", action: "nav:superfunnel")],
            [menuButton("🪙 Открытые счета · \(openInvoices.count)", action: "crypto:invoices")],
            [menuButton("📋 Глобальные пресеты — Модель", action: "pm:model"),
             menuButton("🎭 Роль", action: "pm:role")],
            [menuButton("🌡 Темп.", action: "pm:temp"),
             menuButton("📝 История", action: "pm:history")],
            [menuButton("ℹ️ Справка по командам", action: "nav:superadminhelp")],
            navButtons(),
        ]

        let text = """
        <b>🛡 Супер-админ</b>

        💫 Stars · \(starsLabel)
        🪙 Крипто · \(cryptoLabel) · режим <b>\(cryptoMode.displayName)</b>
        💳 Карта · \(cardLabel)
        💹 Наценка · <b>\(markupPct)%</b> · /tenant markup
        💰 Балансов · <b>\(balances.count)</b> · остатки \(String(format: "$%.2f", balancesTotal)) · маржа <b>\(String(format: "$%.4f", marginTotal))</b> · /balance list
        🆓 Бесплатных моделей · <b>\(freeCount)</b>
        🪙 Открытых счетов · <b>\(openInvoices.count)</b>

        <b>Глобальные пресеты</b>
        🤖 Моделей · <b>\(globalModels)</b> · 🎭 Ролей · <b>\(globalRoles)</b>
        🌡 Темп · <b>\(globalTemps)</b> · 📝 Истории · <b>\(globalHist)</b>
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    /// Conversion-funnel analytics page (roadmap step 7): each funnel stage with
    /// step-to-step conversion, plus sponsor tallies (retained vs. churned).
    private func renderSuperFunnel(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let report = await state.funnelReport()
        func n(_ e: FunnelEvent) -> Int { report.count(e) }
        func pct(_ num: Int, _ den: Int) -> String {
            guard den > 0 else { return "—" }
            return String(format: "%.0f%%", Double(num) / Double(den) * 100)
        }

        let start = n(.start)
        let firstMsg = n(.firstMessage)
        let capHit = n(.capHit)
        let openPurchase = n(.openPurchase)
        let invoiceSent = n(.invoiceSent)
        let paid = n(.paid)
        let renewed = n(.renewed)
        let creditTopup = n(.creditTopup)
        let converted = paid + creditTopup

        let lines: [String] = [
            "<b>📊 Воронка конверсии</b>",
            "",
            "1️⃣ Старт (/start) · <b>\(start)</b>",
            "2️⃣ Первое сообщение · <b>\(firstMsg)</b> · активация \(pct(firstMsg, start))",
            "3️⃣ Упёрлись в лимит · <b>\(capHit)</b>",
            "4️⃣ Открыли покупку · <b>\(openPurchase)</b>",
            "5️⃣ Счёт выставлен · <b>\(invoiceSent)</b> · из открывших \(pct(invoiceSent, openPurchase))",
            "6️⃣ Оплатили · <b>\(paid)</b> · из счетов \(pct(paid, invoiceSent))",
            "",
            "🔄 Продлений · <b>\(renewed)</b> · renewal \(pct(renewed, paid))",
            "💰 Пополнений баланса · <b>\(creditTopup)</b>",
            "",
            "🎯 Конверсия в оплату (от активации) · <b>\(pct(converted, firstMsg))</b>",
            "",
            "<b>Спонсоры (по подпискам)</b>",
            "✅ Активных · <b>\(report.sponsorsActive)</b> · ⛔ истёкших (отток) · <b>\(report.sponsorsExpired)</b>"
                + (report.sponsorsUnlimited > 0 ? " · ♾ <b>\(report.sponsorsUnlimited)</b>" : ""),
            "",
            "<i>Счётчики событий (не уникальные юзеры), переживают рестарт. Те же числа — в /metrics. Ретеншн D1/D7 — в разработке.</i>",
        ]

        let rows: [[InlineKeyboardButton]] = [
            [menuButton("🔄 Обновить", action: "nav:superfunnel")],
            navButtons(),
        ]
        return (lines.joined(separator: "\n"), InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderSuperStars(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let price = await state.starsPrice()
        let priceLabel = price.map { "<b>\($0) ⭐</b>" } ?? "<b>отключена</b>"
        let rate = await state.starsPerUsd()
        var packParts: [String] = []
        for cents in CreditPack.centsOptions {
            packParts.append("\(CreditPack.label(cents: cents)) → \(await state.starsForCents(cents))⭐")
        }
        let packLine = packParts.joined(separator: " · ")

        var rows: [[InlineKeyboardButton]] = [
            [menuButton("✏️ Изменить цену подписки", action: "stars:setprice")],
            [menuButton("✏️ Курс кредитов (Stars за $1)", action: "stars:setrate")],
        ]
        if price != nil {
            rows.append([menuButton("⛔ Отключить продажи", action: "stars:disable")])
        }
        rows.append([menuButton("← К супер-админу", action: "nav:superadmin")])

        let text = """
        <b>💫 Stars — продажа доступа</b>

        Цена подписки: \(priceLabel)

        <b>Кредиты (пополнение баланса):</b>
        Курс: <b>\(rate) ⭐ за $1</b>
        \(packLine)

        <i>Цена подписки — Stars за единоразовый доступ (0 = откл). \
        Курс кредитов задаёт, сколько Stars стоит $1 пополнения баланса; \
        Telegram платит ~$0.013/⭐, поэтому 77⭐/$ покрывает себестоимость и маржу.</i>
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderSuperCrypto(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let cryptoCents = await state.cryptoPriceUsdCents()
        let cryptoLabel = cryptoCents.map { String(format: "<b>$%.2f</b>", Double($0) / 100.0) } ?? "<b>отключена</b>"
        let cryptoAddrs = await state.cryptoAddresses()
        let cryptoMode = await state.cryptoMatchMode()
        let cryptoPools = await state.cryptoAddressPools()
        let openInvoices = await state.openCryptoInvoices()

        var rows: [[InlineKeyboardButton]] = [
            [menuButton("✏️ Изменить цену в USDT", action: "crypto:setprice")],
        ]
        if cryptoCents != nil {
            rows.append([menuButton("⛔ Отключить крипто-оплату", action: "crypto:disableprice")])
        }
        rows.append([menuButton("🔀 Режим: \(cryptoMode.displayName)", action: "crypto:togglemode")])

        switch cryptoMode {
        case .amountDelta:
            for chain in CryptoChain.allCases {
                let addr = cryptoAddrs[chain]
                let label = addr.map { _ in "✏️ \(chain.displayName) ✓" } ?? "✏️ \(chain.displayName)"
                var row: [InlineKeyboardButton] = [menuButton(label, action: "crypto:setaddr:\(chain.rawValue)")]
                if addr != nil {
                    row.append(menuButton("🗑", action: "crypto:deladdr:\(chain.rawValue)"))
                }
                rows.append(row)
            }
        case .uniqueAddress:
            for chain in CryptoChain.allCases {
                let pool = cryptoPools[chain] ?? []
                rows.append([menuButton("➕ \(chain.displayName) (\(pool.count))", action: "crypto:pooladd:\(chain.rawValue)")])
                for (i, addr) in pool.enumerated() {
                    let short = addr.count > 22 ? String(addr.prefix(10)) + "…" + String(addr.suffix(8)) : addr
                    rows.append([menuButton("🗑 \(short)", action: "crypto:poolrm:\(chain.rawValue):\(i)")])
                }
            }
        }
        rows.append([menuButton("🪙 Открытые счета (\(openInvoices.count))", action: "crypto:invoices")])
        rows.append([menuButton("← К супер-админу", action: "nav:superadmin")])

        var addrLines: [String] = []
        switch cryptoMode {
        case .amountDelta:
            for chain in CryptoChain.allCases {
                if let addr = cryptoAddrs[chain] {
                    addrLines.append("• \(chain.displayName) · <code>\(addr)</code>")
                }
            }
        case .uniqueAddress:
            for chain in CryptoChain.allCases {
                let pool = cryptoPools[chain] ?? []
                if !pool.isEmpty {
                    addrLines.append("• \(chain.displayName) — пул из \(pool.count) адр.")
                }
            }
        }
        let addrSection = addrLines.isEmpty ? "<i>не настроены</i>" : addrLines.joined(separator: "\n")

        let modeHelp: String
        switch cryptoMode {
        case .amountDelta:
            modeHelp = "<i>Дельта суммы: один адрес на сеть, идентификация по уникальной сумме.</i>"
        case .uniqueAddress:
            modeHelp = "<i>Уникальный адрес: каждому счёту выдаётся свой адрес из пула. Сумма одинаковая.</i>"
        }

        let text = """
        <b>🪙 Крипто-оплата</b>

        Цена: \(cryptoLabel)
        Режим: <b>\(cryptoMode.displayName)</b>
        \(modeHelp)

        Адреса:
        \(addrSection)

        Открытых счетов: <b>\(openInvoices.count)</b>
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderSuperCard(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let card = await state.cardConfig()

        var rows: [[InlineKeyboardButton]] = []
        let tokenLabel = card.maskedToken.map { _ in "🔑 Токен провайдера ✓" } ?? "🔑 Ввести токен провайдера"
        var tokenRow: [InlineKeyboardButton] = [menuButton(tokenLabel, action: "card:settoken")]
        if card.providerToken != nil {
            tokenRow.append(menuButton("🗑", action: "card:deltoken"))
        }
        rows.append(tokenRow)
        rows.append([menuButton("✏️ Изменить цену", action: "card:setprice")])

        var currencyRow: [InlineKeyboardButton] = []
        for currency in CardCurrency.allCases {
            let mark = currency == card.currency ? "✅ " : ""
            currencyRow.append(menuButton("\(mark)\(currency.rawValue)", action: "card:currency:\(currency.rawValue)"))
        }
        rows.append(currencyRow)

        if card.priceMinorUnits != nil {
            rows.append([menuButton("⛔ Отключить продажи", action: "card:disable")])
        }
        rows.append([menuButton("← К супер-админу", action: "nav:superadmin")])

        let tokenLine = card.maskedToken.map { masked in
            "<code>\(masked)</code>" + (card.isTestToken ? " · <b>ТЕСТОВЫЙ</b>" : "")
        } ?? "<i>не задан</i>"
        let priceLine = card.priceLabel.map { "<b>\($0)</b>" } ?? "<i>не задана</i>"
        let statusLine = card.isEnabled
            ? "🟢 Оплата картой <b>включена</b>."
            : "🔴 Оплата картой <b>выключена</b> — нужны токен и цена."

        let text = """
        <b>💳 Оплата картой (эквайринг)</b>

        \(statusLine)

        Токен провайдера: \(tokenLine)
        Валюта: <b>\(card.currency.rawValue)</b>
        Цена: \(priceLine)

        <i>Токен выдаёт @BotFather после подключения платёжного провайдера \
        (ЮKassa, Stripe, Smart Glocal…): Bot Settings → Payments. \
        Инструкция — PAYMENTS_SETUP.md в репозитории.</i>
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderSuperFreeModels(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let pinned = Set(await state.freeModelIDs())
        let pinnedList = await state.freeModelIDs()
        let modelPresets = await state.modelPresets(chatID: chatKey.chatID)
        let chatModelPresets = await state.chatPresets(category: .model, chatKey: chatKey)
        let allPresets = modelPresets + chatModelPresets

        var rows: [[InlineKeyboardButton]] = [
            [menuButton("➕ Добавить по ID", action: "freemodels:add")],
        ]
        if modelPriceMonitor != nil {
            rows.append([menuButton("🌐 Список бесплатных OpenRouter", action: "model:freemodels")])
        }

        if !allPresets.isEmpty {
            for preset in allPresets {
                let isPinned = pinned.contains(preset.value)
                let mark = isPinned ? "🆓" : "☐"
                let action = isPinned ? "model:unmarkfree:\(preset.value)" : "model:markfree:\(preset.value)"
                rows.append([menuButton("\(mark) \(preset.display)", action: action)])
            }
        }

        for (i, modelID) in pinnedList.enumerated() where !allPresets.contains(where: { $0.value == modelID }) {
            let shortID = modelID.count > 28 ? "…" + modelID.suffix(25) : modelID
            rows.append([menuButton("🗑 \(shortID)", action: "freemodels:remove:\(i)")])
        }

        rows.append([menuButton("← К супер-админу", action: "nav:superadmin")])

        let pinnedText = pinnedList.isEmpty
            ? "<i>не закреплены — пользователи без доступа видят все модели как бесплатные</i>"
            : pinnedList.map { "• <code>\($0)</code>" }.joined(separator: "\n")

        let text = """
        <b>🆓 Бесплатные модели</b>

        Закреплено: <b>\(pinnedList.count)</b>
        \(pinnedText)

        <i>Пользователи без полного доступа видят только закреплённые модели. \
        Нажмите ☐ напротив пресета чтобы закрепить, 🆓 — открепить. \
        Модели не из пресетов добавляйте по ID.</i>
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderAdminPanel(chatKey: ChatKey, username: String?) async -> (String, InlineKeyboardMarkup) {
        let defaults = await state.getDefaults(chatID: chatKey.chatID)
        let whitelist = await state.listWhitelisted(chatID: chatKey.chatID)
        let admins = await state.listAdmins(chatID: chatKey.chatID)

        let globalRoles = await state.rolePresets(chatID: chatKey.chatID).count
        let globalModels = await state.modelPresets(chatID: chatKey.chatID).count
        let globalTemps = await state.tempPresets(chatID: chatKey.chatID).count
        let globalHist = await state.historyLengthPresets(chatID: chatKey.chatID).count

        let invoker = username?.lowercased()
        let chatOwner = await state.chatOwner(chatID: chatKey.chatID)
        let isOwnChat = invoker != nil && chatOwner?.lowercased() == invoker
        let chatStatusLine: String
        if let chatOwner {
            chatStatusLine = isOwnChat ? "🟢 этот чат привязан к вам" : "🔒 чат принадлежит @\(chatOwner)"
        } else {
            chatStatusLine = "⚪ чат свободен"
        }

        let licensedChats: [Int]
        let licensedUsers: [String]
        let usage: CumulativeUsage
        if let invoker {
            licensedChats = await state.chatsOwnedBy(invoker)
            licensedUsers = await state.licensedUsers(ownerUsername: invoker)
            usage = await state.tenantUsage(ownerUsername: invoker)
        } else {
            licensedChats = []
            licensedUsers = []
            usage = .zero
        }

        var rows: [[InlineKeyboardButton]] = []
        if isOwnChat {
            rows.append([menuButton("📌 Отвязать этот чат", action: "tenant:release")])
        } else if chatOwner == nil {
            rows.append([menuButton("📌 Привязать этот чат к моей лицензии", action: "tenant:claim")])
        }
        rows.append([menuButton("🔗 Пригласительная ссылка", action: "nav:admininvite")])
        rows.append([
            menuButton("📋 Чаты лицензии · \(licensedChats.count)", action: "nav:adminchats"),
            menuButton("👥 Пользователи · \(licensedUsers.count)", action: "nav:adminusers"),
        ])
        rows.append([
            menuButton("⚙️ Дефолты", action: "nav:admindef"),
            menuButton("👤 Whitelist · \(whitelist.count)", action: "nav:adminwl"),
        ])
        rows.append([menuButton("🤖 Пресеты моделей · \(globalModels)", action: "pm:model"),
                     menuButton("🎭 Ролей · \(globalRoles)", action: "pm:role")])
        rows.append([menuButton("🌡 Темп. · \(globalTemps)", action: "pm:temp"),
                     menuButton("📝 Истории · \(globalHist)", action: "pm:history")])
        rows.append([menuButton("ℹ️ Справка по командам", action: "nav:adminhelp")])
        rows.append(navButtons())

        let adminsLine = admins.isEmpty
            ? "<i>только владелец</i>"
            : admins.sorted().map { "@\($0)" }.joined(separator: ", ")

        let costStr = String(format: "$%.4f", await state.billedCost(of: usage))
        let usageLine = usage.generationCount == 0
            ? "📈 Запросов пока нет"
            : "📈 запросов <b>\(usage.generationCount)</b> · токенов <b>\(Int(usage.totalTokens))</b> · итого <b>\(costStr)</b>"

        let subscriptionLine: String
        if let invoker {
            let sub = await state.tenantSubscription(ownerUsername: invoker)
            if !sub.exists {
                subscriptionLine = "💳 Подписка · <i>нет — /buy</i>"
            } else if let until = sub.paidUntil {
                let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy"
                subscriptionLine = sub.isActive
                    ? "💳 Подписка · до <b>\(f.string(from: until))</b> · продлить /buy"
                    : "💳 Подписка · <b>⛔ истекла \(f.string(from: until))</b> · продлить /buy"
            } else {
                subscriptionLine = "💳 Подписка · <b>бессрочная</b>"
            }
        } else {
            subscriptionLine = "💳 Подписка · <i>нужен @username</i>"
        }

        let text = """
        <b>🛠 Админ-панель</b>

        <b>📌 Лицензия</b>
        \(chatStatusLine)
        🆔 Этот чат · <code>\(chatKey.chatID)</code>
        \(subscriptionLine)
        Чатов · <b>\(licensedChats.count)</b> · юзеров · <b>\(licensedUsers.count)</b>
        \(usageLine)

        <b>По умолчанию для новых чатов</b>
        🤖 Модель · <code>\(defaults.model)</code>
        📝 История · <b>\(defaults.historyLength) сообщ.</b>
        🎭 Роль:
        <blockquote expandable>\(defaults.role)</blockquote>

        <b>👥 Доступ</b>
        Whitelist · <b>\(whitelist.count) ID</b>
        Админы · \(adminsLine)

        <b>📋 Глобальные пресеты</b>
        Кнопки ниже — управление пресетами для всех чатов.
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderAdminChats(chatKey: ChatKey, username: String?) async -> (String, InlineKeyboardMarkup) {
        guard let invoker = username?.lowercased() else {
            return ("У вас не задан @username.", InlineKeyboardMarkup(inline_keyboard: [[menuButton("← Назад", action: "nav:admin")]]))
        }
        let chats = await state.chatsOwnedBy(invoker).sorted()

        var rows: [[InlineKeyboardButton]] = []
        for chatID in chats.prefix(40) {
            let kind = chatID < 0 ? "👥" : "👤"
            rows.append([
                menuButton("\(kind) \(chatID)", action: "noop"),
                menuButton("🗑 Отвязать", action: "tenant:rmchat:\(chatID)"),
            ])
        }
        let chatOwner = await state.chatOwner(chatID: chatKey.chatID)
        if chatOwner?.lowercased() != invoker {
            rows.append([menuButton("📌 Привязать этот чат", action: "tenant:claim")])
        }
        rows.append([menuButton("📥 Привязать чат по ID", action: "tenant:assignprompt")])
        rows.append([menuButton("← К админ-панели", action: "nav:admin")])

        let listText: String
        if chats.isEmpty {
            listText = "<i>нет привязанных чатов</i>"
        } else {
            listText = chats.map { "• <code>\($0)</code>" }.joined(separator: "\n")
        }
        let text = """
        <b>📋 Чаты лицензии @\(invoker)</b> (\(chats.count))

        \(listText)

        <i>Чтобы привязать ещё один чат — добавьте бота туда (он привяжется автоматически), \
        либо откройте этот чат и нажмите «Привязать этот чат». Также можно ввести chatID кнопкой ниже.</i>
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderAdminWhitelist(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let ids = await state.listWhitelisted(chatID: chatKey.chatID).sorted()
        var rows: [[InlineKeyboardButton]] = [
            [menuButton("➕ Добавить ID", action: "wl:add")],
        ]
        for id in ids.prefix(40) {
            rows.append([
                menuButton("\(id)", action: "noop"),
                menuButton("🗑 Убрать", action: "wl:remove:\(id)"),
            ])
        }
        rows.append([menuButton("← К админ-панели", action: "nav:admin")])

        let listText = ids.isEmpty
            ? "<i>пусто</i>"
            : ids.map { "• <code>\($0)</code>" }.joined(separator: "\n")
        let text = """
        <b>👤 Whitelist</b> (\(ids.count))

        \(listText)

        <i>ID пользователей с разрешённым доступом без оплаты в этом чате.</i>
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderAdminDefaults(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let defs = await state.getDefaults(chatID: chatKey.chatID)
        let rows: [[InlineKeyboardButton]] = [
            [menuButton("✏️ Модель", action: "def:model")],
            [menuButton("✏️ Длина истории", action: "def:hist")],
            [menuButton("✏️ Роль", action: "def:role")],
            [menuButton("← К админ-панели", action: "nav:admin")],
        ]
        let text = """
        <b>⚙️ Значения по умолчанию для новых чатов</b>

        🤖 Модель · <code>\(defs.model)</code>
        📝 История · <b>\(defs.historyLength) сообщ.</b>
        🎭 Роль:
        <blockquote expandable>\(defs.role)</blockquote>

        <i>Применяются к новым чатам и при /reset.</i>
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderAdminUsers(chatKey: ChatKey, username: String?) async -> (String, InlineKeyboardMarkup) {
        guard let invoker = username?.lowercased() else {
            return ("У вас не задан @username.", InlineKeyboardMarkup(inline_keyboard: [[menuButton("← Назад", action: "nav:admin")]]))
        }
        let users = await state.licensedUsers(ownerUsername: invoker)

        var rows: [[InlineKeyboardButton]] = [
            [menuButton("🔗 Пригласительная ссылка", action: "nav:admininvite")],
            [menuButton("➕ Добавить @username", action: "tenant:adduserprompt")],
        ]
        for (i, user) in users.prefix(40).enumerated() {
            rows.append([
                menuButton("@\(user)", action: "noop"),
                menuButton("🗑 Удалить", action: "tenant:rmuser:\(i)"),
            ])
        }
        rows.append([menuButton("← К админ-панели", action: "nav:admin")])

        let listText: String
        if users.isEmpty {
            listText = "<i>нет добавленных пользователей</i>"
        } else {
            listText = users.map { "• @\($0)" }.joined(separator: "\n")
        }
        let text = """
        <b>👥 Лицензированные пользователи @\(invoker)</b> (\(users.count))

        \(listText)

        <i>Кнопка выше — добавить @username. Команда — <code>/tenant adduser @username</code>.</i>
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderSuperTenants(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let rows = await state.tenantStats()

        var lines: [String] = ["<b>🏢 Tenants</b> (\(rows.count))"]
        if rows.isEmpty {
            lines.append("<i>нет</i>")
        } else {
            for row in rows {
                let mark = row.isSuperAdmin ? "🛡" : "🛠"
                let realStr = String(format: "$%.4f", row.usage.totalCost)
                let billedStr = String(format: "$%.4f", await state.billedCost(of: row.usage))
                let tokens = Int(row.usage.totalTokens)
                lines.append("\n\(mark) <b>@\(row.username)</b>")
                lines.append("  чатов <b>\(row.chatCount)</b> · юзеров <b>\(row.licensedUserCount)</b> · запросов <b>\(row.usage.generationCount)</b> · ток. <b>\(tokens)</b>")
                lines.append("  💵 реально <b>\(realStr)</b> · клиентам <b>\(billedStr)</b>")
            }
        }

        if !rows.isEmpty {
            lines.append("\n<i>Нажмите на tenant — подписка и управление.</i>")
        }

        var buttons: [[InlineKeyboardButton]] = [[menuButton("➕ Зарегистрировать tenant", action: "stenant:add")]]
        for row in rows {
            var btnRow = [menuButton("\(row.isSuperAdmin ? "🛡" : "🛠") @\(row.username)", action: "stenant:info:\(row.username)")]
            if !row.isSuperAdmin {
                btnRow.append(menuButton("🗑", action: "stenant:rm:\(row.username)"))
            }
            buttons.append(btnRow)
        }
        buttons.append([menuButton("🛡 Суперадмины", action: "nav:superadmins")])
        buttons.append([menuButton("← К супер-админу", action: "nav:superadmin")])

        return (lines.joined(separator: "\n"), InlineKeyboardMarkup(inline_keyboard: buttons))
    }

    private func renderSuperTenantInfo(username: String) async -> (String, InlineKeyboardMarkup) {
        let target = username.lowercased()
        guard let row = await state.tenantStats().first(where: { $0.username == target }) else {
            return (
                "Tenant @\(target) не найден.",
                InlineKeyboardMarkup(inline_keyboard: [[menuButton("← К tenants", action: "nav:supertenants")]])
            )
        }

        let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy"
        let subLine: String
        if let until = row.paidUntil {
            subLine = row.isActive
                ? "💳 Подписка · до <b>\(f.string(from: until))</b>"
                : "💳 Подписка · <b>⛔ истекла \(f.string(from: until))</b>"
        } else {
            subLine = "💳 Подписка · <b>бессрочная</b>"
        }
        let realStr = String(format: "$%.4f", row.usage.totalCost)
        let billedStr = String(format: "$%.4f", await state.billedCost(of: row.usage))

        let text = """
        <b>🏢 Tenant @\(row.username)</b>\(row.isSuperAdmin ? " · 🛡 суперадмин" : "")

        \(subLine)
        Чатов · <b>\(row.chatCount)</b> · юзеров · <b>\(row.licensedUserCount)</b>
        📈 запросов <b>\(row.usage.generationCount)</b> · токенов <b>\(Int(row.usage.totalTokens))</b>
        💵 реально <b>\(realStr)</b> · клиентам <b>\(billedStr)</b>
        """

        var buttons: [[InlineKeyboardButton]] = [
            [menuButton("⏳ Продлить +\(ChatContextStore.subscriptionDays) дн.", action: "stenant:ext:\(row.username)")],
            [menuButton("♾ Бессрочно", action: "stenant:unlim:\(row.username)"),
             menuButton("⛔ Истечь сейчас", action: "stenant:exp:\(row.username)")],
        ]
        if !row.isSuperAdmin {
            buttons.append([menuButton("🗑 Удалить tenant", action: "stenant:rm:\(row.username)")])
        }
        buttons.append([menuButton("← К tenants", action: "nav:supertenants")])
        return (text, InlineKeyboardMarkup(inline_keyboard: buttons))
    }

    private func renderSuperBalances(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let balances = await state.allBalances()
        let markupPct = await state.markupPercent()
        func usd(_ v: Double) -> String { String(format: "$%.4f", v) }

        var lines = ["<b>💰 Балансы (pay-as-you-go)</b> (\(balances.count)) · наценка <b>\(markupPct)%</b>", ""]
        if balances.isEmpty {
            lines.append("<i>Кошельков нет. Баланс — оплата платных моделей по факту, без подписки: начислите сумму, бот списывает стоимость каждого ответа с наценкой.</i>")
        } else {
            var totalBalance = 0.0, totalBilled = 0.0, totalReal = 0.0
            for entry in balances {
                let w = entry.wallet
                totalBalance += w.balanceUsd
                totalBilled += w.spentBilledUsd
                totalReal += w.spentRealUsd
                lines.append("• <b>@\(entry.username)</b> · остаток <b>\(usd(w.balanceUsd))</b>")
                lines.append("  списано \(usd(w.spentBilledUsd)) · реально \(usd(w.spentRealUsd)) · маржа <b>\(usd(w.spentBilledUsd - w.spentRealUsd))</b>")
            }
            lines.append("")
            lines.append("<b>Итого</b> · остатки \(usd(totalBalance)) · маржа <b>\(usd(totalBilled - totalReal))</b>")
        }

        var buttons: [[InlineKeyboardButton]] = [[menuButton("➕ Начислить / списать", action: "sbal:add")]]
        for entry in balances.prefix(30) {
            buttons.append([
                menuButton("@\(entry.username) · \(usd(entry.wallet.balanceUsd))", action: "noop"),
                menuButton("🗑", action: "sbal:rm:\(entry.username)"),
            ])
        }
        buttons.append([menuButton("💹 Наценка · \(markupPct)%", action: "markup:set")])
        buttons.append([menuButton("← К супер-админу", action: "nav:superadmin")])
        return (lines.joined(separator: "\n"), InlineKeyboardMarkup(inline_keyboard: buttons))
    }

    private func renderSuperAdmins(chatKey: ChatKey, username: String?) async -> (String, InlineKeyboardMarkup) {
        let supers = await state.listSuperAdmins()
        let isRoot = await state.isRootSuperAdmin(username: username)

        var rows: [[InlineKeyboardButton]] = []
        if isRoot {
            rows.append([menuButton("➕ Добавить @username", action: "sa:add")])
            for s in supers {
                rows.append([
                    menuButton("@\(s)", action: "noop"),
                    menuButton("🗑 Удалить", action: "sa:rm:\(s)"),
                ])
            }
        }
        rows.append([menuButton("← К супер-админу", action: "nav:superadmin")])

        let listText = supers.isEmpty ? "<i>нет</i>" : supers.map { "• @\($0)" }.joined(separator: "\n")
        let footer = isRoot
            ? ""
            : "\n\n<i>Только главный суперадмин может изменять список.</i>"
        let text = """
        <b>🛡 Суперадмины</b> (\(supers.count))

        \(listText)\(footer)
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderSuperSimulate(chatKey: ChatKey, username: String?) async -> (String, InlineKeyboardMarkup) {
        let role = await state.simulatedRole(username: username)
        let label: String
        switch role {
        case .admin: label = "админ"
        case .regularUser: label = "обычный пользователь"
        case nil: label = "выкл (суперадмин)"
        }

        let rows: [[InlineKeyboardButton]] = [
            [menuButton((role == .admin ? "✓ " : "") + "🛠 Админ", action: "sim:admin")],
            [menuButton((role == .regularUser ? "✓ " : "") + "👤 Обычный пользователь", action: "sim:user")],
            [menuButton((role == nil ? "✓ " : "") + "⛔ Выключить", action: "sim:off")],
            [menuButton("🧪 Тест покупки", action: "sim:buy")],
            [menuButton("← К супер-админу", action: "nav:superadmin")],
        ]

        let text = """
        <b>🎭 Симуляция роли</b>

        Текущий режим · <b>\(label)</b>

        <i>Только в текущем процессе бота, не сохраняется при рестарте.</i>
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderAdminInvite(chatKey: ChatKey, username: String?) async -> (String, InlineKeyboardMarkup) {
        guard let invoker = username?.lowercased() else {
            return ("У вас не задан @username.", InlineKeyboardMarkup(inline_keyboard: [[menuButton("← Назад", action: "nav:admin")]]))
        }
        guard await state.isTenant(username: invoker) else {
            return (
                "Лицензия не активна — оформите доступ: /buy",
                InlineKeyboardMarkup(inline_keyboard: [[menuButton("← К админ-панели", action: "nav:admin")]])
            )
        }

        let token = await state.inviteToken(owner: invoker)
        var rows: [[InlineKeyboardButton]] = []
        let text: String
        if let token {
            let link = "https://t.me/\(botUsername)?start=inv_\(token)"
            rows.append([InlineKeyboardButton(text: "📨 Открыть ссылку", url: link)])
            rows.append([menuButton("♻️ Перевыпустить (старая сгорит)", action: "tenant:newinvite")])
            text = """
            <b>🔗 Пригласительная ссылка</b>

            <code>\(link)</code>

            Отправьте её любому пользователю: открыв её и нажав Start, он получит доступ к платным моделям за счёт вашей лицензии и появится в списке «Пользователи».
            """
        } else {
            rows.append([menuButton("➕ Создать ссылку", action: "tenant:newinvite")])
            text = """
            <b>🔗 Пригласительная ссылка</b>

            Ссылка ещё не создана. Нажмите кнопку ниже — бот сгенерирует персональную ссылку-приглашение вашей лицензии.
            """
        }
        rows.append([menuButton("← К админ-панели", action: "nav:admin")])
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderSuperChats(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let groups = await state.groupChats()
        let privates = await state.privateChats()
        let uniqueGroupIDs = Array(Set(groups.map(\.chatID))).sorted()
        let uniquePrivateIDs = Array(Set(privates.map(\.chatID))).sorted()

        var rows: [[InlineKeyboardButton]] = []
        for chatID in uniqueGroupIDs.prefix(20) {
            let label = await state.chatDisplayLabel(chatID: chatID)
            rows.append([menuButton("👥 \(label)", action: "sinspect:\(chatID)")])
        }
        for chatID in uniquePrivateIDs.prefix(20) {
            let label = await state.chatDisplayLabel(chatID: chatID)
            rows.append([menuButton("👤 \(label)", action: "sinspect:\(chatID)")])
        }
        rows.append([menuButton("← К супер-админу", action: "nav:superadmin")])

        let truncated = uniqueGroupIDs.count > 20 || uniquePrivateIDs.count > 20
        let text = """
        <b>👁 Чаты бота</b>

        Группы · <b>\(uniqueGroupIDs.count)</b> · личные · <b>\(uniquePrivateIDs.count)</b>

        Нажмите на чат — откроются его настройки, роль и статистика.\(truncated ? "\nПоказаны первые 20 каждого типа; полный список — /chats, детали — /inspect <chatID>." : "")
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderInspect(chatID: Int) async -> (String, InlineKeyboardMarkup) {
        let label = await state.chatDisplayLabel(chatID: chatID)
        let owner = await state.chatOwner(chatID: chatID)
        let keys = await state.existingContextKeys(chatID: chatID)

        var lines = ["<b>👁 \(label)</b> · <code>\(chatID)</code>"]
        lines.append(owner.map { "Лицензия · @\($0)" } ?? "Лицензия · <i>нет (бесплатный)</i>")

        if keys.isEmpty {
            lines.append("\n<i>Контекст ещё не создан.</i>")
        }
        for key in keys.prefix(5) {
            guard let help = await state.peekHelp(chatKey: key) else { continue }
            lines.append("")
            lines.append(key.threadID == 0 ? "<b>Основной тред</b>" : "<b>Топик \(key.threadID)</b>")
            lines.append("🤖 <code>\(help.model)</code> · 🌡 \(Self.formatTemp(help.temp)) · 📝 \(help.maxHistory)")
            let realStr = String(format: "$%.4f", help.cumulativeUsage.totalCost)
            let billedStr = String(format: "$%.4f", await state.billedCost(of: help.cumulativeUsage))
            lines.append("📈 запросов \(help.cumulativeUsage.generationCount) · токенов \(Int(help.cumulativeUsage.totalTokens)) · реально \(realStr) · клиентам \(billedStr)")
            let rolePreview = help.role.count > 250 ? String(help.role.prefix(250)) + "…" : help.role
            lines.append("🎭 <blockquote expandable>\(rolePreview)</blockquote>")
        }
        if keys.count > 5 {
            lines.append("\n<i>…и ещё \(keys.count - 5) топиков — /inspect \(chatID)</i>")
        }

        let rows: [[InlineKeyboardButton]] = [
            [menuButton("← К списку чатов", action: "nav:superchats")],
        ]
        return (lines.joined(separator: "\n"), InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderSuperAds(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let campaigns = await state.adCampaigns()

        var lines = ["<b>📣 Реклама</b> (\(campaigns.count))", ""]
        if campaigns.isEmpty {
            lines.append("<i>Кампаний нет. Реклама показывается в чатах без активной платной лицензии — после ответа бота, с настраиваемой частотой и лимитом показов.</i>")
        } else {
            for c in campaigns {
                let status = c.enabled ? (c.isRunning() ? "🟢" : "🟡 (вне окна/лимита)") : "⚪ выкл"
                var line = "\(status) <b>\(c.id)</b> · каждые \(c.everyNReplies) отв. · пауза \(c.minIntervalSeconds / 60) мин"
                if let target = c.totalImpressionsTarget {
                    line += " · \(c.impressionsUsed)/\(target)"
                } else {
                    line += " · показов \(c.impressionsUsed)"
                }
                lines.append(line)
                let preview = c.text.count > 100 ? String(c.text.prefix(100)) + "…" : c.text
                lines.append("<blockquote expandable>\(preview)</blockquote>")
            }
        }
        lines.append("")
        lines.append("<i>Тонкая настройка — команда /ads (частота, лимиты с пейсингом, кнопка-ссылка). Проверить показ: /simulate user и написать боту.</i>")

        var rows: [[InlineKeyboardButton]] = [[menuButton("➕ Новое объявление", action: "ads:add")]]
        for c in campaigns.prefix(15) {
            rows.append([
                menuButton("\(c.enabled ? "⏸" : "▶️") \(c.id)", action: "ads:toggle:\(c.id)"),
                menuButton("🗑 \(c.id)", action: "ads:rm:\(c.id)"),
            ])
        }
        rows.append([menuButton("← К супер-админу", action: "nav:superadmin")])
        return (lines.joined(separator: "\n"), InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderAdminHelp() -> (String, InlineKeyboardMarkup) {
        let rows: [[InlineKeyboardButton]] = [
            [menuButton("← К админ-панели", action: "nav:admin")],
        ]
        return (Self.adminHelpText, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderSuperAdminHelp() -> (String, InlineKeyboardMarkup) {
        let rows: [[InlineKeyboardButton]] = [
            [menuButton("← К супер-админу", action: "nav:superadmin")],
        ]
        return (Self.superAdminHelpText, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    static let adminHelpText: String = """
<b>🛠 Справка администратора</b>

Все админ-задачи доступны кнопками в этой панели <b>и</b> командами. Кнопки — для удобства, команды — для скорости.

<b>━━━ 📌 Лицензия ━━━</b>

UI: «📌 Привязать/Отвязать», «🔗 Пригласительная ссылка», «📋 Чаты лицензии» → «📥 Привязать чат по ID», «👥 Пользователи» → «➕ Добавить @username».

<b>Самый простой способ дать доступ</b> — пригласительная ссылка: <code>/tenant invite</code>. Кто откроет её — получает платные модели за ваш счёт, без всяких ID.

<code>/tenant claim</code> — привязать этот чат к вашей лицензии
<code>/tenant release</code> — отвязать этот чат
<code>/tenant assign @username &lt;chatID&gt;</code> — привязать чат вручную
<code>/tenant unassign &lt;chatID&gt;</code> — отвязать чат
<code>/tenant chats</code> — чаты лицензии
<code>/tenant adduser @username</code> — дать @пользователю доступ
<code>/tenant removeuser @username</code> — отозвать доступ
<code>/tenant users</code> — лицензированные пользователи
<code>/chatid</code> — ID и статус текущего чата (работает у всех)

<b>━━━ 💳 Подписка ━━━</b>

Подписка действует \(ChatContextStore.subscriptionDays) дней с момента оплаты, продление — снова /buy (срок прибавляется к текущему). Статус виден в шапке админ-панели. Когда подписка истекает, ваши чаты и пользователи временно теряют платные модели — настройки и списки сохраняются, после продления всё возвращается.

<b>━━━ 👥 Whitelist ━━━</b>

UI: «👤 Whitelist» в админ-панели — ➕ добавить ID / 🗑 убрать.

<code>/whitelist add &lt;ID&gt;</code>
<code>/whitelist remove &lt;ID&gt;</code>
<code>/whitelist list</code>

<b>━━━ ⚙️ Дефолты для новых чатов ━━━</b>

UI: «⚙️ Дефолты» в админ-панели — кнопки правят модель, длину истории и роль.

<code>/defaults</code> — показать текущие
<code>/defaults model &lt;id&gt;</code>
<code>/defaults role &lt;текст&gt;</code>
<code>/defaults historylength &lt;1–50&gt;</code>

<b>━━━ 📋 Пресеты меню ━━━</b>

UI: «🤖 Пресеты моделей», «🎭 Ролей», «🌡 Темп.», «📝 Истории» — кнопки в админ-панели или в самих разделах меню.

Типы: <code>model</code>, <code>temp</code>, <code>history</code>, <code>role</code>.
<code>/presets &lt;тип&gt; add &lt;label&gt; | &lt;value&gt;</code>
<code>/presets &lt;тип&gt; remove &lt;value&gt;</code>
<code>/presets &lt;тип&gt; list</code>
<blockquote>/presets model add GPT-4o | openai/gpt-4o</blockquote>

<b>━━━ 📋 Просмотр ━━━</b>

<code>/chats</code> — все чаты бота
<code>/users</code> — пользователи в личке
"""

    static let superAdminHelpText: String = """
<b>🛡 Справка супер-админа</b>

Любая настройка имеет и кнопку, и команду. Списки кнопок — в соответствующих разделах меню.

<b>━━━ 🛡 Суперадмины ━━━</b>

UI: «🛡 Суперадмины» в супер-меню — ➕ добавить / 🗑 убрать (только главный суперадмин).

<code>/superadmin add @username</code>
<code>/superadmin remove @username</code>
<code>/superadmin list</code>

<b>━━━ 🏢 Tenants и лицензии ━━━</b>

UI: «🏢 Tenants и статистика» — ➕ зарегистрировать / 🗑 удалить; нажмите на tenant — продление, бессрочная подписка, немедленное истечение.

<code>/tenant list</code> — все tenants
<code>/tenant stats</code> — статистика и подписки (токены, $, сроки)
<code>/tenant add @username</code> — зарегистрировать вручную (бессрочно)
<code>/tenant remove @username</code> — удалить tenant
<code>/tenant extend @username &lt;дней&gt;</code> — продлить подписку
<code>/tenant unlimited @username</code> — сделать бессрочной
<code>/tenant expire @username</code> — завершить немедленно
<code>/tenant assign @username &lt;chatID&gt;</code> — привязать чат
<code>/tenant unassign &lt;chatID&gt;</code> — отвязать чат

<b>━━━ 👁 Прозрачность ━━━</b>

UI: «👁 Чаты бота» в супер-меню — список чатов с названиями, по нажатию — настройки, роль и статистика чата.

<code>/chats</code> — все чаты с ID и названиями
<code>/inspect &lt;chatID&gt;</code> — настройки/роль/статистика любого чата
<code>/chatid</code> — ID текущего чата

<b>━━━ 💰 Балансы и наценка ━━━</b>

UI: «💰 Балансы» в супер-меню — начислить/списать/удалить кошельки; «💹 Наценка» — изменить процент.

Второй способ монетизации: пользователь платит за каждый ответ со своего баланса по ценам с наценкой (подписка чата имеет приоритет — тогда баланс не трогается).

<code>/tenant markup &lt;процент&gt;</code> — наценка на цены моделей (по умолчанию 30%)
<code>/balance add @user 5</code> — начислить $5 (себе тоже можно)
<code>/balance set @user 10</code> · <code>/balance remove @user</code>
<code>/balance list</code> — все кошельки: остаток, списано, реальный расход, маржа

Пользователь видит цены и списания уже с наценкой (футер, /balance, меню); реальные цифры — только вам.

<b>━━━ 📣 Реклама ━━━</b>

UI: «📣 Реклама» в супер-меню — создать/включить/удалить кампании.
Показы идут только в чатах <b>без активной платной лицензии</b>, после ответа бота.

<code>/ads</code> — список кампаний и вся справка
<code>/ads add &lt;текст&gt;</code> — создать
<code>/ads freq &lt;id&gt; &lt;N&gt; [мин]</code> — каждые N ответов, пауза в минутах
<code>/ads limit &lt;id&gt; &lt;показов&gt; [дней]</code> — лимит показов, равномерно на период
<code>/ads button &lt;id&gt; &lt;текст&gt; | &lt;url&gt;</code> — кнопка-ссылка

<b>━━━ 💫 Stars ━━━</b>

UI: «💫 Stars» в супер-меню.
<code>/tenant price &lt;Stars&gt;</code> — цена в Stars (0 = отключить)

<b>━━━ 🪙 Крипто ━━━</b>

UI: «🪙 Крипто» в супер-меню — все настройки кнопками. «🪙 Открытые счета» — список счетов.

<code>/tenant cryptoprice &lt;USD&gt;</code> — цена в долларах (0 = отключить)
<code>/tenant cryptomode delta|unique</code> — режим идентификации платежей
<code>/tenant cryptoinvoices</code> — открытые счета

<i>delta</i> — один адрес на сеть, плательщики различаются по уникальной сумме.
<i>unique</i> — каждому счёту выдаётся свой адрес из пула (сумма у всех одинаковая).

<b>Адреса (режим delta):</b>
<code>/tenant cryptoaddr &lt;ton|bsc|eth|tron&gt; &lt;addr&gt;</code>
<code>/tenant cryptoaddr list</code>

<b>Пул адресов (режим unique):</b>
<code>/tenant cryptopool add &lt;chain&gt; &lt;addr&gt;</code>
<code>/tenant cryptopool remove &lt;chain&gt; &lt;index&gt;</code>
<code>/tenant cryptopool list</code>

<b>━━━ 💳 Карта (эквайринг) ━━━</b>

UI: «💳 Карта» в супер-меню — токен провайдера, валюта (RUB/USD/EUR), цена. Всё кнопками, команд нет.

Токен выдаёт @BotFather после подключения провайдера (ЮKassa, Stripe…): /mybots → бот → Bot Settings → Payments. Токен с <code>:TEST:</code> — тестовый режим (карта 4242 4242 4242 4242). Подробная инструкция — PAYMENTS_SETUP.md.

<b>━━━ 🆓 Бесплатные модели ━━━</b>

UI: «🆓 Бесплатные модели» в супер-меню — ➕ по ID, ☐/🆓 у пресетов.

<code>/tenant freemodels add|remove|list|available &lt;id&gt;</code>

<b>━━━ 🎭 Симуляция роли ━━━</b>

UI: «🎭 Симуляция» в супер-меню — кнопки админ/обычный/выкл + «🧪 Тест покупки».

<code>/simulate admin|user|off|status</code>
<code>/simulate buy</code> — тест покупки: активация подписки без оплаты (откат: /tenant remove)

<b>━━━ 🧪 Команды админа ━━━</b>

Также доступны: /defaults, /presets, /whitelist, /chats, /users, /reset_stats.
"""

    // MARK: - Preset management renderers

    private func renderPresetManagement(category: PresetCategory, chatKey: ChatKey, canManageGlobal: Bool) async -> (String, InlineKeyboardMarkup) {
        let globalPresets = await state.presets(for: category, chatID: chatKey.chatID)
        let chatPresets = await state.chatPresets(category: category, chatKey: chatKey)
        let modelPrices = category == .model ? await state.openRouterModelPrices() : [:]
        let priceMultiplier = await state.priceMultiplier()

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
            text += "💬 <b>Пресеты чата</b> — <i>нет</i>"
        } else {
            text += "💬 <b>Пресеты чата</b>\n"
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
        let formatLine = category == .model
            ? "<code>Название | Значение | Провайдер</code>\n<i>Провайдер (роутинг OpenRouter) — опционален.</i>"
            : "<code>Название | Значение</code>"
        switch kind {
        case .add:
            text = """
            <b>➕ Новый пресет · \(scopeLabel) · \(category.displayName)</b>

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

    // MARK: - Helpers

    private func processAdminPendingInput(text: String, chatKey: ChatKey, username: String?) async -> Bool {
        guard let pending = await state.consumeAdminPendingInput(chatKey: chatKey) else { return true }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isAdmin = await state.isAdmin(username: username, chatID: chatKey.chatID)
        let isSuper = await state.isSuperAdmin(username: username)
        let isRoot = await state.isRootSuperAdmin(username: username)

        func normalizeUsername(_ raw: String) -> String {
            raw.hasPrefix("@") ? String(raw.dropFirst()) : raw
        }

        var toast: String = ""
        var resumePage: MenuPage = .adminPanel

        switch pending.kind {
        case .whitelistAdd:
            guard isAdmin else { toast = "🔒 Только администратор"; resumePage = .adminPanel; break }
            if let id = Int(trimmed) {
                await state.addToWhitelist(userID: id, chatID: chatKey.chatID)
                toast = "✓ \(id) в whitelist"
            } else {
                toast = "⚠️ Нужен целочисленный ID"
            }
            resumePage = .adminWhitelist

        case .defaultsModel:
            guard isAdmin, !trimmed.isEmpty else { toast = "⚠️ ID модели пуст"; resumePage = .adminDefaults; break }
            let new = await state.setDefaultModel(trimmed, chatID: chatKey.chatID)
            toast = "✓ Модель по умолчанию: \(new)"
            resumePage = .adminDefaults

        case .defaultsRole:
            guard isAdmin, !trimmed.isEmpty else { toast = "⚠️ Текст пуст"; resumePage = .adminDefaults; break }
            _ = await state.setDefaultRole(trimmed, chatID: chatKey.chatID)
            toast = "✓ Роль по умолчанию обновлена"
            resumePage = .adminDefaults

        case .defaultsHistory:
            if let n = Int(trimmed), (1...50).contains(n) {
                _ = await state.setDefaultHistoryLength(n, chatID: chatKey.chatID)
                toast = "✓ Длина истории по умолчанию: \(n)"
            } else {
                toast = "⚠️ Нужно число 1–50"
            }
            resumePage = .adminDefaults

        case .tenantAssignChat:
            guard let owner = pending.payload else { toast = "Нет владельца"; resumePage = .adminChats; break }
            if !isSuper, owner.lowercased() != username?.lowercased() {
                toast = "🔒 Можно привязать только к своей лицензии"
            } else if let chatID = Int(trimmed) {
                let ok = await state.assignChat(chatID: chatID, to: owner)
                toast = ok ? "✓ Чат \(chatID) привязан" : "Tenant не найден"
            } else {
                toast = "⚠️ Нужен целочисленный chatID"
            }
            resumePage = .adminChats

        case .tenantAddUser:
            guard let owner = pending.payload else { toast = "Нет владельца"; resumePage = .adminUsers; break }
            if !isSuper, owner.lowercased() != username?.lowercased() {
                toast = "🔒 Можно добавлять только в свою лицензию"
            } else {
                let target = normalizeUsername(trimmed)
                if target.isEmpty {
                    toast = "⚠️ Нужен @username"
                } else {
                    let ok = await state.addLicensedUser(ownerUsername: owner, target: target)
                    toast = ok ? "✓ @\(target) лицензирован" : "Уже в списке или нет лицензии"
                }
            }
            resumePage = .adminUsers

        case .tenantRegister:
            guard isSuper else { toast = "🔒 Только суперадмин"; resumePage = .superTenants; break }
            let target = normalizeUsername(trimmed)
            if target.isEmpty {
                toast = "⚠️ Нужен @username"
            } else {
                await state.registerTenant(username: target)
                toast = "✓ Tenant @\(target) создан"
            }
            resumePage = .superTenants

        case .tenantRemove:
            guard isSuper else { toast = "🔒 Только суперадмин"; resumePage = .superTenants; break }
            let target = normalizeUsername(trimmed)
            let removed = await state.removeTenant(username: target)
            toast = removed ? "✓ Tenant @\(target) удалён" : "Нельзя удалить"
            resumePage = .superTenants

        case .superAdminAdd:
            guard isRoot else { toast = "🔒 Только главный суперадмин"; resumePage = .superAdmins; break }
            let target = normalizeUsername(trimmed)
            if target.isEmpty {
                toast = "⚠️ Нужен @username"
            } else {
                let ok = await state.addSuperAdmin(target: target)
                toast = ok ? "✓ @\(target) — суперадмин" : "Уже суперадмин"
            }
            resumePage = .superAdmins

        case .superAdminRemove:
            guard isRoot else { toast = "🔒 Только главный суперадмин"; resumePage = .superAdmins; break }
            let target = normalizeUsername(trimmed)
            let ok = await state.removeSuperAdmin(target: target)
            toast = ok ? "✓ @\(target) больше не суперадмин" : "Нельзя удалить"
            resumePage = .superAdmins

        case .adAddText:
            guard isSuper else { toast = "🔒 Только суперадмин"; resumePage = .superAdmin; break }
            guard !trimmed.isEmpty else { toast = "⚠️ Пустой текст"; resumePage = .superAds; break }
            let campaign = AdCampaign.new(text: trimmed)
            await state.upsertAdCampaign(campaign)
            toast = "✓ Кампания \(campaign.id) создана. Настройки: /ads"
            resumePage = .superAds

        case .chatCustomRole:
            resumePage = .role
            if trimmed.isEmpty {
                toast = "⚠️ Текст роли пуст"
            } else {
                _ = await state.setRoleAndResetHistory(chatKey: chatKey, role: trimmed + formatOptions)
                toast = "✓ Роль обновлена. История очищена."
            }

        case .chatCustomModel:
            resumePage = .model
            let comps = trimmed.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let modelID = comps.first ?? ""
            let providerRouting = comps.count > 1 && !comps[1].isEmpty ? comps[1] : nil
            if modelID.isEmpty {
                toast = "⚠️ ID модели пуст"
            } else {
                let hasAccess = await state.hasFullModelAccess(username: username, chatID: chatKey.chatID)
                if !hasAccess, let eff = await state.effectiveFreeModelIDs(), !eff.contains(modelID) {
                    toast = "⭐ <b>\(modelID)</b> — модель с полным доступом. Купить: /buy"
                } else {
                    _ = await state.setModelAndResetHistory(chatKey: chatKey, newModel: modelID, providerRouting: providerRouting)
                    await modelPriceMonitor?.refreshPricesIfNeeded(for: modelID)
                    toast = "✓ Модель: <code>\(modelID)</code>" + (providerRouting.map { " · \($0)" } ?? "") + ". История очищена."
                }
            }

        case .chatCustomTemp:
            resumePage = .temp
            if let temp = Float(trimmed.replacingOccurrences(of: ",", with: ".")), (0.0...2.0).contains(temp) {
                await state.setTemperature(chatKey: chatKey, value: temp)
                toast = "✓ Темп: <b>\(Self.formatTemp(temp))</b> — \(Self.tempBucket(temp))"
            } else {
                toast = "⚠️ Нужно число от 0.0 до 2.0"
            }

        case .chatCustomHistory:
            resumePage = .history
            if let n = Int(trimmed), (1...50).contains(n) {
                await state.setMaxHistory(chatKey: chatKey, newMax: n)
                toast = "✓ Длина истории: <b>\(n) сообщ.</b>"
            } else {
                toast = "⚠️ Нужно число от 1 до 50"
            }

        case .markupPercent:
            resumePage = .superAdmin
            guard isSuper else { toast = "🔒 Только суперадмин"; break }
            if let pct = Int(trimmed), (0...500).contains(pct) {
                await state.setMarkupPercent(pct)
                toast = "✓ Наценка: <b>\(pct)%</b> (множитель ×\(String(format: "%.2f", 1.0 + Double(pct) / 100.0)))"
            } else {
                toast = "⚠️ Нужно число 0–500"
            }

        case .balanceTopUp:
            resumePage = .superBalances
            guard isSuper else { toast = "🔒 Только суперадмин"; break }
            let comps = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if comps.count >= 2,
               let amount = Double(comps[1].replacingOccurrences(of: ",", with: ".")) {
                let target = normalizeUsername(comps[0])
                if target.isEmpty {
                    toast = "⚠️ Нужен @username"
                } else {
                    let wallet = await state.creditBalance(username: target, amountUsd: amount)
                    toast = "✓ Баланс @\(target.lowercased()) · <b>\(String(format: "$%.4f", wallet.balanceUsd))</b>"
                }
            } else {
                toast = "⚠️ Формат: <code>@username сумма</code>, например <code>@user 5</code>"
            }

        case .cardProviderToken:
            resumePage = .superCard
            guard isSuper else { toast = "🔒 Только суперадмин"; break }
            if trimmed == "-" {
                await state.setCardProviderToken(nil)
                toast = "✓ Токен удалён"
            } else if trimmed.isEmpty {
                toast = "⚠️ Пустой токен"
            } else if !trimmed.contains(":") {
                toast = "⚠️ Не похоже на токен BotFather (нет <code>:</code>). Пример: <code>123456789:TEST:...</code>"
            } else {
                await state.setCardProviderToken(trimmed)
                let card = await state.cardConfig()
                toast = "✓ Токен сохранён" + (card.isTestToken ? " (тестовый режим)" : "")
            }

        case .cardPrice:
            resumePage = .superCard
            guard isSuper else { toast = "🔒 Только суперадмин"; break }
            let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
            if let value = Double(normalized), value >= 0 {
                if value == 0 {
                    await state.setCardPriceMinorUnits(nil)
                    toast = "✓ Продажи картой отключены."
                } else {
                    let minorUnits = Int((value * 100).rounded())
                    let card = await state.cardConfig()
                    if minorUnits < card.currency.minMinorUnits {
                        toast = "⚠️ Минимум для \(card.currency.rawValue): \(card.currency.format(minorUnits: card.currency.minMinorUnits))"
                    } else {
                        await state.setCardPriceMinorUnits(minorUnits)
                        toast = "✓ Цена картой: <b>\(card.currency.format(minorUnits: minorUnits))</b>"
                    }
                }
            } else {
                toast = "⚠️ Введите число, например <code>499</code> или <code>4.99</code>, или <code>0</code> для отключения."
            }

        case .simulateAs:
            break
        }

        let (menuText, markup) = await renderPage(resumePage, chatKey: chatKey, username: username)
        try? await telegram.editMessage(.init(chatID: chatKey.chatID, messageID: pending.menuMessageID, text: menuText, replyMarkup: markup))
        if !toast.isEmpty {
            _ = try? await telegram.sendMessage(.init(
                chatID: chatKey.chatID,
                threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                replyTo: nil,
                text: toast,
                replyMarkup: nil
            ))
        }
        return true
    }

    private func sendHistoryDump(chatKey: ChatKey) async {
        let messages = await state.history(chatKey: chatKey)
        let text: String
        if messages.isEmpty {
            text = "📝 История пуста."
        } else {
            var lines: [String] = ["<b>📝 История</b> (\(messages.count))"]
            for msg in messages {
                let roleLabel: String
                switch msg.role {
                case "system": roleLabel = "⚙️"
                case "user": roleLabel = "👤"
                case "assistant": roleLabel = "🤖"
                default: roleLabel = msg.role
                }
                let content: String
                switch msg.content {
                case .text(let t):
                    content = t
                case .parts(let parts):
                    let textParts = parts.compactMap { $0.text }
                    let mediaTags = parts.compactMap { part -> String? in
                        if part.inputImage != nil { return "[изображение]" }
                        if part.inputAudio != nil { return "[аудио]" }
                        if part.inputVideo != nil { return "[видео]" }
                        return nil
                    }
                    content = (textParts.joined(separator: " ") + " " + mediaTags.joined(separator: " ")).trimmingCharacters(in: .whitespaces)
                }
                let limit = 280
                let displayContent: String
                if content.isEmpty {
                    displayContent = "<i>(пусто)</i>"
                } else if content.count > limit {
                    let endIndex = content.index(content.startIndex, offsetBy: limit)
                    displayContent = String(content[..<endIndex]) + "…"
                } else {
                    displayContent = content
                }
                lines.append("\n\(roleLabel) \(displayContent)")
            }
            text = lines.joined(separator: "\n")
        }
        _ = try? await telegram.sendMessage(.init(
            chatID: chatKey.chatID,
            threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
            replyTo: nil,
            text: text,
            replyMarkup: nil
        ))
    }

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

}

extension ServiceProvider: CaseIterable {
    public static var allCases: [ServiceProvider] {
        [.openrouter, .deepseek, .yandex]
    }
}
