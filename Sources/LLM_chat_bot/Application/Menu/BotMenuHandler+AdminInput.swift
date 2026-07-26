import Foundation

// Typed values behind admin and super-admin buttons: prices, addresses,
// wallet top-ups, reminder schedule, referral rewards.
//
// One dispatcher picks the group by `AdminPendingInputKind`; each group keeps
// its own `switch` so a bare `break` still means "stop, keep what was set".

/// Everything a typed value produces: the toast to send and the page to redraw.
private typealias AdminInputOutcome = (toast: String, page: MenuPage)

extension BotMenuHandler {
    func processAdminPendingInput(text: String, chatKey: ChatKey, username: String?) async -> Bool {
        guard let pending = await state.consumeAdminPendingInput(chatKey: chatKey) else { return true }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isAdmin = await state.isAdmin(username: username, chatID: chatKey.chatID)
        let isSuper = await state.isSuperAdmin(username: username)
        let isRoot = await state.isRootSuperAdmin(username: username)

        let outcome: AdminInputOutcome
        switch pending.kind {
        case .whitelistAdd, .defaultsModel, .defaultsRole, .defaultsHistory,
             .tenantAssignChat, .tenantAddUser:
            outcome = await applyLicenceInput(
                pending: pending,
                trimmed: trimmed,
                chatKey: chatKey,
                username: username,
                isAdmin: isAdmin,
                isSuper: isSuper
            )

        case .tenantRegister, .tenantRemove, .superAdminAdd, .superAdminRemove:
            outcome = await applyRegistryInput(
                pending: pending,
                trimmed: trimmed,
                isSuper: isSuper,
                isRoot: isRoot
            )

        case .adAddText, .selfPromoText, .selfPromoEvery, .selfPromoPause:
            outcome = await applyAdsInput(pending: pending, trimmed: trimmed, isSuper: isSuper)

        case .chatCustomRole, .chatCustomModel, .chatCustomTemp, .chatCustomHistory:
            outcome = await applyChatValueInput(
                pending: pending,
                trimmed: trimmed,
                chatKey: chatKey,
                username: username
            )

        case .markupPercent, .dailyPremiumLimit, .balanceTopUp:
            outcome = await applyEconomyInput(pending: pending, trimmed: trimmed, isSuper: isSuper)

        case .cardProviderToken, .cardUsdRate, .cardPrice:
            outcome = await applyCardInput(pending: pending, trimmed: trimmed, isSuper: isSuper)

        case .reminderDaysBefore, .reminderWinbackDays, .reminderDiscount,
             .reminderOfferHours, .reminderInterval, .reminderWalletDays:
            outcome = await applyReminderInput(pending: pending, trimmed: trimmed, isSuper: isSuper)

        case .onboardingAdd, .onboardingEdit, .referralInviterReward,
             .referralInviteeReward, .referralPaidBonus, .referralCap:
            outcome = await applyGrowthInput(pending: pending, trimmed: trimmed, isSuper: isSuper)

        case .simulateAs:
            // The simulation page acts on buttons only — nothing to apply.
            outcome = (toast: "", page: .adminPanel)
        }

        let (menuText, markup) = await renderPage(outcome.page, chatKey: chatKey, username: username)
        try? await telegram.editMessage(.init(chatID: chatKey.chatID, messageID: pending.menuMessageID, text: menuText, replyMarkup: markup))
        if !outcome.toast.isEmpty {
            _ = try? await telegram.sendMessage(.init(
                chatID: chatKey.chatID,
                threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                replyTo: nil,
                text: outcome.toast,
                replyMarkup: nil
            ))
        }
        return true
    }

    /// `@user` → `user`. The store resolves the storage key itself.
    private func normalizeUsername(_ raw: String) -> String {
        raw.hasPrefix("@") ? String(raw.dropFirst()) : raw
    }

    // MARK: - Admin panel: guests, defaults for new chats, own licence

