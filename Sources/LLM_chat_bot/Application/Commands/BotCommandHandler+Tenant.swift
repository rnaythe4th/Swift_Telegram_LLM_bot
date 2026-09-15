import Foundation

// /tenant: licences, chat ownership and per-tenant configuration.
//
// The subcommand switch is a dispatcher; each group keeps its own switch, so a
// bare `return` inside a branch still means "done with this command".

/// One `/tenant` subcommand, and — on the same type — who may run it.
///
/// The audience used to be a hand-written `Set<String>` sitting next to the
/// dispatch switch, which is a gate that fails **open**: a new super-only
/// subcommand added to the switch and forgotten in the set is a licence knob
/// handed to every chat admin, and nothing says so at compile time. This is the
/// same shape `MenuCommand.access` closed for menu buttons (CLAUDE.md §17) —
/// `audience` is an exhaustive switch with no `default`, so a new case does not
/// build until it has named who it is for.
enum TenantSubcommand: String, CaseIterable, Hashable {
    case add, remove, list, stats
    case assign, unassign, claim, release, chats
    case adduser, removeuser, users, invite
    case extend, unlimited, expire
    case markup, price, cryptoprice
    case freemodels, cryptoaddr, cryptomode, cryptopool, cryptoinvoices

    enum Audience: Equatable {
        /// Whoever runs the bot in this chat — the licence owner, or a super-admin.
        case chatOperator
        /// The bot's own operator: prices, other people's licences, payment rails.
        case superAdmin
    }

    var audience: Audience {
        switch self {
        // A licence owner manages their own access: which chats it covers, who
        // is a guest, and the invite link that adds one.
        case .assign, .unassign, .claim, .release, .chats,
             .adduser, .removeuser, .users, .invite:
            return .chatOperator

        // Everything that reaches beyond the caller's own licence: somebody
        // else's subscription term, what things cost, which rails accept money.
        // `list` is here because it names every paying customer — the help text
        // always filed it under «Только суперадмин», the gate did not.
        case .add, .remove, .list, .stats,
             .extend, .unlimited, .expire,
             .markup, .price, .cryptoprice,
             .freemodels, .cryptoaddr, .cryptomode, .cryptopool, .cryptoinvoices:
            return .superAdmin
        }
    }
}

extension BotCommandHandler {
    func handleTenant(chatKey: ChatKey, argument: String, fromUser: TelegramUser?) async throws {
        let parts = argument.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        let arg1 = parts.count > 1 ? parts[1] : ""
        let arg2 = parts.count > 2 ? parts[2] : ""

        // Storage key: stored owners are keyed by userID, so comparisons must
        // use the key rather than the rentable handle.
        let invokerKey = await actorKey(fromUser)
        let invokerIsSuper = await state.isSuperAdmin(invokerKey)

        guard let sub = TenantSubcommand(rawValue: (parts.first ?? "").lowercased()) else {
            try await sendTenantHelp(chatKey: chatKey, invokerIsSuper: invokerIsSuper)
            return
        }
        if case .superAdmin = sub.audience, !invokerIsSuper {
            try await sendUserFeedback(chatKey: chatKey, text: Texts.superAdminOnlyCommand)
            return
        }

        switch sub {
        case .add, .remove, .list, .stats:
            try await handleTenantRegistry(
                sub: sub,
                chatKey: chatKey,
                arg1: arg1
            )

        case .assign, .unassign, .claim, .release, .chats:
            try await handleTenantChats(
                sub: sub,
                chatKey: chatKey,
                arg1: arg1,
                arg2: arg2,
                invokerKey: invokerKey,
                invokerIsSuper: invokerIsSuper
            )

        case .adduser, .removeuser, .users, .invite:
            try await handleTenantGuests(
                sub: sub,
                chatKey: chatKey,
                arg1: arg1,
                invokerKey: invokerKey
            )

        case .extend, .unlimited, .expire:
            try await handleTenantSubscription(
                sub: sub,
                chatKey: chatKey,
                arg1: arg1,
                arg2: arg2
            )

        case .markup, .price, .cryptoprice:
            try await handleTenantPricing(sub: sub, chatKey: chatKey, arg1: arg1)

        case .freemodels:
            try await handleFreeModels(chatKey: chatKey, subcommand: arg1, value: arg2)

        case .cryptoaddr:
            try await handleCryptoAddr(chatKey: chatKey, subArg: arg1, value: arg2)

        case .cryptomode:
            try await handleCryptoMode(chatKey: chatKey, value: arg1)

        case .cryptopool:
            try await handleCryptoPool(chatKey: chatKey, subArg: arg1, value: arg2)

        case .cryptoinvoices:
            try await handleCryptoInvoices(chatKey: chatKey)
        }
    }

