import Foundation

// /start and its deep links: greeting, referral binding, invite redemption
// and the group welcome.

extension BotCommandHandler {
    func handleStart(chatKey: ChatKey, argument: String, fromUser: TelegramUser?) async throws {
        if chatKey.chatID > 0 {
            // Funnel: `.start` means a person opened the bot. A group hitting
            // /start is the `?startgroup=` link replaying the join, which the
            // funnel already counts as `.addedToGroup`.
            await state.bumpFunnel(.start)
        } else {
            // The `?startgroup=` replay carries the adder, so a paying sponsor
            // claims their new group even if the join event went missing.
            await state.autoAssignIfNeeded(
                chatID: chatKey.chatID,
                senderUsername: fromUser?.username,
                senderUserID: fromUser?.id
            )
        }
        // Deep-link invite: t.me/<bot>?start=inv_<token> — grants paid-model
        // access under the issuing admin's licence.
        let payload = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        if payload.hasPrefix("inv_") {
            try await handleInviteRedemption(token: String(payload.dropFirst(4)), chatKey: chatKey, fromUser: fromUser)
            return
        }
        // Two-sided referral: t.me/<bot>?start=ref_<userID> (roadmap step 10).
        if let inviterUserID = ReferralLink.inviterUserID(payload: payload) {
            try await handleReferralStart(inviterUserID: inviterUserID, chatKey: chatKey, fromUser: fromUser)
            return
        }
        // Paid-traffic tag: t.me/<bot>?start=src_<кампания>. Silent by design —
        // this only labels where the person came from, so there is nothing to
        // tell them about; the greeting must look exactly like any other.
        if let tag = TrafficSourceLink.tag(payload: payload), let user = fromUser, chatKey.chatID > 0 {
            await state.bindTrafficSource(userID: user.id, tag: tag, username: user.username)
        }
        try await sendStartGreeting(chatKey: chatKey)
    }

    /// Attributes a new user to their inviter, then greets as usual. Nothing is
    /// paid here — the reward lands after the invited user's first real answer
    /// (see `GenerationCoordinator`), which is what keeps farming pointless.
    private func handleReferralStart(inviterUserID: Int, chatKey: ChatKey, fromUser: TelegramUser?) async throws {
        // Referral links are personal: attribution only makes sense in the DM
        // the link opens.
        guard let user = fromUser, chatKey.chatID > 0 else {
            try await sendStartGreeting(chatKey: chatKey)
            return
        }

        let config = await state.referralConfig()
        let outcome = await state.bindReferral(
            invitedUserID: user.id,
            invitedUsername: user.username,
            inviterUserID: inviterUserID
        )

        var note: String?
        switch outcome {
        case .bound(let inviter, let inviteeReward):
            // `paysOnSignup`, not `paysAnything`: the bonus for a friend who
            // pays lands much later and does not belong in the copy that
            // promises money for the first question — otherwise a config with
            // only that bonus prints «на ваш баланс придёт $0.00».
            if config.paysOnSignup {
                note = "🎁 <b>Вас пригласил \(inviter).</b>\n\nЗадайте первый вопрос — и на ваш баланс придёт"
                    + " <b>\(inviteeReward.formatted(fractionDigits: 2))</b>"
                    + " (пригласившему — \(config.inviterReward.formatted(fractionDigits: 2)))."
                    + "\n\nПока баланс не пуст, вам доступны любые модели без подписки: с него списывается стоимость каждого ответа, обычно доли цента."
            } else {
                note = "🎁 Вы пришли по приглашению <b>\(inviter)</b>. Просто напишите вопрос — отвечу."
            }

        case .boundWithoutReward(let inviter):
            // Honest instead of silent: the attribution stands, but the
            // inviter is out of paid invites, so no money is promised.
            note = "🎁 Вы пришли по приглашению <b>\(inviter)</b>. Бонус за это приглашение уже исчерпан, но бот работает как обычно — просто напишите вопрос. Своя ссылка с бонусом — /ref"

        case .alreadyBound(let inviter):
            note = "ℹ️ Вас уже пригласил <b>\(inviter)</b> — бонус за приглашение даётся только один раз."

        case .selfInvite:
            note = "🙂 Это ваша собственная ссылка — себя пригласить нельзя. Отправьте её друзьям: /ref"

        case .notNewUser:
            note = "ℹ️ Бонус за приглашение получают только те, кто раньше боту не писал. Зато приглашать можете вы сами: /ref"

        case .unknownInviter:
            note = "⚠️ Ссылка не сработала: тот, кто её прислал, ещё ни разу не писал этому боту."

        case .disabled:
            note = nil
        }

        if let note {
            try await sendUserFeedback(chatKey: chatKey, text: note)
        }
        try await sendStartGreeting(chatKey: chatKey)
    }

