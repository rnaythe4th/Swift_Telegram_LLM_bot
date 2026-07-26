import Foundation

// /tenant: licences, chat ownership and per-tenant configuration.

extension BotCommandHandler {
    func handleTenant(chatKey: ChatKey, argument: String, fromUser: TelegramUser?) async throws {
        let parts = argument.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        let subcommand = parts.first ?? ""
        let arg1 = parts.count > 1 ? parts[1] : ""
        let arg2 = parts.count > 2 ? parts[2] : ""

        func normalizeUsername(_ raw: String) -> String {
            raw.hasPrefix("@") ? String(raw.dropFirst()) : raw
        }

        // Storage key: stored owners are keyed by userID, so comparisons must
        // use the key rather than the rentable handle.
        let invokerUsername = await actorKey(fromUser)
        let invokerIsSuper = await state.isSuperAdmin(username: invokerUsername)
        let superOnlySubs: Set<String> = [
            "remove", "price", "freemodels", "cryptoprice", "cryptoaddr",
            "cryptomode", "cryptopool", "stats", "cryptoinvoices",
            "extend", "unlimited", "expire", "markup"
        ]
        if superOnlySubs.contains(subcommand.lowercased()), !invokerIsSuper {
            try await sendUserFeedback(chatKey: chatKey, text: "🔒 Команда только для суперадминистратора.")
            return
        }

        switch subcommand.lowercased() {
        case "add":
            guard invokerIsSuper else {
                try await sendUserFeedback(chatKey: chatKey, text: "🔒 Команда только для суперадминистратора.")
                return
            }
            let username = normalizeUsername(arg1)
            guard !username.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant add @username</code>")
                return
            }
            await state.registerTenant(username: username)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Tenant @\(username) зарегистрирован.")

        case "remove":
            let username = normalizeUsername(arg1)
            guard !username.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant remove @username</code>")
                return
            }
            let removed = await state.removeTenant(username: username)
            try await sendUserFeedback(chatKey: chatKey, text: removed
                ? "✓ Tenant @\(username) удалён."
                : "Tenant @\(username) не найден или является владельцем.")

        case "list":
            let tenants = await state.listTenants()
            if tenants.isEmpty {
                try await sendUserFeedback(chatKey: chatKey, text: "Спонсоров пока нет.")
            } else {
                let list = tenants.map { "• \($0.label)" }.joined(separator: "\n")
                try await sendUserFeedback(chatKey: chatKey, text: "<b>🏢 Спонсоры</b> (\(tenants.count))\n\(list)")
            }

