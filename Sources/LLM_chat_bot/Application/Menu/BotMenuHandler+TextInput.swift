import Foundation

// Typed values that follow a menu button: preset editing and the plain
// per-chat settings. The chat holds one wait (`PendingRequest`), so this is a
// single switch on its kind; the kinds behind `AdminPendingInput` live in
// +AdminInput.swift.

extension BotMenuHandler {
    /// `invoker` here — and everywhere it is threaded onward — is the
    /// caller's **storage key**, not their raw handle: store lookups are keyed
    /// by userID, and keys round-trip through the invoker-taking APIs
    /// unchanged. Anything a person reads is resolved through `displayLabel`.
    func processTextInput(text: String, chatKey: ChatKey, userID: UserID?) async -> Bool {
        let invoker = userID.map { self.state.userKey(userID: $0) }
        if text.hasPrefix("/") { return false }

        guard let pending = await state.pendingRequest(chatKey: chatKey) else { return false }

        // A wait belongs to the person who armed it. Without this check a
        // super-admin who tapped "✏️ Изменить цену" in a group swallows the
        // next message from *any* member: no LLM answer, an out-of-nowhere
        // "🔒 Только суперадмин…", and the wait is spent — which reads as the
        // bot being broken. Their message goes on to be answered normally.
        if let owner = pending.owner, owner != invoker { return false }

        // The value is ours to spend; an invalid one re-arms the same wait.
        _ = await state.consumePending(chatKey: chatKey)
        let handled = await apply(pending, text: text, chatKey: chatKey, invoker: invoker)
        // Whatever the applier re-armed still belongs to the same person —
        // nobody tapped a button in between. A re-armed wait left unowned
        // would swallow the next message from anyone in the group.
        await state.notePendingInputOwner(pending.owner, chatKey: chatKey)
        return handled
    }

    /// Routes a spent wait to the code that understands its value.
    private func apply(
        _ pending: PendingRequest,
        text: String,
        chatKey: ChatKey,
        invoker: UserKey?
    ) async -> Bool {
        let menuMessageID = pending.menuMessageID

        switch pending.kind {
        case .starsPrice:
            return await applyStarsPriceInput(text: text, menuMessageID: menuMessageID, chatKey: chatKey, invoker: invoker)

        case .starsPerUsd:
            return await applyStarsRateInput(text: text, menuMessageID: menuMessageID, chatKey: chatKey, invoker: invoker)

        case .cryptoPrice:
            return await applyCryptoPriceInput(text: text, menuMessageID: menuMessageID, chatKey: chatKey, invoker: invoker)

        case .cryptoPoolAdd(let chain):
            return await applyCryptoPoolInput(text: text, chain: chain, menuMessageID: menuMessageID, chatKey: chatKey, invoker: invoker)

        case .cryptoAddress(let chain):
            return await applyCryptoAddressInput(text: text, chain: chain, menuMessageID: menuMessageID, chatKey: chatKey, invoker: invoker)

        case .freeModel:
            return await applyFreeModelInput(text: text, menuMessageID: menuMessageID, chatKey: chatKey, invoker: invoker)

        case .admin(let admin):
            return await processAdminPendingInput(admin, menuMessageID: menuMessageID, text: text, chatKey: chatKey, invoker: invoker)

        case .preset(let preset):
            return await applyPresetInput(pending: preset, menuMessageID: menuMessageID, text: text, chatKey: chatKey, invoker: invoker)
        }
    }

    // MARK: - Prices and payment addresses

