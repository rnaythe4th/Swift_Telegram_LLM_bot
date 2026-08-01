import Foundation

// Super-admin only: /superadmin, /simulate, crypto configuration and the
// pinned free-model list.

extension BotCommandHandler {
    func handleSuperAdminCmd(chatKey: ChatKey, argument: String) async throws {
        let parts = argument.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        let subcommand = (parts.first ?? "").lowercased()
        let arg = parts.count > 1 ? parts[1] : ""

        func normalizeUsername(_ raw: String) -> String {
            raw.hasPrefix("@") ? String(raw.dropFirst()) : raw
        }

        switch subcommand {
        case "add":
            let handle = normalizeUsername(arg.trimmingCharacters(in: .whitespaces))
            guard !handle.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/superadmin add @username</code>")
                return
            }
            let ok = await state.addSuperAdmin(state.userKeyOrRaw(handle))
            try await sendUserFeedback(chatKey: chatKey, text: ok
                ? "✓ @\(handle) теперь суперадмин."
                : "@\(handle) уже является суперадмином.")

        case "remove":
            let handle = normalizeUsername(arg.trimmingCharacters(in: .whitespaces))
            guard !handle.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/superadmin remove @username</code>")
                return
            }
            let ok = await state.removeSuperAdmin(state.userKeyOrRaw(handle))
            try await sendUserFeedback(chatKey: chatKey, text: ok
                ? "✓ @\(handle) больше не суперадмин."
                : "Нельзя удалить главного суперадмина или такого пользователя нет.")

        case "list":
            let supers = await state.listSuperAdmins()
            let list = supers.map { "• \($0.label)" }.joined(separator: "\n")
            try await sendUserFeedback(chatKey: chatKey, text: "<b>🛡 Суперадмины</b> (\(supers.count))\n\(list)")