    private func applyLicenceInput(
        pending: AdminPendingInput,
        trimmed: String,
        chatKey: ChatKey,
        username: String?,
        isAdmin: Bool,
        isSuper: Bool
    ) async -> AdminInputOutcome {
        var toast: String = ""
        var resumePage: MenuPage = .adminPanel

        switch pending.kind {
        case .whitelistAdd:
            guard isAdmin else { toast = "🔒 Только администратор"; resumePage = .adminPanel; break }
            if let id = Int(trimmed) {
                await state.addToWhitelist(userID: id, chatID: chatKey.chatID)
                toast = "✓ \(id) добавлен в гости"
            } else {
                toast = "⚠️ Нужен номер — целое число"
            }
            resumePage = .adminWhitelist

        case .defaultsModel:
            guard isAdmin, !trimmed.isEmpty else { toast = "⚠️ ID модели пуст"; resumePage = .adminDefaults; break }
            let new = await state.setDefaultModel(trimmed, chatID: chatKey.chatID)
            toast = "✓ Модель в новых чатах · \(new)"
            resumePage = .adminDefaults

        case .defaultsRole:
            guard isAdmin, !trimmed.isEmpty else { toast = "⚠️ Текст пуст"; resumePage = .adminDefaults; break }
            _ = await state.setDefaultRole(trimmed, chatID: chatKey.chatID)
            toast = "✓ Роль в новых чатах обновлена"
            resumePage = .adminDefaults

        case .defaultsHistory:
            if let n = Int(trimmed), (1...50).contains(n) {
                _ = await state.setDefaultHistoryLength(n, chatID: chatKey.chatID)
                toast = "✓ Память в новых чатах · \(n) сообщ."
            } else {
                toast = "⚠️ Нужно число 1–50"
            }
            resumePage = .adminDefaults

        case .tenantAssignChat:
            guard let owner = pending.payload else { toast = "Не удалось определить владельца"; resumePage = .adminChats; break }
            if !isSuper, owner.lowercased() != username?.lowercased() {
                toast = "🔒 Включить премиум можно только за свой счёт"
            } else if let chatID = Int(trimmed) {
                let ok = await state.assignChat(chatID: chatID, to: owner)
                toast = ok ? "✓ Премиум включён в чате \(chatID)" : "Премиум не найден"
            } else {
                toast = "⚠️ Номер чата — целое число"
            }
            resumePage = .adminChats

        case .tenantAddUser:
            guard let owner = pending.payload else { toast = "Не удалось определить владельца"; resumePage = .adminUsers; break }
            if !isSuper, owner.lowercased() != username?.lowercased() {
                toast = "🔒 Добавлять гостей можно только к своему премиуму"
            } else {
                let target = normalizeUsername(trimmed)
                if target.isEmpty {
                    toast = "⚠️ Нужен @username"
                } else {
                    let ok = await state.addLicensedUser(ownerUsername: owner, target: target)
                    toast = ok ? "✓ @\(target) добавлен в гости премиума" : "Уже в списке или премиум неактивен"
                }
            }
            resumePage = .adminUsers

        default:
            break
        }

        return (toast, resumePage)
    }

    // MARK: - Tenants and super-admins

    private func applyRegistryInput(
        pending: AdminPendingInput,
        trimmed: String,
        isSuper: Bool,
        isRoot: Bool
    ) async -> AdminInputOutcome {
        var toast: String = ""
        var resumePage: MenuPage = .adminPanel

        switch pending.kind {
        case .tenantRegister:
            guard isSuper else { toast = "🔒 Только суперадмин"; resumePage = .superTenants; break }
            let target = normalizeUsername(trimmed)
            if target.isEmpty {
                toast = "⚠️ Нужен @username"
            } else {
                await state.registerTenant(username: target)
                toast = "✓ Тенант @\(target) создан"
            }
            resumePage = .superTenants

        case .tenantRemove:
            guard isSuper else { toast = "🔒 Только суперадмин"; resumePage = .superTenants; break }
            let target = normalizeUsername(trimmed)
            let removed = await state.removeTenant(username: target)
            toast = removed ? "✓ Тенант @\(target) удалён" : "Нельзя удалить"
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

        default:
            break
        }

        return (toast, resumePage)
    }