    /// `@user` → `user`. The store resolves the storage key itself.
    private func normalizeUsername(_ raw: String) -> String {
        raw.hasPrefix("@") ? String(raw.dropFirst()) : raw
    }

    /// The person a typed handle addresses, named the way people are named
    /// everywhere else.
    ///
    /// Two rules in one place. The text came from a chat message, so echoing it
    /// back into HTML raw is a `<` away from Telegram refusing the whole
    /// confirmation — the change lands and the person is told nothing, so they
    /// type it again. And the key it resolved to must never be printed itself
    /// (`UserKey(#42)`, CLAUDE.md §17). `displayLabel` answers both: it is
    /// escaped at the source and it names whoever the key actually reached,
    /// which is the sanitised handle, not the characters that were typed.
    private func targetLabel(_ key: UserKey) async -> String {
        await state.displayLabel(forKey: key)
    }

    // MARK: - Who is a tenant at all

    private func handleTenantRegistry(
        sub: TenantSubcommand,
        chatKey: ChatKey,
        arg1: String
    ) async throws {
        switch sub {
        case .add:
            let handle = normalizeUsername(arg1)
            guard !handle.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant add @username</code>")
                return
            }
            let key = await state.userKeyOrRaw(handle)
            await state.registerTenant(key)
            try await sendUserFeedback(chatKey: chatKey, text: "✓ Спонсор \(await targetLabel(key)) зарегистрирован.")

        case .remove:
            let handle = normalizeUsername(arg1)
            guard !handle.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant remove @username</code>")
                return
            }
            let key = await state.userKeyOrRaw(handle)
            let label = await targetLabel(key)
            let removed = await state.removeTenant(key)
            try await sendUserFeedback(chatKey: chatKey, text: removed
                ? "✓ Спонсор \(label) удалён."
                : "Спонсор \(label) не найден или является владельцем.")

        case .list:
            let tenants = await state.listTenants()
            if tenants.isEmpty {
                try await sendUserFeedback(chatKey: chatKey, text: "Спонсоров пока нет.")
            } else {
                var list = tenants.prefix(Self.listCap).map { "• \($0.label)" }.joined(separator: "\n")
                if tenants.count > Self.listCap {
                    list += "\n<i>…и ещё \(tenants.count - Self.listCap)</i>"
                }
                try await sendUserFeedback(chatKey: chatKey, text: "<b>🏢 Спонсоры</b> (\(tenants.count))\n\(list)")
            }

        case .stats:
            let rows = await state.tenantStats()
            if rows.isEmpty {
                try await sendUserFeedback(chatKey: chatKey, text: "Спонсоров пока нет.")
            } else {
                var lines = ["<b>📊 Статистика tenants</b>"]
                let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy"
                for row in rows.prefix(Self.listCap) {
                    let mark = row.isSuperAdmin ? "🛡" : "🛠"
                    let realStr = row.usage.totalCost.formatted()
                    let billedStr = await state.billedCost(of: row.usage).formatted()
                    let tokens = ResponseFooterFormatter.formatTokenValue(row.usage.totalTokens)
                    let subscription: String
                    if let until = row.paidUntil {
                        subscription = row.isActive ? "до \(f.string(from: until))" : "⛔ истекла \(f.string(from: until))"
                    } else {
                        subscription = "бессрочно"
                    }
                    // `row.label`, not `row.key`: the key's description is the
                    // debug form (`UserKey(#42)`), which names nobody and shows
                    // the storage shape — the label sits right beside it.
                    lines.append("\n\(mark) <b>\(row.label)</b> · \(subscription)")
                    lines.append("  чатов <b>\(row.chatCount)</b> · юзеров <b>\(row.licensedUserCount)</b>")
                    lines.append("  запросов <b>\(row.usage.generationCount)</b> · токенов <b>\(tokens)</b>")
                    lines.append("  💵 реально <b>\(realStr)</b> · клиентская цена <b>\(billedStr)</b>")
                }
                if rows.count > Self.listCap {
                    lines.append("\n<i>…и ещё \(rows.count - Self.listCap) — /menu → 🛡 Супер-админ → 🏢 Тенанты</i>")
                }
                try await sendUserFeedback(chatKey: chatKey, text: lines.joined(separator: "\n"))
            }