    private func handleInviteRedemption(token: String, chatKey: ChatKey, fromUser: TelegramUser?) async throws {
        guard let owner = await state.redeemInvite(token: token) else {
            try await sendUserFeedback(chatKey: chatKey, text: """
                ⚠️ Ссылка не работает — она устарела или премиум-доступ пригласившего уже закончился.
                Попросите у него новую.
                """)
            try await sendStartGreeting(chatKey: chatKey)
            return
        }

        let ownerLabel = await state.displayLabel(forKey: owner)
        // Match against every key this person could be filed under: with no
        // @username the handle-only comparison is nil == "#id", so the owner
        // would "activate" their own invite and add themselves as their own guest.
        if await state.userKeys(username: fromUser?.username, userID: fromUser?.id).contains(owner) {
            try await sendUserFeedback(chatKey: chatKey, text: "ℹ️ Это ваша собственная пригласительная ссылка — доступ у вас и так есть.")
            return
        }

        var grantedLines: [String] = []
        if let visitorID = fromUser?.id {
            // Filed under the visitor's account, so the grant survives a rename
            // and works for someone who never set a @username.
            _ = await state.addLicensedUser(ownerUsername: owner, target: state.userKey(userID: visitorID))
            grantedLines.append("• платные модели доступны вам во всех чатах с этим ботом")
        }
        // Private chat: attach it to the inviter's licence too, so access holds
        // even if the guest list is later cleared.
        if chatKey.chatID > 0, await state.chatOwner(chatID: chatKey.chatID) == nil {
            _ = await state.assignChat(chatID: chatKey.chatID, to: owner)
            grantedLines.append("• в этом чате премиум работает за счёт \(ownerLabel)")
        }

        guard !grantedLines.isEmpty else {
            try await sendUserFeedback(chatKey: chatKey, text: """
                ⚠️ Приглашение не сработало: в этом чате премиум уже открыт другим спонсором.
                Откройте ссылку в личке с ботом.
                """)
            return
        }

        try await sendUserFeedback(chatKey: chatKey, text: """
            🎟 <b>Приглашение от \(ownerLabel) активировано!</b>

            \(grantedLines.joined(separator: "\n"))

            Просто напишите сообщение — бот ответит. Настройки: /menu
            """)
    }

    private func sendStartGreeting(chatKey: ChatKey) async throws {
        // A group reaching /start is almost always Telegram replaying the
        // `?startgroup=` link as `/start <payload>` right after the join. The
        // DM copy ("напишите мне", "добавить в свой чат") makes no sense there,
        // and `claimGroupGreeting` inside makes sure the join event and this
        // message produce exactly one welcome between them.
        if chatKey.chatID < 0 {
            try await sendGroupWelcome(chatID: chatKey.chatID)
            return
        }

        var text = """
        <b>👋 Привет!</b> Я — умный ИИ-ассистент в Telegram.

        Напишите мне — отвечу. Понимаю текст, фото, голос и видео, помню разговор.

        <b>Хотите умного ИИ в свой групповой чат?</b> Меня можно добавить — премиум откроет любой участник, и доступ заработает сразу для всех.

        ⚙️ /menu · 📘 /help
        """
        var rows: [[InlineKeyboardButton]] = []

        // Onboarding (roadmap step 9): ready-made prompts turn the empty chat
        // after /start — the biggest drop-off point — into one tap to value.
        let onboarding = await state.onboardingConfig()
        let exampleRows = OnboardingPresenter.exampleRows(onboarding, inGroup: false)
        if !exampleRows.isEmpty {
            text += "\n\n" + OnboardingPresenter.invitation
            rows.append(contentsOf: exampleRows)
            await state.bumpFunnel(.onboardingShown)
        }

        // Viral loop entry: one tap opens Telegram's group picker and adds the
        // bot; the group-entry greeting then pitches premium to the owner.
        if !botUsername.isEmpty {
            rows.append([InlineKeyboardButton(text: "➕ Добавить в свой чат", url: "https://t.me/\(botUsername)?startgroup=add")])
        }
        rows.append([InlineKeyboardButton(text: "⚙️ Открыть меню", callback_data: BotCallbackAction.menu(action: MenuRoute.link(.open)).rawData)])
        rows.append([InlineKeyboardButton(text: "📘 Инструкция", callback_data: BotCallbackAction.faq.rawData)])
        let markup = InlineKeyboardMarkup(inline_keyboard: rows)
        _ = try await telegram.sendMessage(.init(
            chatID: chatKey.chatID,
            threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
            replyTo: nil,
            text: text,
            replyMarkup: markup
        ))
    }

    /// Group welcome (roadmap step 4). Mirrors `BotOrchestrator.sendGroupWelcome`
    /// through the same presenter and the same one-shot claim, so whichever of
    /// the two paths lands first is the one that posts.
    private func sendGroupWelcome(chatID: Int) async throws {
        guard await state.claimGroupGreeting(chatID: chatID) else { return }
        let sponsor = await state.chatSponsor(chatID: chatID, askerUsername: nil)
        let welcome = GroupWelcomePresenter.welcome(
            sponsor: sponsor,
            onboarding: await state.onboardingConfig()
        )
        if welcome.showsExamples {
            await state.bumpFunnel(.onboardingShown)
        }
        _ = try await telegram.sendMessage(.init(
            chatID: chatID,
            threadID: nil,
            replyTo: nil,
            text: welcome.text,
            replyMarkup: welcome.markup
        ))
    }
}