    // MARK: - Ads and the built-in self-promo

    private func applyAdsInput(
        pending: AdminPendingInput,
        trimmed: String,
        isSuper: Bool
    ) async -> AdminInputOutcome {
        var toast: String = ""
        var resumePage: MenuPage = .adminPanel

        switch pending.kind {
        case .adAddText:
            guard isSuper else { toast = "🔒 Только суперадмин"; resumePage = .superAdmin; break }
            guard !trimmed.isEmpty else { toast = "⚠️ Пустой текст"; resumePage = .superAds; break }
            let campaign = AdCampaign.new(text: trimmed)
            await state.upsertAdCampaign(campaign)
            toast = "✓ Кампания \(campaign.id) создана. Настройки: /ads"
            resumePage = .superAds

        case .selfPromoText:
            resumePage = .superAds
            guard isSuper else { toast = "🔒 Только суперадмин"; break }
            guard !trimmed.isEmpty else { toast = "⚠️ Пустой текст"; break }
            var promoText = await state.selfPromoConfig()
            promoText.text = trimmed
            await state.setSelfPromoConfig(promoText)
            toast = "✓ Текст само-рекламы обновлён"

        case .selfPromoEvery:
            resumePage = .superAds
            guard isSuper else { toast = "🔒 Только суперадмин"; break }
            if let n = Int(trimmed), SelfPromoConfig.repliesRange.contains(n) {
                var promo = await state.selfPromoConfig()
                promo.everyNReplies = n
                await state.setSelfPromoConfig(promo)
                toast = "✓ Само-реклама · раз в <b>\(n)</b> ответов"
            } else {
                toast = "⚠️ Нужно число \(SelfPromoConfig.repliesRange.lowerBound)–\(SelfPromoConfig.repliesRange.upperBound)"
            }

        case .selfPromoPause:
            resumePage = .superAds
            guard isSuper else { toast = "🔒 Только суперадмин"; break }
            if let n = Int(trimmed), SelfPromoConfig.pauseMinutesRange.contains(n) {
                var promo = await state.selfPromoConfig()
                promo.minIntervalSeconds = n * 60
                await state.setSelfPromoConfig(promo)
                toast = n == 0 ? "✓ Пауза убрана (только частота)" : "✓ Пауза · <b>\(n)</b> мин"
            } else {
                toast = "⚠️ Нужно число 0–\(SelfPromoConfig.pauseMinutesRange.upperBound)"
            }

        default:
            break
        }

        return (toast, resumePage)
    }

    // MARK: - Per-chat values typed instead of tapping a preset

    private func applyChatValueInput(
        pending: AdminPendingInput,
        trimmed: String,
        chatKey: ChatKey,
        username: String?
    ) async -> AdminInputOutcome {
        var toast: String = ""
        var resumePage: MenuPage = .adminPanel

        switch pending.kind {
        case .chatCustomRole:
            resumePage = .role
            if trimmed.isEmpty {
                toast = "⚠️ Текст роли пуст"
            } else {
                _ = await state.setRoleAndResetHistory(chatKey: chatKey, role: trimmed + formatOptions)
                toast = "✓ Роль обновлена. Переписка очищена."
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
                    toast = "⭐ <b>\(modelID)</b> — платная модель. Открыть премиум — /buy, или пополнить баланс — /balance"
                } else {
                    _ = await state.setModelAndResetHistory(chatKey: chatKey, newModel: modelID, providerRouting: providerRouting)
                    await modelPriceMonitor?.refreshPricesIfNeeded(for: modelID)
                    toast = "✓ Модель: <code>\(modelID)</code>" + (providerRouting.map { " · \($0)" } ?? "") + ". Переписка очищена."
                }
            }

        case .chatCustomTemp:
            resumePage = .temp
            if let temp = Float(trimmed.replacingOccurrences(of: ",", with: ".")), (0.0...2.0).contains(temp) {
                await state.setTemperature(chatKey: chatKey, value: temp)
                toast = "✓ Стиль ответа: <b>\(Self.tempBucket(temp))</b> (\(Self.formatTemp(temp)))"
            } else {
                toast = "⚠️ Нужно число от 0.0 до 2.0"
            }

        case .chatCustomHistory:
            resumePage = .history
            if let n = Int(trimmed), (1...50).contains(n) {
                await state.setMaxHistory(chatKey: chatKey, newMax: n)
                toast = "✓ Память: <b>\(n) сообщ.</b>"
            } else {
                toast = "⚠️ Нужно число от 1 до 50"
            }

        default:
            break
        }