        case "assign":
            let username = normalizeUsername(arg1)
            // Admins may only assign chats to themselves; super may assign to anyone.
            if !invokerIsSuper, await state.userKey(username: username) != invokerUsername {
                try await sendUserFeedback(chatKey: chatKey, text: "🔒 Включить премиум в чате можно только за свой счёт.")
                return
            }
            guard !username.isEmpty, let chatID = Int(arg2) else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant assign @username &lt;chatID&gt;</code>")
                return
            }
            let ok = await state.assignChat(chatID: chatID, to: username)
            try await sendUserFeedback(chatKey: chatKey, text: ok
                ? "✓ В чате <code>\(chatID)</code> включён премиум @\(username)."
                : "У @\(username) нет премиума.")

        case "unassign":
            guard let chatID = Int(arg1) else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant unassign &lt;chatID&gt;</code>")
                return
            }
            let owner = await state.chatOwner(chatID: chatID)
            if !invokerIsSuper, owner != invokerUsername {
                try await sendUserFeedback(chatKey: chatKey, text: "🔒 В этом чате премиум открыли не вы.")
                return
            }
            let removed = await state.unassignChat(chatID: chatID)
            try await sendUserFeedback(chatKey: chatKey, text: removed != nil
                ? "✓ Chat <code>\(chatID)</code> отвязан от \(await state.displayLabel(forKey: removed!))."
                : "Чат <code>\(chatID)</code> не был привязан.")

        case "claim":
            // Admin attaches the current chat to their licence.
            guard let username = invokerUsername else {
                try await sendUserFeedback(chatKey: chatKey, text: Self.unknownAccountNotice)
                return
            }
            let ok = await state.assignChat(chatID: chatKey.chatID, to: username)
            let claimLabel = await state.displayLabel(forKey: username)
            try await sendUserFeedback(chatKey: chatKey, text: ok
                ? "✓ Премиум включён в этом чате — за счёт \(claimLabel)."
                : "У \(claimLabel) нет активного премиума — оформить: /buy")

        case "release":
            // Admin detaches the current chat from their licence.
            let owner = await state.chatOwner(chatID: chatKey.chatID)
            if !invokerIsSuper, owner != invokerUsername {
                try await sendUserFeedback(chatKey: chatKey, text: "🔒 В этом чате премиум открыли не вы.")
                return
            }
            let removed = await state.unassignChat(chatID: chatKey.chatID)
            try await sendUserFeedback(chatKey: chatKey, text: removed != nil
                ? "✓ Этот чат отвязан от \(await state.displayLabel(forKey: removed!))."
                : "Этот чат не был привязан.")

        case "chats":
            // Admin → own chats; super → all (already covered by /chats).
            guard let username = invokerUsername else {
                try await sendUserFeedback(chatKey: chatKey, text: Self.unknownAccountNotice)
                return
            }
            let chats = await state.chatsOwnedBy(username)
            if chats.isEmpty {
                try await sendUserFeedback(chatKey: chatKey, text: "Ваш премиум пока не включён ни в одном чате.")
            } else {
                let list = chats.sorted().map { "• <code>\($0)</code>" }.joined(separator: "\n")
                try await sendUserFeedback(chatKey: chatKey, text: "<b>📌 Чаты с премиумом \(await state.displayLabel(forKey: username))</b> (\(chats.count))\n\(list)")
            }

        case "adduser":
            guard let username = invokerUsername else {
                try await sendUserFeedback(chatKey: chatKey, text: Self.unknownAccountNotice)
                return
            }
            let target = normalizeUsername(arg1)
            guard !target.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant adduser @username</code>")
                return
            }
            let added = await state.addLicensedUser(ownerUsername: username, target: target)
            try await sendUserFeedback(chatKey: chatKey, text: added
                ? "✓ @\(target) теперь пользуется умными моделями за ваш счёт."
                : "@\(target) уже в списке, либо ваш премиум неактивен.")

        case "removeuser":
            guard let username = invokerUsername else {
                try await sendUserFeedback(chatKey: chatKey, text: Self.unknownAccountNotice)
                return
            }
            let target = normalizeUsername(arg1)
            guard !target.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant removeuser @username</code>")
                return
            }
            let removed = await state.removeLicensedUser(ownerUsername: username, target: target)
            try await sendUserFeedback(chatKey: chatKey, text: removed
                ? "✓ @\(target) больше не гость вашего премиума."
                : "@\(target) не найден среди гостей вашего премиума.")

        case "users":
            guard let username = invokerUsername else {
                try await sendUserFeedback(chatKey: chatKey, text: Self.unknownAccountNotice)
                return
            }
            let users = await state.licensedUsers(ownerUsername: username)
            if users.isEmpty {
                try await sendUserFeedback(chatKey: chatKey, text: "Гостей премиума пока нет.\n\n<i>Проще всего пригласить ссылкой: /tenant invite</i>")
            } else {
                let list = users.map { "• \($0.label)" }.joined(separator: "\n")
                try await sendUserFeedback(chatKey: chatKey, text: "<b>👥 Гости премиума \(await state.displayLabel(forKey: username))</b> (\(users.count))\n\(list)")
            }

        case "invite":
            guard let username = invokerUsername else {
                try await sendUserFeedback(chatKey: chatKey, text: Self.unknownAccountNotice)
                return
            }
            guard await state.isTenant(username: username) else {
                try await sendUserFeedback(chatKey: chatKey, text: "Премиум неактивен — оформить: /buy")
                return
            }
            let wantsNew = arg1.lowercased() == "new"
            let existing = await state.inviteToken(owner: username)
            let token: String?
            if wantsNew || existing == nil {
                token = await state.regenerateInviteToken(owner: username)
            } else {
                token = existing
            }
            guard let token else {
                try await sendUserFeedback(chatKey: chatKey, text: "Не удалось создать ссылку — премиум не найден.")
                return
            }
            let link = "https://t.me/\(botUsername)?start=inv_\(token)"
            let renewedNote = wantsNew ? "\n<i>Старая ссылка больше не действует.</i>" : ""
            try await sendUserFeedback(chatKey: chatKey, text: """
                🔗 <b>Ваша ссылка-приглашение</b>

                \(link)

                Любой, кто откроет её и нажмёт «Начать», получит умные модели за ваш счёт и попадёт в список гостей (/tenant users).\(renewedNote)

                <code>/tenant invite new</code> — перевыпустить (старая перестанет работать)
                """)

        case "extend":
            let username = normalizeUsername(arg1)
            guard !username.isEmpty, let days = Int(arg2), days > 0 else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant extend @username &lt;дней&gt;</code>")
                return
            }
            if let until = await state.extendTenantSubscription(username: username, days: days) {
                let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy"
                try await sendUserFeedback(chatKey: chatKey, text: "✓ Подписка @\(username) продлена до <b>\(f.string(from: until))</b>.")
            } else {
                try await sendUserFeedback(chatKey: chatKey, text: "Tenant @\(username) не найден.")
            }

        case "unlimited":
            let username = normalizeUsername(arg1)
            guard !username.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant unlimited @username</code>")
                return
            }
            let ok = await state.setTenantUnlimited(username: username)
            try await sendUserFeedback(chatKey: chatKey, text: ok
                ? "✓ Подписка @\(username) теперь бессрочная."
                : "Tenant @\(username) не найден.")

        case "expire":
            let username = normalizeUsername(arg1)
            guard !username.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant expire @username</code>")
                return
            }
            let ok = await state.expireTenantSubscription(username: username)
            try await sendUserFeedback(chatKey: chatKey, text: ok
                ? "✓ Подписка @\(username) немедленно завершена (лицензия и настройки сохранены)."
                : "Tenant @\(username) не найден или это владелец бота.")

        case "markup":
            if arg1.isEmpty {
                let pct = await state.markupPercent()
                try await sendUserFeedback(chatKey: chatKey, text: """
                    💹 Наценка на цены моделей: <b>\(pct)%</b>

                    Применяется ко всем ценам, которые видят пользователи (футер, меню, /model), и к списаниям с балансов.
                    <i>Изменить:</i> <code>/tenant markup 30</code>
                    """)
            } else if let pct = Int(arg1), (0...500).contains(pct) {
                await state.setMarkupPercent(pct)
                try await sendUserFeedback(chatKey: chatKey, text: "✓ Наценка: <b>\(pct)%</b> (множитель ×\(String(format: "%.2f", 1.0 + Double(pct) / 100.0)))")
            } else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant markup &lt;0–500&gt;</code>")
            }


        case "stats":
            let rows = await state.tenantStats()
            if rows.isEmpty {
                try await sendUserFeedback(chatKey: chatKey, text: "Спонсоров пока нет.")
            } else {
                var lines = ["<b>📊 Статистика tenants</b>"]
                let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy"
                for row in rows {
                    let mark = row.isSuperAdmin ? "🛡" : "🛠"
                    let realStr = String(format: "$%.4f", row.usage.totalCost)
                    let billedStr = String(format: "$%.4f", await state.billedCost(of: row.usage))
                    let tokens = Int(row.usage.totalTokens)
                    let subscription: String
                    if let until = row.paidUntil {
                        subscription = row.isActive ? "до \(f.string(from: until))" : "⛔ истекла \(f.string(from: until))"
                    } else {
                        subscription = "бессрочно"
                    }
                    lines.append("\n\(mark) <b>@\(row.username)</b> · \(subscription)")
                    lines.append("  чатов <b>\(row.chatCount)</b> · юзеров <b>\(row.licensedUserCount)</b>")
                    lines.append("  запросов <b>\(row.usage.generationCount)</b> · токенов <b>\(tokens)</b>")
                    lines.append("  💵 реально <b>\(realStr)</b> · клиентская цена <b>\(billedStr)</b>")
                }
                try await sendUserFeedback(chatKey: chatKey, text: lines.joined(separator: "\n"))
            }

        case "freemodels":
            try await handleFreeModels(chatKey: chatKey, subcommand: arg1, value: arg2)

        case "cryptoprice":
            if arg1.isEmpty {
                let cents = await state.cryptoPriceUsdCents()
                if let cents {
                    let usd = Double(cents) / 100.0
                    try await sendUserFeedback(chatKey: chatKey, text: String(format: "🪙 Цена в крипто: <b>$%.2f</b>", usd))
                } else {
                    try await sendUserFeedback(chatKey: chatKey, text: "🪙 Крипто-оплата отключена.")
                }
            } else if arg1 == "0" || arg1.lowercased() == "off" {
                await state.setCryptoPriceUsdCents(nil)
                try await sendUserFeedback(chatKey: chatKey, text: "✓ Крипто-оплата отключена.")
            } else if let usd = Double(arg1.replacingOccurrences(of: ",", with: ".")), usd > 0 {
                let cents = Int((usd * 100.0).rounded())
                await state.setCryptoPriceUsdCents(cents)
                try await sendUserFeedback(chatKey: chatKey, text: String(format: "✓ Цена в крипто: <b>$%.2f</b>", Double(cents) / 100.0))
            } else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant cryptoprice 9.99</code> или <code>/tenant cryptoprice 0</code>")
            }

        case "cryptoaddr":
            try await handleCryptoAddr(chatKey: chatKey, subArg: arg1, value: arg2)

        case "cryptomode":
            try await handleCryptoMode(chatKey: chatKey, value: arg1)

        case "cryptopool":
            try await handleCryptoPool(chatKey: chatKey, subArg: arg1, value: arg2)

        case "cryptoinvoices":
            try await handleCryptoInvoices(chatKey: chatKey)

        case "price":
            if arg1.isEmpty {
                let price = await state.starsPrice()
                if let price {
                    try await sendUserFeedback(chatKey: chatKey, text: "💫 Цена доступа: <b>\(price) Stars</b>")
                } else {
                    try await sendUserFeedback(chatKey: chatKey, text: "💫 Продажа доступа отключена.")
                }
            } else if arg1 == "0" || arg1.lowercased() == "off" {
                await state.setStarsPrice(nil)
                try await sendUserFeedback(chatKey: chatKey, text: "✓ Продажа доступа отключена.")
            } else if let price = Int(arg1), price > 0 {
                await state.setStarsPrice(price)
                try await sendUserFeedback(chatKey: chatKey, text: "✓ Цена доступа: <b>\(price) Stars</b>")
            } else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant price &lt;число&gt;</code> или <code>/tenant price 0</code> (отключить)")
            }

        default:
            let adminHelp = """
                <b>⚡ Управление премиумом</b>

                <code>/tenant invite</code> — 🔗 ссылка-приглашение (проще всего поделиться доступом)
                <code>/tenant claim</code> — включить премиум в этом чате
                <code>/tenant release</code> — выключить в этом чате
                <code>/tenant assign @username &lt;номер чата&gt;</code> — включить в другом чате
                <code>/tenant unassign &lt;номер чата&gt;</code> — выключить в другом чате
                <code>/tenant chats</code> — чаты, где работает ваш премиум
                <code>/tenant adduser @username</code> — добавить гостя
                <code>/tenant removeuser @username</code> — убрать гостя
                <code>/tenant users</code> — список гостей
                <code>/chatid</code> — номер этого чата
                <code>/buy</code> — статус и продление премиума
                """
            let superHelp = """

                <b>🛡 Только суперадмин</b>
                <code>/tenant add @username</code> — зарегистрировать (бессрочно)
                <code>/tenant remove @username</code> — удалить
                <code>/tenant extend @username &lt;дней&gt;</code> — продлить подписку
                <code>/tenant unlimited @username</code> · <code>/tenant expire @username</code>
                <code>/tenant list</code> — все tenants
                <code>/tenant stats</code> — статистика и подписки
                <code>/tenant price &lt;число&gt;</code> — цена в Stars (0 = отключить)
                <code>/tenant freemodels add|remove|list|available &lt;id&gt;</code>
                <code>/tenant cryptoprice &lt;USD&gt;</code> — цена крипто-доступа
                <code>/tenant cryptoaddr &lt;chain&gt; &lt;addr&gt;|list</code>
                <code>/tenant cryptomode delta|unique</code>
                <code>/tenant cryptopool add|remove|list &lt;chain&gt; …</code>
                <code>/tenant cryptoinvoices</code> — открытые счета
                """
            let text = invokerIsSuper ? adminHelp + superHelp : adminHelp
            try await sendUserFeedback(chatKey: chatKey, text: text)
        }
    }
}