    private func applyStarsPriceInput(text: String, menuMessageID: Int, chatKey: ChatKey, invoker: UserKey?) async -> Bool {
        guard await state.isSuperAdmin(invoker) else {
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
            await refreshMenu(chatKey: chatKey, menuMessageID: menuMessageID, screen: await renderSuperStars(chatKey: chatKey))
            _ = try? await telegram.sendMessage(.init(
                chatID: chatKey.chatID,
                threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                replyTo: nil,
                text: confirmText,
                replyMarkup: nil
            ))
        } else {
            await state.setPending(.starsPrice, menuMessageID: menuMessageID, chatKey: chatKey)
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

    private func applyStarsRateInput(text: String, menuMessageID: Int, chatKey: ChatKey, invoker: UserKey?) async -> Bool {
        guard await state.isSuperAdmin(invoker) else {
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
            await refreshMenu(chatKey: chatKey, menuMessageID: menuMessageID, screen: await renderSuperStars(chatKey: chatKey))
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
            await state.setPending(.starsPerUsd, menuMessageID: menuMessageID, chatKey: chatKey)
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

    private func applyCryptoPriceInput(text: String, menuMessageID: Int, chatKey: ChatKey, invoker: UserKey?) async -> Bool {
        guard await state.isSuperAdmin(invoker) else {
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
            await refreshMenu(chatKey: chatKey, menuMessageID: menuMessageID, screen: await renderSuperCrypto(chatKey: chatKey))
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
            await refreshMenu(chatKey: chatKey, menuMessageID: menuMessageID, screen: await renderSuperCrypto(chatKey: chatKey))
            _ = try? await telegram.sendMessage(.init(
                chatID: chatKey.chatID,
                threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                replyTo: nil,
                text: confirm,
                replyMarkup: nil
            ))
        } else {
            await state.setPending(.cryptoPrice, menuMessageID: menuMessageID, chatKey: chatKey)
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

    private func applyCryptoPoolInput(
        text: String,
        chain: CryptoChain,
        menuMessageID: Int,
        chatKey: ChatKey,
        invoker: UserKey?
    ) async -> Bool {
        guard await state.isSuperAdmin(invoker) else {
            // Swallowing the message without a word is what makes a lost
            // right look like a broken bot.
            await sendPlain(chatKey: chatKey, text: Texts.superAdminOnlySetting)
            return true
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let toast: String
        if trimmed.isEmpty {
            toast = "⚠️ Адрес пустой."
        } else {
            let added = await state.addCryptoPoolAddress(chain, address: trimmed)
            toast = added
                ? "✓ В пул \(chain.displayName) добавлен: \(trimmed)"
                : "Адрес уже в пуле: \(trimmed)"
        }
        await refreshMenu(chatKey: chatKey, menuMessageID: menuMessageID, screen: await renderSuperCrypto(chatKey: chatKey))
        _ = try? await telegram.sendMessage(.init(
            chatID: chatKey.chatID,
            threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
            replyTo: nil,
            text: toast,
            replyMarkup: nil
        ))
        return true
    }

    private func applyCryptoAddressInput(
        text: String,
        chain: CryptoChain,
        menuMessageID: Int,
        chatKey: ChatKey,
        invoker: UserKey?
    ) async -> Bool {
        guard await state.isSuperAdmin(invoker) else {
            // Swallowing the message without a word is what makes a lost
            // right look like a broken bot.
            await sendPlain(chatKey: chatKey, text: Texts.superAdminOnlySetting)
            return true
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "-" || trimmed.isEmpty {
            await state.setCryptoAddress(chain, address: nil)
        } else {
            await state.setCryptoAddress(chain, address: trimmed)
        }
        await refreshMenu(chatKey: chatKey, menuMessageID: menuMessageID, screen: await renderSuperCrypto(chatKey: chatKey))
        _ = try? await telegram.sendMessage(.init(
            chatID: chatKey.chatID,
            threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
            replyTo: nil,
            text: trimmed == "-" || trimmed.isEmpty
                ? "✓ Адрес для \(chain.displayName) удалён."
                : "✓ Адрес для \(chain.displayName): <code>\(trimmed)</code>",
            replyMarkup: nil
        ))
        return true
    }

    private func applyFreeModelInput(text: String, menuMessageID: Int, chatKey: ChatKey, invoker: UserKey?) async -> Bool {
        guard await state.isSuperAdmin(invoker) else {
            // Swallowing the message without a word is what makes a lost
            // right look like a broken bot.
            await sendPlain(chatKey: chatKey, text: Texts.superAdminOnlySetting)
            return true
        }
        let modelID = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !modelID.isEmpty {
            let added = await state.addFreeModel(modelID)
            let toast = added ? "✓ Добавлено: \(modelID)" : "Уже в списке: \(modelID)"
            await refreshMenu(chatKey: chatKey, menuMessageID: menuMessageID, screen: await renderSuperFreeModels(chatKey: chatKey))
            _ = try? await telegram.sendMessage(.init(
                chatID: chatKey.chatID,
                threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                replyTo: nil,
                text: toast,
                replyMarkup: nil
            ))
        } else {
            await state.setPending(.freeModel, menuMessageID: menuMessageID, chatKey: chatKey)
        }
        return true
    }

    // MARK: - Presets ("Название | Значение [| Сервис]")

    private func applyPresetInput(
        pending: PresetInput,
        menuMessageID: Int,
        text: String,
        chatKey: ChatKey,
        invoker: UserKey?
    ) async -> Bool {
        let canManageGlobal = await state.isAdmin(invoker, chatID: chatKey.chatID)

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
            await state.setPending(.preset(pending), menuMessageID: menuMessageID, chatKey: chatKey)
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

        await refreshMenu(
            chatKey: chatKey,
            menuMessageID: menuMessageID,
            screen: await renderPresetManagement(category: pending.category, chatKey: chatKey, canManageGlobal: canManageGlobal)
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
}