        default:
            break
        }
    }

    // MARK: - Which chats a licence covers

    private func handleTenantChats(
        sub: TenantSubcommand,
        chatKey: ChatKey,
        arg1: String,
        arg2: String,
        invokerKey: UserKey?,
        invokerIsSuper: Bool
    ) async throws {
        switch sub {
        case .assign:
            let handle = normalizeUsername(arg1)
            let target = await state.userKeyOrRaw(handle)
            // Admins may only assign chats to themselves; super may assign to anyone.
            if !invokerIsSuper, target != invokerKey {
                try await sendUserFeedback(chatKey: chatKey, text: "🔒 Включить премиум в чате можно только за свой счёт.")
                return
            }
            guard !handle.isEmpty, let chatID = Int(arg2).map(ChatID.init) else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant assign @username &lt;chatID&gt;</code>")
                return
            }
            let targetName = await targetLabel(target)
            let ok = await state.assignChat(chatID: chatID, to: target)
            try await sendUserFeedback(chatKey: chatKey, text: ok
                ? "✓ В чате <code>\(chatID)</code> включён премиум \(targetName)."
                : "У \(targetName) нет премиума.")

        case .unassign:
            guard let chatID = Int(arg1).map(ChatID.init) else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant unassign &lt;chatID&gt;</code>")
                return
            }
            let owner = await state.chatOwner(chatID: chatID)
            if !invokerIsSuper, owner != invokerKey {
                try await sendUserFeedback(chatKey: chatKey, text: "🔒 В этом чате премиум открыли не вы.")
                return
            }
            let removed = await state.unassignChat(chatID: chatID)
            try await sendUserFeedback(chatKey: chatKey, text: removed != nil
                ? "✓ Chat <code>\(chatID)</code> отвязан от \(await state.displayLabel(forKey: removed!))."
                : "Чат <code>\(chatID)</code> не был привязан.")

        case .claim:
            // Admin attaches the current chat to their licence.
            guard let invoker = invokerKey else {
                try await sendUserFeedback(chatKey: chatKey, text: Self.unknownAccountNotice)
                return
            }
            let ok = await state.assignChat(chatID: chatKey.chatID, to: invoker)
            let claimLabel = await state.displayLabel(forKey: invoker)
            try await sendUserFeedback(chatKey: chatKey, text: ok
                ? "✓ Премиум включён в этом чате — за счёт \(claimLabel)."
                : "У \(claimLabel) нет активного премиума — оформить: /buy")

        case .release:
            // Admin detaches the current chat from their licence.
            let owner = await state.chatOwner(chatID: chatKey.chatID)
            if !invokerIsSuper, owner != invokerKey {
                try await sendUserFeedback(chatKey: chatKey, text: "🔒 В этом чате премиум открыли не вы.")
                return
            }
            let removed = await state.unassignChat(chatID: chatKey.chatID)
            try await sendUserFeedback(chatKey: chatKey, text: removed != nil
                ? "✓ Этот чат отвязан от \(await state.displayLabel(forKey: removed!))."
                : "Этот чат не был привязан.")

        case .chats:
            // Admin → own chats; super → all (already covered by /chats).
            guard let invoker = invokerKey else {
                try await sendUserFeedback(chatKey: chatKey, text: Self.unknownAccountNotice)
                return
            }
            let chats = await state.chatsOwnedBy(invoker)
            if chats.isEmpty {
                try await sendUserFeedback(chatKey: chatKey, text: "Ваш премиум пока не включён ни в одном чате.")
            } else {
                let list = chats.sorted().map { "• <code>\($0)</code>" }.joined(separator: "\n")
                try await sendUserFeedback(chatKey: chatKey, text: "<b>📌 Чаты с премиумом \(await state.displayLabel(forKey: invoker))</b> (\(chats.count))\n\(list)")
            }

        default:
            break
        }
    }

    // MARK: - Guests of a licence

    private func handleTenantGuests(
        sub: TenantSubcommand,
        chatKey: ChatKey,
        arg1: String,
        invokerKey: UserKey?
    ) async throws {
        switch sub {
        case .adduser:
            guard let invoker = invokerKey else {
                try await sendUserFeedback(chatKey: chatKey, text: Self.unknownAccountNotice)
                return
            }
            let target = normalizeUsername(arg1)
            guard !target.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant adduser @username</code>")
                return
            }
            let targetKey = await state.userKeyOrRaw(target)
            let targetName = await targetLabel(targetKey)
            let added = await state.addLicensedUser(ownerKey: invoker, target: targetKey)
            try await sendUserFeedback(chatKey: chatKey, text: added
                ? "✓ \(targetName) теперь пользуется умными моделями за ваш счёт."
                : "\(targetName) уже в списке, либо ваш премиум неактивен.")

        case .removeuser:
            guard let invoker = invokerKey else {
                try await sendUserFeedback(chatKey: chatKey, text: Self.unknownAccountNotice)
                return
            }
            let target = normalizeUsername(arg1)
            guard !target.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant removeuser @username</code>")
                return
            }
            let targetKey = await state.userKeyOrRaw(target)
            let targetName = await targetLabel(targetKey)
            let removed = await state.removeLicensedUser(ownerKey: invoker, target: targetKey)
            try await sendUserFeedback(chatKey: chatKey, text: removed
                ? "✓ \(targetName) больше не гость вашего премиума."
                : "\(targetName) не найден среди гостей вашего премиума.")

        case .users:
            guard let invoker = invokerKey else {
                try await sendUserFeedback(chatKey: chatKey, text: Self.unknownAccountNotice)
                return
            }
            let users = await state.licensedUsers(ownerKey: invoker)
            if users.isEmpty {
                try await sendUserFeedback(chatKey: chatKey, text: "Гостей премиума пока нет.\n\n<i>Проще всего пригласить ссылкой: /tenant invite</i>")
            } else {
                var list = users.prefix(Self.listCap).map { "• \($0.label)" }.joined(separator: "\n")
                if users.count > Self.listCap {
                    list += "\n<i>…и ещё \(users.count - Self.listCap)</i>"
                }
                try await sendUserFeedback(chatKey: chatKey, text: "<b>👥 Гости премиума \(await state.displayLabel(forKey: invoker))</b> (\(users.count))\n\(list)")
            }

        case .invite:
            guard let invoker = invokerKey else {
                try await sendUserFeedback(chatKey: chatKey, text: Self.unknownAccountNotice)
                return
            }
            guard await state.isTenant(invoker) else {
                try await sendUserFeedback(chatKey: chatKey, text: "Премиум неактивен — оформить: /buy")
                return
            }
            let wantsNew = arg1.lowercased() == "new"
            let existing = await state.inviteToken(owner: invoker)
            let token: String?
            if wantsNew || existing == nil {
                token = await state.regenerateInviteToken(owner: invoker)
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

        default:
            break
        }
    }

    // MARK: - Subscription term (super-admin only)

    private func handleTenantSubscription(
        sub: TenantSubcommand,
        chatKey: ChatKey,
        arg1: String,
        arg2: String
    ) async throws {
        switch sub {
        case .extend:
            let handle = normalizeUsername(arg1)
            guard !handle.isEmpty, let days = Int(arg2), days > 0 else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant extend @username &lt;дней&gt;</code>")
                return
            }
            let key = await state.userKeyOrRaw(handle)
            let name = await targetLabel(key)
            switch await extendSubscription(key: key, days: days) {
            case .extended(let until):
                let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy"
                try await sendUserFeedback(chatKey: chatKey, text: "✓ Подписка \(name) продлена до <b>\(f.string(from: until))</b>.")
            case .alreadyUnlimited:
                try await sendUserFeedback(chatKey: chatKey, text: "У \(name) бессрочный доступ — продлевать нечего. Чтобы задать срок: <code>/tenant expire</code>, затем продлить.")
            case .unknownTenant:
                try await sendUserFeedback(chatKey: chatKey, text: "Спонсор \(name) не найден.")
            }

        case .unlimited:
            let handle = normalizeUsername(arg1)
            guard !handle.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant unlimited @username</code>")
                return
            }
            let key = await state.userKeyOrRaw(handle)
            let name = await targetLabel(key)
            let ok = await setSubscriptionUnlimited(key: key)
            try await sendUserFeedback(chatKey: chatKey, text: ok
                ? "✓ Подписка \(name) теперь бессрочная."
                : "Спонсор \(name) не найден.")

        case .expire:
            let handle = normalizeUsername(arg1)
            guard !handle.isEmpty else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant expire @username</code>")
                return
            }
            let key = await state.userKeyOrRaw(handle)
            let name = await targetLabel(key)
            let ok = await expireSubscription(key: key)
            try await sendUserFeedback(chatKey: chatKey, text: ok
                ? "✓ Подписка \(name) немедленно завершена (лицензия и настройки сохранены)."
                : "Спонсор \(name) не найден или это владелец бота.")

        default:
            break
        }
    }

    // MARK: - Prices and markup (super-admin only)

    private func handleTenantPricing(sub: TenantSubcommand, chatKey: ChatKey, arg1: String) async throws {
        switch sub {
        case .markup:
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

        case .cryptoprice:
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
            } else if let cents = FiatCurrency.minorUnits(from: arg1), cents > 0 {
                // Integer parsing with an overflow check: `Int(Double)` traps
                // past `Int.max`, and this is a number typed into a chat.
                await state.setCryptoPriceUsdCents(cents)
                try await sendUserFeedback(chatKey: chatKey, text: String(format: "✓ Цена в крипто: <b>$%.2f</b>", Double(cents) / 100.0))
            } else {
                try await sendUserFeedback(chatKey: chatKey, text: "<i>Использование:</i> <code>/tenant cryptoprice 9.99</code> или <code>/tenant cryptoprice 0</code>")
            }

        case .price:
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
            break
        }
    }

    // MARK: - Help

    private func sendTenantHelp(chatKey: ChatKey, invokerIsSuper: Bool) async throws {
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