        default:
            try await sendUserFeedback(chatKey: chatKey, text: """
                <b>🛡 Суперадмины</b>

                <code>/superadmin add @username</code>
                <code>/superadmin remove @username</code>
                <code>/superadmin list</code>

                <i>Только главный суперадмин может управлять списком.</i>
                """)
        }
    }

    func handleSimulate(chatKey: ChatKey, fromUser: TelegramUser?, argument: String) async throws {
        // Keyed by userID, so simulation (and the test purchase below) works for
        // a super-admin who never set a @invoker — the gate above already let
        // them in by key, and demanding a handle here would contradict it.
        guard let invoker = await actorKey(fromUser) else {
            try await sendUserFeedback(chatKey: chatKey, text: "Не удалось определить ваш аккаунт — напишите боту в личку и повторите.")
            return
        }

        let arg = argument.trimmingCharacters(in: .whitespaces).lowercased()

        func currentLabel() async -> String {
            switch await state.simulatedRole(invoker) {
            case .admin: return "админ"
            case .regularUser: return "обычный пользователь"
            case nil: return "выкл (суперадмин)"
            }
        }

        switch arg {
        case "":
            let label = await currentLabel()
            try await sendUserFeedback(chatKey: chatKey, text: """
                <b>🎭 Симуляция роли</b>

                Текущий режим · <b>\(label)</b>

                <code>/simulate admin</code> — тест от админа
                <code>/simulate user</code> — тест от обычного пользователя
                <code>/simulate buy</code> — тест покупки (активация подписки без оплаты)
                <code>/simulate off</code> — выключить
                <code>/simulate status</code> — статус

                <i>Действует только в текущем процессе бота, не сохраняется при рестарте.</i>
                """)

        case "status":
            let label = await currentLabel()
            try await sendUserFeedback(chatKey: chatKey, text: "🎭 Симуляция · <b>\(label)</b>")

        case "admin":
            await state.setSimulatedRole(invoker, role: .admin)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Симуляция включена · <b>админ</b>.\nЧтобы выключить — <code>/simulate off</code>.")

        case "user", "regular":
            await state.setSimulatedRole(invoker, role: .regularUser)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Симуляция включена · <b>обычный пользователь</b>.\nЧтобы выключить — <code>/simulate off</code>.")

        case "off", "выкл", "none":
            await state.setSimulatedRole(invoker, role: nil)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Симуляция выключена. Вы снова суперадмин.")

        case "buy":
            // Test purchase: exercises the same activation logic as a real
            // Stars payment, without money changing hands.
            let activation = await state.activatePaidSubscription(invoker)
            await state.assignChat(chatID: chatKey.chatID, to: invoker)
            let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy"
            // `invoker` here is the storage key (`#12345`): printing it would
            // show "@#12345" and, worse, the suggested rollback command would
            // resolve to a different key (`#` is stripped from typed input).
            let label = await state.displayLabel(forKey: invoker)
            let handle = await state.username(forKey: invoker)
            let resultLine: String
            switch activation {
            case .started(let until):
                resultLine = "Создан тенант \(label), подписка до <b>\(f.string(from: until))</b>."
            case .extended(let until):
                resultLine = "Подписка \(label) продлена до <b>\(f.string(from: until))</b>."
            case .alreadyUnlimited:
                resultLine = "У \(label) бессрочный доступ — активация ничего не меняет."
            }
            let rollback = handle.map { "<code>/tenant remove @\($0)</code>" }
                ?? "/menu → 🛡 Супер-админ → 🏢 Тенанты → 🗑"
            try await sendUserFeedback(chatKey: chatKey, text: """
                🧪 <b>Тест покупки выполнен.</b>
                \(resultLine)
                Этот чат привязан к лицензии \(label).

                Откатить: \(rollback)
                Проверить поведение подписки: /menu → ⚡ Мой премиум, /buy
                """)

        default:
            try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/simulate admin|user|buy|off|status</code>")
        }
    }

    func handleCryptoInvoices(chatKey: ChatKey) async throws {
        let invoices = await state.openCryptoInvoices()
        var lines: [String] = ["<b>🪙 Открытые счета</b> (\(invoices.count))"]
        if invoices.isEmpty {
            lines.append("<i>нет</i>")
        } else {
            let sorted = invoices.sorted { $0.createdAt < $1.createdAt }
            for inv in sorted.prefix(50) {
                let amount = CryptoAmountFormatter.format(atomic: inv.exactAmountAtomic, decimals: inv.asset.decimals)
                let received = CryptoAmountFormatter.format(atomic: inv.accumulatedAtomic, decimals: inv.asset.decimals)
                lines.append("• \(await state.displayLabel(forKey: inv.ownerKey)) · \(inv.asset.displayLabel) · \(received)/\(amount) \(inv.asset.symbol) · \(inv.status.rawValue)")
            }
        }
        try await sendUserFeedback(chatKey: chatKey, text: lines.joined(separator: "\n"))
    }

    func handleCryptoMode(chatKey: ChatKey, value: String) async throws {
        let v = value.trimmingCharacters(in: .whitespaces).lowercased()
        if v.isEmpty {
            let mode = await state.cryptoMatchMode()
            try await sendUserFeedback(chatKey: chatKey, text: "🪙 Режим: <b>\(mode.displayName)</b>\n<i>Использование:</i> <code>/tenant cryptomode delta|unique</code>")
            return
        }
        let target: CryptoMatchMode?
        switch v {
        case "delta", "amount", "amount_delta": target = .amountDelta
        case "unique", "address", "unique_address": target = .uniqueAddress
        default: target = nil
        }
        guard let mode = target else {
            try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant cryptomode delta|unique</code>")
            return
        }
        await state.setCryptoMatchMode(mode)
        try await sendUserFeedback(chatKey: chatKey, text: "✓ Режим: <b>\(mode.displayName)</b>")
    }

    func handleCryptoPool(chatKey: ChatKey, subArg: String, value: String) async throws {
        let sub = subArg.trimmingCharacters(in: .whitespaces).lowercased()
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        let chainStr = parts.first ?? ""
        let arg2 = parts.count > 1 ? parts[1] : ""

        if sub.isEmpty || sub == "list" {
            let pools = await state.cryptoAddressPools()
            var lines: [String] = ["<b>🪙 Пулы адресов</b>"]
            for chain in CryptoChain.allCases {
                let pool = pools[chain] ?? []
                if pool.isEmpty {
                    lines.append("• \(chain.displayName) · <i>пусто</i>")
                } else {
                    lines.append("• \(chain.displayName) (\(pool.count))")
                    for (i, addr) in pool.enumerated() {
                        lines.append("  \(i). <code>\(addr)</code>")
                    }
                }
            }
            try await sendUserFeedback(chatKey: chatKey, text: lines.joined(separator: "\n"))
            return
        }

        guard let chain = CryptoChain(rawValue: chainStr.lowercased()) else {
            try await sendUserFeedback(chatKey: chatKey, text: "<i>Неизвестная сеть.</i> Используйте: <code>ton|bsc|eth|tron</code>")
            return
        }

        switch sub {
        case "add":
            let addr = arg2.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !addr.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant cryptopool add &lt;chain&gt; &lt;addr&gt;</code>")
                return
            }
            let added = await state.addCryptoPoolAddress(chain, address: addr)
            try await sendUserFeedback(chatKey: chatKey, text: added
                ? "✓ В пул \(chain.displayName) добавлен: <code>\(addr)</code>"
                : "Адрес уже в пуле.")
        case "remove":
            guard let index = Int(arg2) else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant cryptopool remove &lt;chain&gt; &lt;index&gt;</code>")
                return
            }
            let removed = await state.removeCryptoPoolAddress(chain, at: index)
            try await sendUserFeedback(chatKey: chatKey, text: removed
                ? "✓ Удалён из пула \(chain.displayName), индекс \(index)."
                : "Адрес с таким индексом не найден.")
        default:
            try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant cryptopool add|remove|list</code>")
        }
    }

    func handleCryptoAddr(chatKey: ChatKey, subArg: String, value: String) async throws {
        let lower = subArg.lowercased()
        if lower.isEmpty || lower == "list" {
            let addrs = await state.cryptoAddresses()
            if addrs.isEmpty {
                try await sendUserFeedback(chatKey: chatKey, text: "🪙 Адреса не настроены.\n<i>Использование:</i> <code>/tenant cryptoaddr ton EQ...</code>")
                return
            }
            var lines = ["<b>🪙 Адреса для приёма</b>"]
            for chain in CryptoChain.allCases {
                if let addr = addrs[chain] {
                    lines.append("• \(chain.displayName) · <code>\(addr)</code>")
                }
            }
            try await sendUserFeedback(chatKey: chatKey, text: lines.joined(separator: "\n"))
            return
        }
        guard let chain = CryptoChain(rawValue: lower) else {
            try await sendUserFeedback(chatKey: chatKey, text: "<i>Неизвестная сеть.</i> Используйте: <code>ton</code>, <code>bsc</code>, <code>eth</code>, <code>tron</code>")
            return
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            await state.setCryptoAddress(chain, address: nil)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Адрес для \(chain.displayName) удалён.")
        } else {
            await state.setCryptoAddress(chain, address: trimmed)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Адрес для \(chain.displayName): <code>\(trimmed)</code>")
        }
    }

    func handleFreeModels(chatKey: ChatKey, subcommand: String, value: String) async throws {
        switch subcommand.lowercased() {
        case "add":
            let id = value.trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant freemodels add &lt;model-id&gt;</code>")
                return
            }
            let added = await state.addFreeModel(id)
            try await sendUserFeedback(chatKey: chatKey, text: added
                ? "✓ Бесплатная модель добавлена: <code>\(id)</code>"
                : "Модель <code>\(id)</code> уже в списке.")

        case "remove":
            let id = value.trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant freemodels remove &lt;model-id&gt;</code>")
                return
            }
            let removed = await state.removeFreeModel(id)
            try await sendUserFeedback(chatKey: chatKey, text: removed
                ? "✓ Модель <code>\(id)</code> удалена из бесплатных."
                : "Модель <code>\(id)</code> не найдена в списке.")

        case "list":
            let ids = await state.freeModelIDs()
            if ids.isEmpty {
                try await sendUserFeedback(chatKey: chatKey, text: "💡 Список бесплатных моделей пуст — все модели доступны всем.")
            } else {
                let list = ids.enumerated().map { "\($0.offset + 1). <code>\($0.element)</code>" }.joined(separator: "\n")
                try await sendUserFeedback(chatKey: chatKey, text: "<b>Бесплатные модели</b> (\(ids.count))\n\(list)")
            }

        case "available":
            guard let monitor = modelPriceMonitor else {
                try await sendUserFeedback(chatKey: chatKey, text: "⚠️ Мониторинг моделей недоступен.")
                return
            }
            try await sendUserFeedback(chatKey: chatKey, text: "⏳ Запрашиваю список бесплатных моделей OpenRouter…")
            let freeModels = try await monitor.fetchCurrentFreeModels()
            if freeModels.isEmpty {
                try await sendUserFeedback(chatKey: chatKey, text: "Бесплатных моделей на OpenRouter сейчас нет.")
            } else {
                let list = freeModels.map { "• <code>\($0.id)</code>" }.joined(separator: "\n")
                try await sendUserFeedback(chatKey: chatKey, text: "<b>🆓 Бесплатные модели OpenRouter сейчас</b> (\(freeModels.count))\n\(list)")
            }

        default:
            let ids = await state.freeModelIDs()
            let status = ids.isEmpty
                ? "<i>Список пуст — все модели доступны всем.</i>"
                : ids.map { "• <code>\($0)</code>" }.joined(separator: "\n")
            try await sendUserFeedback(chatKey: chatKey, text: """
                <b>🆓 Бесплатные модели</b>

                \(status)

                <code>/tenant freemodels add &lt;id&gt;</code>
                <code>/tenant freemodels remove &lt;id&gt;</code>
                <code>/tenant freemodels list</code>
                <code>/tenant freemodels available</code> — актуальный список от OpenRouter
                """)
        }
    }
}
