import Foundation

// Typed values that follow a menu button: preset editing and the plain
// per-chat settings. One `has*` check per waiting kind picks the applier;
// the kinds behind `AdminPendingInput` live in +AdminInput.swift.

extension BotMenuHandler {
    /// `username` here — and everywhere it is threaded onward — is the
    /// caller's **storage key**, not their raw handle: store lookups are keyed
    /// by userID, and keys round-trip through the username-taking APIs
    /// unchanged. Anything a person reads is resolved through `displayLabel`.
    func processTextInput(text: String, chatKey: ChatKey, userID: Int?, username: String?) async -> Bool {
        let username = userID.map { self.state.userKey(userID: $0) } ?? username
        if text.hasPrefix("/") { return false }

        // A wait belongs to the person who armed it. Without this check a
        // super-admin who tapped "✏️ Изменить цену" in a group swallows the
        // next message from *any* member: no LLM answer, an out-of-nowhere
        // "🔒 Только суперадмин…", and the wait is spent — which reads as the
        // bot being broken. Their message goes on to be answered normally.
        if let owner = await state.pendingInputOwner(chatKey: chatKey), owner != username {
            return false
        }

        if await state.hasPendingStarsPriceInput(chatKey: chatKey) {
            return await applyStarsPriceInput(text: text, chatKey: chatKey, username: username)
        }

        if await state.hasPendingStarsPerUsdInput(chatKey: chatKey) {
            return await applyStarsRateInput(text: text, chatKey: chatKey, username: username)
        }

        if await state.hasPendingCryptoPriceInput(chatKey: chatKey) {
            return await applyCryptoPriceInput(text: text, chatKey: chatKey, username: username)
        }

        if await state.hasPendingCryptoPoolAddInput(chatKey: chatKey) {
            return await applyCryptoPoolInput(text: text, chatKey: chatKey, username: username)
        }

        if await state.hasPendingCryptoAddressInput(chatKey: chatKey) {
            return await applyCryptoAddressInput(text: text, chatKey: chatKey, username: username)
        }

        if await state.hasPendingFreeModelInput(chatKey: chatKey) {
            return await applyFreeModelInput(text: text, chatKey: chatKey, username: username)
        }

        if await state.hasAdminPendingInput(chatKey: chatKey) {
            return await processAdminPendingInput(text: text, chatKey: chatKey, username: username)
        }

        guard await state.hasPendingInput(chatKey: chatKey) else { return false }
        guard let pending = await state.consumePendingInput(chatKey: chatKey) else { return false }

        return await applyPresetInput(pending: pending, text: text, chatKey: chatKey, username: username)
    }

    // MARK: - Prices and payment addresses

    private func applyStarsPriceInput(text: String, chatKey: ChatKey, username: String?) async -> Bool {
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

    private func applyStarsRateInput(text: String, chatKey: ChatKey, username: String?) async -> Bool {
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
        // 0 turns Stars top-ups off without touching the subscription price.
        if let value = Int(trimmed), value >= 0 {
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
                text: value == 0
                    ? "✓ Пополнение баланса через Stars отключено."
                    : "✓ Курс пополнений: <b>\(value) ⭐ за $1</b>",
                replyMarkup: nil
            ))
        } else {
            await state.setPendingStarsPerUsdInput(menuMessageID: menuMessageID, chatKey: chatKey)
            _ = try? await telegram.sendMessage(.init(
                chatID: chatKey.chatID,
                threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                replyTo: nil,
                text: "⚠️ Введите целое число (например <code>77</code>) или <code>0</code>, чтобы отключить пополнения через Stars.",
                replyMarkup: nil
            ))
        }
        return true
    }

    private func applyCryptoPriceInput(text: String, chatKey: ChatKey, username: String?) async -> Bool {
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

    private func applyCryptoPoolInput(text: String, chatKey: ChatKey, username: String?) async -> Bool {
        guard let pending = await state.consumePendingCryptoPoolAddInput(chatKey: chatKey) else { return true }
        guard await state.isSuperAdmin(username: username) else {
            // Swallowing the message without a word is what makes a lost
            // right look like a broken bot.
            await sendPlain(chatKey: chatKey, text: "🔒 Это может изменить только суперадмин.")
            return true
        }
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

    private func applyCryptoAddressInput(text: String, chatKey: ChatKey, username: String?) async -> Bool {
        guard let pending = await state.consumePendingCryptoAddressInput(chatKey: chatKey) else { return true }
        guard await state.isSuperAdmin(username: username) else {
            // Swallowing the message without a word is what makes a lost
            // right look like a broken bot.
            await sendPlain(chatKey: chatKey, text: "🔒 Это может изменить только суперадмин.")
            return true
        }
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

    private func applyFreeModelInput(text: String, chatKey: ChatKey, username: String?) async -> Bool {
        guard let menuMessageID = await state.consumePendingFreeModelInput(chatKey: chatKey) else { return true }
        guard await state.isSuperAdmin(username: username) else {
            // Swallowing the message without a word is what makes a lost
            // right look like a broken bot.
            await sendPlain(chatKey: chatKey, text: "🔒 Это может изменить только суперадмин.")
            return true
        }
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

    // MARK: - Presets ("Название | Значение [| Сервис]")

    private func applyPresetInput(
        pending: PendingInput,
        text: String,
        chatKey: ChatKey,
        username: String?
    ) async -> Bool {
        let canManageGlobal = await state.isAdmin(username: username, chatID: chatKey.chatID)

        if pending.scope == .global, !canManageGlobal {
            _ = try? await telegram.sendMessage(
                .init(
                    chatID: chatKey.chatID,
                    threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                    replyTo: nil,
                    text: "🔒 Общие заготовки может менять только администратор.",
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
                ? "<code>Название | Значение | Сервис</code> (сервис можно не указывать)"
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
            toastText = "✓ Общая заготовка добавлена: \(display)\(providerSuffix)"
        case (.global, .edit(let index)):
            let ok = await state.editPreset(category: pending.category, index: index, display: display, value: value, provider: provider, chatID: chatKey.chatID)
            toastText = ok ? "✓ Обновлён: \(display)\(providerSuffix)" : "⚠️ Заготовка не найдена"
        case (.chat, .add):
            _ = await state.addChatPreset(category: pending.category, chatKey: chatKey, display: display, value: value, provider: provider)
            toastText = "✓ Заготовка чата добавлена: \(display)\(providerSuffix)"
        case (.chat, .edit(let index)):
            let ok = await state.editChatPreset(category: pending.category, chatKey: chatKey, index: index, display: display, value: value, provider: provider)
            toastText = ok ? "✓ Обновлён: \(display)\(providerSuffix)" : "⚠️ Заготовка не найдена"
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

    func clearAllPendingInputs(chatKey: ChatKey) async {
        await state.clearPendingInput(chatKey: chatKey)
        await state.clearPendingStarsPriceInput(chatKey: chatKey)
        await state.clearPendingStarsPerUsdInput(chatKey: chatKey)
        await state.clearPendingFreeModelInput(chatKey: chatKey)
        await state.clearPendingCryptoPriceInput(chatKey: chatKey)
        await state.clearPendingCryptoAddressInput(chatKey: chatKey)
        await state.clearPendingCryptoPoolAddInput(chatKey: chatKey)
        await state.clearAdminPendingInput(chatKey: chatKey)
    }
}
