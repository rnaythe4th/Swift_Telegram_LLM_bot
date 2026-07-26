import Foundation

// Super-admin payment configuration: Stars, card acquiring, crypto
// addresses and the pinned free-model list.

extension BotMenuHandler {
    // MARK: - Card admin actions

    func handleCardAdminAction(
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

        case "setrate":
            // Credit packs carry a USD face value; selling them on a card in
            // RUB/EUR needs an explicit rate (roadmap step 2).
            await state.setAdminPendingInput(.init(kind: .cardUsdRate, menuMessageID: message.message_id, payload: nil), chatKey: chatKey)
            let rateCard = await state.cardConfig()
            var preview = ""
            for cents in CreditPack.centsOptions {
                if let minor = rateCard.creditMinorUnits(cents: cents) {
                    preview += "\n\(CreditPack.label(cents: cents)) → <b>\(rateCard.currency.format(minorUnits: minor))</b>"
                }
            }
            let rateText = """
            <b>💳 Курс для пополнения баланса</b>

            Сейчас: <b>\(rateCard.usdRateLabel ?? "не задан")</b>\(preview.isEmpty ? "" : "\n" + preview)

            Введите, сколько \(rateCard.currency.rawValue) стоит <b>$1</b> (например <code>95</code>), или <b>0</b> — не продавать пополнения картой.

            <i>Пакеты пополнения имеют номинал в долларах: сколько заплатили — столько и легло на баланс. Курс должен покрывать вашу комиссию эквайринга.</i>
            """
            let rateMarkup = InlineKeyboardMarkup(inline_keyboard: [
                [menuButton("❌ Отмена", action: "nav:supercard")]
            ])
            try await editOrAnswer(callback: callback, message: message, text: rateText, markup: rateMarkup)

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

    func handleCryptoAdminAction(
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
                let sorted = invoices.sorted { $0.createdAt < $1.createdAt }
                for inv in sorted.prefix(20) {
                    let amount = CryptoAmountFormatter.format(atomic: inv.exactAmountAtomic, decimals: inv.asset.decimals)
                    let received = CryptoAmountFormatter.format(atomic: inv.accumulatedAtomic, decimals: inv.asset.decimals)
                    text += "\n• \(await state.displayLabel(forKey: inv.username)) · \(inv.asset.displayLabel) · \(received)/\(amount) \(inv.asset.symbol) · \(inv.status.rawValue)"
                }
                if invoices.count > 20 {
                    text += "\n\n<i>Показаны первые 20 из \(invoices.count) — полный список /tenant cryptoinvoices.</i>"
                }
            }
            let markup = InlineKeyboardMarkup(inline_keyboard: [
                [menuButton("🪙 К настройкам крипты", action: "nav:supercrypto")],
                [menuButton("← К супер-админу", action: "nav:superadmin")],
            ])
            try await editOrAnswer(callback: callback, message: message, text: text, markup: markup)

        default:
            try await showPage(.superCrypto, chatKey: chatKey, callback: callback, message: message)
        }
    }

    func renderSuperStars(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
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

        <b>Пополнение баланса:</b>
        \(rate > 0 ? "Курс: <b>\(rate) ⭐ за $1</b>\n\(packLine)" : "<b>отключено</b>")

        <i>Цена подписки — Stars за месячный доступ (0 = откл). \
        Курс пополнений задаёт, сколько Stars стоит $1 на балансе, и не зависит \
        от цены подписки (0 = не продавать пополнения через Stars). \
        Telegram платит ~$0.013/⭐, поэтому 77⭐/$ покрывает себестоимость и маржу.</i>
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    func renderSuperCrypto(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
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

    func renderSuperCard(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
        let card = await state.cardConfig()

        var rows: [[InlineKeyboardButton]] = []
        let tokenLabel = card.maskedToken.map { _ in "🔑 Токен провайдера ✓" } ?? "🔑 Ввести токен провайдера"
        var tokenRow: [InlineKeyboardButton] = [menuButton(tokenLabel, action: "card:settoken")]
        if card.providerToken != nil {
            tokenRow.append(menuButton("🗑", action: "card:deltoken"))
        }
        rows.append(tokenRow)
        rows.append([
            menuButton("✏️ Цена подписки", action: "card:setprice"),
            menuButton("💱 Курс пополнений", action: "card:setrate"),
        ])

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
        // Credit top-ups ride on the same token but need their own FX rate, so
        // they can be on while subscription sales are off and vice versa.
        var creditsLine = card.creditsEnabled
            ? "🟢 Пополнение баланса картой <b>включено</b> · \(card.usdRateLabel ?? "")"
            : "🔴 Пополнение баланса картой <b>выключено</b>" + (card.providerToken == nil ? " — нужен токен" : " — задайте курс")
        if card.creditsEnabled {
            let packs = CreditPack.centsOptions.compactMap { cents -> String? in
                guard let minor = card.creditMinorUnits(cents: cents) else { return nil }
                return "\(CreditPack.label(cents: cents)) → \(card.currency.format(minorUnits: minor))"
            }
            if !packs.isEmpty { creditsLine += "\n<i>\(packs.joined(separator: " · "))</i>" }
        }

        let text = """
        <b>💳 Оплата картой (эквайринг)</b>

        \(statusLine)
        \(creditsLine)

        Токен провайдера: \(tokenLine)
        Валюта: <b>\(card.currency.rawValue)</b>
        Цена подписки: \(priceLine)

        <i>Токен выдаёт @BotFather после подключения платёжного провайдера \
        (ЮKassa, Stripe, Smart Glocal…): Bot Settings → Payments. \
        Инструкция — PAYMENTS_SETUP.md в репозитории.</i>
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    func renderSuperFreeModels(chatKey: ChatKey) async -> (String, InlineKeyboardMarkup) {
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
}