        return (toast, resumePage)
    }

    // MARK: - Markup, daily premium taste, wallets

    private func applyEconomyInput(
        pending: AdminPendingInput,
        trimmed: String,
        isSuper: Bool
    ) async -> AdminInputOutcome {
        var toast: String = ""
        var resumePage: MenuPage = .adminPanel

        switch pending.kind {
        case .markupPercent:
            resumePage = .superAdmin
            guard isSuper else { toast = "🔒 Только суперадмин"; break }
            if let pct = Int(trimmed), (0...500).contains(pct) {
                await state.setMarkupPercent(pct)
                toast = "✓ Наценка: <b>\(pct)%</b> (множитель ×\(String(format: "%.2f", 1.0 + Double(pct) / 100.0)))"
            } else {
                toast = "⚠️ Нужно число 0–500"
            }

        case .dailyPremiumLimit:
            resumePage = .superAdmin
            guard isSuper else { toast = "🔒 Только суперадмин"; break }
            if let n = Int(trimmed), (0...100).contains(n) {
                await state.setDailyPremiumLimit(n)
                toast = n == 0
                    ? "✓ Премиум-вкус выключен (0 — бесплатным сразу free-модель)"
                    : "✓ Премиум-вкус: <b>\(n)</b> умных ответов/день бесплатным"
            } else {
                toast = "⚠️ Нужно число 0–100"
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

        default:
            break
        }

        return (toast, resumePage)
    }

    // MARK: - Card acquiring: token, subscription price, credit FX rate

    private func applyCardInput(
        pending: AdminPendingInput,
        trimmed: String,
        isSuper: Bool
    ) async -> AdminInputOutcome {
        var toast: String = ""
        var resumePage: MenuPage = .adminPanel

        switch pending.kind {
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

        case .cardUsdRate:
            resumePage = .superCard
            guard isSuper else { toast = "🔒 Только суперадмин"; break }
            let rateInput = trimmed.replacingOccurrences(of: ",", with: ".")
            if let value = Double(rateInput), value >= 0 {
                if value == 0 {
                    await state.setCardUsdRateMinorUnits(nil)
                    toast = "✓ Пополнение баланса картой отключено."
                } else {
                    await state.setCardUsdRateMinorUnits(Int((value * 100).rounded()))
                    let card = await state.cardConfig()
                    toast = "✓ Курс: <b>\(card.usdRateLabel ?? "—")</b>"
                }
            } else {
                toast = "⚠️ Введите число, например <code>95</code>, или <code>0</code> для отключения."
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

        default:
            break
        }

        return (toast, resumePage)
    }

    // MARK: - Renewal reminders and winback schedule

    private func applyReminderInput(
        pending: AdminPendingInput,
        trimmed: String,
        isSuper: Bool
    ) async -> AdminInputOutcome {
        var toast: String = ""
        var resumePage: MenuPage = .adminPanel

        switch pending.kind {
        case .reminderDaysBefore:
            resumePage = .superReminders
            guard isSuper else { toast = "🔒 Только суперадмин"; break }
            var expiryConfig = await state.reminderConfig()
            if trimmed == "-" || trimmed == "0" {
                expiryConfig.expiryReminderDays = []
                await state.setReminderConfig(expiryConfig)
                toast = "✓ Напоминания до истечения выключены"
            } else {
                let parsed = trimmed
                    .split(whereSeparator: { ",; ".contains($0) })
                    .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                    .filter { SubscriptionReminderConfig.daysBeforeRange.contains($0) }
                if parsed.isEmpty {
                    toast = "⚠️ Формат: <code>3,1</code> (дни \(SubscriptionReminderConfig.daysBeforeRange.lowerBound)–\(SubscriptionReminderConfig.daysBeforeRange.upperBound))"
                } else {
                    expiryConfig.expiryReminderDays = parsed
                    await state.setReminderConfig(expiryConfig)
                    let applied = await state.reminderConfig().expiryReminderDays
                    toast = "✓ Напоминания · " + applied.map { "за \($0) дн." }.joined(separator: ", ")
                }
            }

        case .reminderWinbackDays:
            resumePage = .superReminders
            guard isSuper else { toast = "🔒 Только суперадмин"; break }
            var config = await state.reminderConfig()
            if trimmed == "-" || trimmed == "0" {
                config.winbackDays = []
                await state.setReminderConfig(config)
                toast = "✓ Winback выключен"
            } else {
                let parsed = trimmed
                    .split(whereSeparator: { ",; ".contains($0) })
                    .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                    .filter { SubscriptionReminderConfig.winbackDayRange.contains($0) }
                if parsed.isEmpty {
                    toast = "⚠️ Формат: <code>1,7</code> (дни \(SubscriptionReminderConfig.winbackDayRange.lowerBound)–\(SubscriptionReminderConfig.winbackDayRange.upperBound))"
                } else {
                    config.winbackDays = parsed
                    await state.setReminderConfig(config)
                    let applied = await state.reminderConfig().winbackDays
                    toast = "✓ Winback · " + applied.map { "+\($0)д" }.joined(separator: ", ")
                }
            }

        case .reminderDiscount:
            resumePage = .superReminders
            guard isSuper else { toast = "🔒 Только суперадмин"; break }
            if let n = Int(trimmed), SubscriptionReminderConfig.discountRange.contains(n) {
                var config = await state.reminderConfig()
                config.winbackDiscountPercent = n
                await state.setReminderConfig(config)
                toast = n == 0
                    ? "✓ Winback без скидки (только напоминание)"
                    : "✓ Скидка winback · <b>\(n)%</b>"
            } else {
                toast = "⚠️ Нужно число \(SubscriptionReminderConfig.discountRange.lowerBound)–\(SubscriptionReminderConfig.discountRange.upperBound)"
            }

        case .reminderOfferHours:
            resumePage = .superReminders
            guard isSuper else { toast = "🔒 Только суперадмин"; break }
            if let n = Int(trimmed), SubscriptionReminderConfig.offerHoursRange.contains(n) {
                var config = await state.reminderConfig()
                config.winbackOfferHours = n
                await state.setReminderConfig(config)
                toast = "✓ Скидка действует <b>\(n) ч</b>"
            } else {
                toast = "⚠️ Нужно число \(SubscriptionReminderConfig.offerHoursRange.lowerBound)–\(SubscriptionReminderConfig.offerHoursRange.upperBound)"
            }

        case .reminderInterval:
            resumePage = .superReminders
            guard isSuper else { toast = "🔒 Только суперадмин"; break }
            if let n = Int(trimmed), SubscriptionReminderConfig.sweepIntervalRange.contains(n) {
                var config = await state.reminderConfig()
                config.sweepIntervalMinutes = n
                await state.setReminderConfig(config)
                toast = "✓ Проверка каждые <b>\(n) мин</b> <i>(применится к следующему циклу)</i>"
            } else {
                toast = "⚠️ Нужно число \(SubscriptionReminderConfig.sweepIntervalRange.lowerBound)–\(SubscriptionReminderConfig.sweepIntervalRange.upperBound)"
            }

        case .reminderWalletDays:
            resumePage = .superReminders
            guard isSuper else { toast = "🔒 Только суперадмин"; break }
            if let n = Int(trimmed), SubscriptionReminderConfig.walletWinbackRange.contains(n) {
                var config = await state.reminderConfig()
                config.walletWinbackDays = n
                await state.setReminderConfig(config)
                toast = n == 0
                    ? "✓ Возврат по балансу выключен"
                    : "✓ Возврат по балансу · после <b>\(n) дн.</b> тишины"
            } else {
                toast = "⚠️ Нужно число \(SubscriptionReminderConfig.walletWinbackRange.lowerBound)–\(SubscriptionReminderConfig.walletWinbackRange.upperBound)"
            }

        default:
            break
        }

        return (toast, resumePage)
    }

    // MARK: - Growth: onboarding examples and referral economics

    private func applyGrowthInput(
        pending: AdminPendingInput,
        trimmed: String,
        isSuper: Bool
    ) async -> AdminInputOutcome {
        var toast: String = ""
        var resumePage: MenuPage = .adminPanel

        switch pending.kind {
        case .onboardingAdd, .onboardingEdit:
            resumePage = .superOnboarding
            guard isSuper else { toast = "🔒 Только суперадмин"; break }
            // "Кнопка | Текст запроса" — same shape as preset input, so the
            // super-admin learns one format for the whole menu.
            let comps = trimmed.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let label = comps.first ?? ""
            let prompt = comps.count > 1 ? comps[1] : ""
            if label.isEmpty || prompt.isEmpty {
                toast = "⚠️ Формат: <code>Кнопка | Текст запроса</code>"
            } else if pending.kind == .onboardingAdd {
                if let added = await state.addOnboardingExample(label: label, prompt: prompt) {
                    toast = "✓ Пример добавлен · <b>\(OnboardingPresenter.escape(added.label))</b>"
                } else {
                    toast = "⚠️ Не добавлен: список полон (\(OnboardingConfig.maxExamples)) или текст пуст"
                }
            } else if let id = pending.payload,
                      await state.updateOnboardingExample(id: id, label: label, prompt: prompt) {
                toast = "✓ Пример обновлён · <b>\(OnboardingPresenter.escape(label))</b>"
            } else {
                toast = "⚠️ Пример не найден — возможно, он был удалён"
            }

        case .referralInviterReward, .referralInviteeReward, .referralPaidBonus:
            resumePage = .superReferrals
            guard isSuper else { toast = "🔒 Только суперадмин"; break }
            let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
            if let usd = Double(normalized), usd >= 0 {
                let cents = Int((usd * 100).rounded())
                guard ReferralConfig.rewardRange.contains(cents) else {
                    toast = "⚠️ Максимум \(ReferralConfig.formatUsd(cents: ReferralConfig.rewardRange.upperBound)) за приглашение"
                    break
                }
                var config = await state.referralConfig()
                let side: String
                switch pending.kind {
                case .referralInviterReward:
                    config.inviterRewardCents = cents
                    side = "пригласившему"
                case .referralInviteeReward:
                    config.inviteeRewardCents = cents
                    side = "другу"
                default:
                    config.payingFriendBonusCents = cents
                    side = "за оплату друга"
                }
                await state.setReferralConfig(config)
                toast = cents == 0
                    ? "✓ Награда \(side) отключена"
                    : "✓ Награда \(side) · <b>\(ReferralConfig.formatUsd(cents: cents))</b>"
            } else {
                toast = "⚠️ Введите сумму в долларах, например <code>1</code> или <code>0.50</code>"
            }

        case .referralCap:
            resumePage = .superReferrals
            guard isSuper else { toast = "🔒 Только суперадмин"; break }
            if let n = Int(trimmed), ReferralConfig.capRange.contains(n) {
                var config = await state.referralConfig()
                config.maxRewardsPerInviter = n
                await state.setReferralConfig(config)
                toast = n == 0
                    ? "✓ Лимит наград снят (без лимита) — следите за счётчиком выплат"
                    : "✓ Лимит · <b>\(n)</b> оплаченных приглашений на человека"
            } else {
                toast = "⚠️ Нужно число \(ReferralConfig.capRange.lowerBound)–\(ReferralConfig.capRange.upperBound)"
            }

        default:
            break
        }

        return (toast, resumePage)
    }
}
