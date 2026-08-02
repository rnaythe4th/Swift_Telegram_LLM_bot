import Foundation

// Where an update goes. `dispatch` is the single entrance for every update
// type; `route` is the per-message pipeline that runs inside the per-chat
// queue. Membership changes and the onboarding tap live here too — both are
// ways into the same two paths.

extension BotOrchestrator {
    // MARK: - Dispatch

    func dispatch(update: TelegramUpdate) async {
        if let callback = update.callback_query {
            // Every path that carries a user refreshes the identity directory,
            // so a rename can never orphan a wallet or a subscription. Awaited
            // rather than detached: the handler below resolves keys, and it
            // must not race the sighting that produces them.
            let from = callback.from
            await state.identifyUser(userID: from.id, username: from.username, firstName: from.first_name)
            // An onboarding example (roadmap step 9) starts a generation, so it
            // belongs on the message path — same per-chat ordering as if the
            // user had typed the prompt.
            if let data = callback.data,
               case .example(let exampleID)? = BotCallbackAction(rawData: data) {
                Task {
                    await self.handleOnboardingExample(id: exampleID, callback: callback)
                }
                return
            }
            // Other callbacks bypass the per-chat queue on purpose: the stop
            // button must cancel the generation that is blocking that queue.
            Task {
                await self.callbackHandler.handleIfSupported(callback)
            }
            return
        }

        if let preCheckout = update.pre_checkout_query {
            Task {
                await self.handlePreCheckoutQuery(preCheckout)
            }
            return
        }

        if let memberUpdate = update.my_chat_member {
            Task {
                await self.handleMyChatMemberUpdate(memberUpdate)
            }
            return
        }

        guard let message = update.message else { return }
        let chatKey = ChatKey(chatID: message.chat.id, threadID: message.message_thread_id ?? 0)

        let result = await updateDispatcher.submit(chatKey: chatKey) { [self] in
            do {
                try await route(message: message, chatKey: chatKey)
            } catch {
                logger.error("routeMessage failed: \(error)", context: LogContext(chat: chatKey, user: message.from?.id))
                if !(error is CancellationError) {
                    let text = "⚠️ " + UserFacingError.message(error)
                    _ = try? await telegram.sendMessage(
                        .init(
                            chatID: chatKey.chatID,
                            threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                            replyTo: nil,
                            text: text,
                            replyMarkup: nil
                        )
                    )
                }
            }
        }

        if case .rejected(let shouldNotify) = result {
            await metrics.increment(MetricName.updatesDropped)
            logger.warning("queue full, update dropped", context: LogContext(chat: chatKey))
            if shouldNotify {
                // Fire-and-forget: dispatch() runs on the intake path and must
                // not wait for a rate-limiter slot.
                Task { [telegram] in
                    _ = try? await telegram.sendMessage(
                        .init(
                            chatID: chatKey.chatID,
                            threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                            replyTo: nil,
                            text: "⏳ Слишком много сообщений подряд — часть я пропустил. Дождитесь ответа на предыдущие.",
                            replyMarkup: nil
                        )
                    )
                }
            }
        }
    }

    /// An onboarding example button was tapped (roadmap step 9): echo the prompt
    /// into the chat (Telegram cannot post it as the user) and answer it as a
    /// normal turn — free-tier gate, billing and history all apply.
    private func handleOnboardingExample(id: String, callback: CallbackQuery) async {
        guard let message = callback.message else {
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: Texts.staleButton)
            return
        }
        let chatKey = ChatKey(chatID: message.chat.id, threadID: message.message_thread_id ?? 0)

        // Counts the tap (per-example stat + funnel) and resolves the prompt.
        guard let example = await state.recordOnboardingTap(id: id) else {
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Этого примера больше нет — просто напишите свой вопрос")
            return
        }
        // Answer with a word, not silence: the answer itself takes seconds to
        // start, and a button that visibly does nothing gets tapped again.
        try? await telegram.answerCallback(callbackQueryID: callback.id, text: "💡 Отправил запрос — сейчас отвечу")

        // Mirrors route(): keep chat identity fresh and let the sender's licence
        // claim an unowned chat before the access gate runs.
        await state.recordChatMeta(
            chatID: message.chat.id,
            info: ChatMetaInfo(
                type: message.chat.type,
                title: message.chat.title,
                username: message.chat.type == "private" ? (message.chat.username ?? callback.from.username) : nil,
                firstName: message.chat.type == "private" ? (message.chat.first_name ?? callback.from.first_name) : nil
            )
        )
        await state.autoAssignIfNeeded(
            chatID: chatKey.chatID,
            senderKey: state.userKey(userID: callback.from.id),
            senderUserID: callback.from.id
        )

        // In a group the echo has to name who tapped: several people share the
        // chat, and an unattributed question followed by an answer reads as the
        // bot talking to itself.
        let isPrivate = message.chat.type == "private"
        // The name goes into an HTML message, so it takes the same escaping as
        // every other stored label (`UserIdentity.displayLabel`) — a display
        // name is arbitrary text the person picked for themselves.
        let asker = isPrivate
            ? nil
            : await state.displayLabel(forKey: state.userKey(userID: callback.from.id))
        let echo = try? await telegram.sendMessage(.init(
            chatID: chatKey.chatID,
            threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
            replyTo: nil,
            text: OnboardingPresenter.tapEcho(example: example, asker: asker),
            replyMarkup: nil
        ))

        let origin = GenerationOrigin(
            user: callback.from,
            isPrivate: isPrivate,
            replyToMessageID: echo?.message_id
        )

        let result = await updateDispatcher.submit(chatKey: chatKey) { [self] in
            do {
                try await generationCoordinator.runReadyPrompt(
                    text: example.prompt,
                    chatKey: chatKey,
                    origin: origin
                )
            } catch {
                logger.error("onboarding example failed: \(error)", context: LogContext(chat: chatKey, user: callback.from.id))
                if !(error is CancellationError) {
                    _ = try? await telegram.sendMessage(.init(
                        chatID: chatKey.chatID,
                        threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                        replyTo: nil,
                        text: "⚠️ " + UserFacingError.message(error),
                        replyMarkup: nil
                    ))
                }
            }
        }

        if case .rejected = result {
            await metrics.increment(MetricName.updatesDropped)
            _ = try? await telegram.sendMessage(.init(
                chatID: chatKey.chatID,
                threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                replyTo: nil,
                text: "⏳ Слишком много запросов подряд. Дождитесь ответа и попробуйте снова.",
                replyMarkup: nil
            ))
        }
    }

    private func handleMyChatMemberUpdate(_ update: ChatMemberUpdate) async {
        let type = update.chat.type
        let wasOut = update.oldStatus == "left" || update.oldStatus == "kicked"
        let isIn = update.newStatus == "member" || update.newStatus == "administrator"

        // Private chats: `my_chat_member` is the only signal that someone
        // blocked the bot. Telegram forbids bot-initiated conversations, so a
        // blocked DM is a dead delivery address — renewal notices, winback and
        // referral payouts must stop aiming at it instead of collecting 403s
        // every sweep. Unblocking (kicked → member) revives it.
        if type == "private" {
            let isBlocked = update.newStatus == "kicked" || update.newStatus == "left"
            if isBlocked || isIn {
                await state.identifyUser(userID: update.from.id, username: update.from.username, firstName: update.from.first_name)
                await state.setBotPresence(chatID: update.chat.id, isMember: !isBlocked, type: "private")
                logger.info("private chat \(isBlocked ? "blocked" : "unblocked") the bot", context: LogContext(chat: update.chat.id, user: update.from.id))
            }
            // The DM greeting is the job of /start, not of this event.
            return
        }
        guard type == "group" || type == "supergroup" else { return }

        // Removal: the licence and the history stay (re-adding restores them),
        // but the chat stops being a delivery channel — renewal notices and
        // sponsor congratulations skip it instead of failing one by one. Only
        // an explicit exit counts; "restricted" is still a member (muted, not
        // gone) and must not silence the chat's notices.
        let isOut = update.newStatus == "left" || update.newStatus == "kicked"
        if !wasOut, isOut {
            await state.setBotPresence(chatID: update.chat.id, isMember: false, type: type, title: update.chat.title)
            logger.info("removed from group", context: LogContext(chat: update.chat.id, user: update.from.id))
            return
        }

        // Greet only on a real entry: previously out (left/kicked) → now in
        // (member/administrator). Skips promotions and permission tweaks so a
        // member→administrator change doesn't re-greet.
        guard wasOut, isIn else { return }

        // Keep the chat identity fresh for admin tooling (mirrors route()) and
        // clear any "removed" mark from an earlier exit.
        await state.setBotPresence(chatID: update.chat.id, isMember: true, type: type, title: update.chat.title)
        await state.identifyUser(userID: update.from.id, username: update.from.username, firstName: update.from.first_name)

        // Funnel: a real group entry is the viral-growth event (roadmap step 4).
        await state.bumpFunnel(.addedToGroup)

        // The person who added the bot may already be paying. Claiming the chat
        // for their licence here (instead of waiting for their first message)
        // means the group is premium from its very first answer — and lets the
        // welcome credit them rather than pitch them something they own.
        await state.autoAssignIfNeeded(
            chatID: update.chat.id,
            senderKey: state.userKey(userID: update.from.id),
            senderUserID: update.from.id
        )

        await sendGroupWelcome(chatID: update.chat.id)
        logger.info("greeted new group", context: LogContext(chat: update.chat.id, user: update.from.id))
    }

    /// Sends the group welcome unless this chat was greeted moments ago — the
    /// `?startgroup=` link makes Telegram deliver a join twice (as
    /// `my_chat_member` and as a `/start <payload>` message), and the two race
    /// on different paths.
    private func sendGroupWelcome(chatID: ChatID) async {
        guard await state.claimGroupGreeting(chatID: chatID) else { return }
        let sponsor = await state.chatSponsor(chatID: chatID, asker: nil)
        let welcome = GroupWelcomePresenter.welcome(
            sponsor: sponsor,
            onboarding: await state.onboardingConfig()
        )
        if welcome.showsExamples {
            await state.bumpFunnel(.onboardingShown)
        }
        _ = try? await telegram.sendMessage(.init(
            chatID: chatID,
            threadID: nil,
            replyTo: nil,
            text: welcome.text,
            replyMarkup: welcome.markup
        ))
    }

    private func route(message: TelegramMessage, chatKey: ChatKey) async throws {
        let senderKey = message.from.map { state.userKey(userID: $0.id) }
        let senderUserID = message.from?.id
        let isPrivate = message.chat.type == "private"

        // Identity first: this is what keeps a wallet, a subscription and a
        // licence attached to the person rather than to a rentable @invoker.
        if let from = message.from {
            await state.identifyUser(userID: from.id, username: from.username, firstName: from.first_name)
        }

        // The group was just upgraded to a supergroup. Move its state to the id
        // Telegram gave it and stop: this service message has no author, no
        // text and nothing to answer — everything after this point is about a
        // chat id that no longer receives anything.
        if let newChatID = message.migrate_to_chat_id {
            let moved = await state.migrateChat(from: chatKey.chatID, to: newChatID)
            logger.info(
                "group migrated to supergroup \(newChatID)\(moved ? "" : " (nothing stored)")",
                context: LogContext(chat: chatKey)
            )
            await persistence?.flushNow()
            return
        }

        // Keep the human-readable chat identity fresh so admin tooling can
        // show titles/usernames instead of bare IDs.
        await state.recordChatMeta(
            chatID: message.chat.id,
            info: ChatMetaInfo(
                type: message.chat.type,
                title: message.chat.title,
                username: isPrivate ? (message.chat.username ?? message.from?.username) : nil,
                firstName: isPrivate ? (message.chat.first_name ?? message.from?.first_name) : nil
            )
        )

        // Successful payment — handle before the access gate since the payer
        // isn't a tenant yet
        if let payment = message.successful_payment {
            await handleSuccessfulPayment(message: message, payment: payment)
            return
        }

        // /buy and /start are allowed before the access gate. Parsed, not
        // prefix-matched: `hasPrefix("/buy")` also let `/buying` (and any
        // `/start…`) skip the gate, while the parser is the thing that knows
        // about `/buy@botname` and the test-mode suffix.
        if let text = message.text {
            let suffix = isPrivate ? nil : await state.suffix(chatKey: chatKey)
            let parsed = ParsedBotCommand.parse(from: text, botUsername: botUsername, suffix: suffix)
            if parsed.name == .buy || parsed.name == .start {
                _ = try? await commandHandler.handleIfCommand(text: text, chatKey: chatKey, fromUser: message.from, isPrivate: isPrivate)
                return
            }
        }

        // Auto-assign unowned private chat to sender's tenant if they own one
        await state.autoAssignIfNeeded(chatID: chatKey.chatID, senderKey: senderKey, senderUserID: senderUserID)

        if try await commandHandler.handleIfCommand(text: message.text, chatKey: chatKey, fromUser: message.from, isPrivate: isPrivate) {
            return
        }

        if let text = message.text, await menuHandler.processTextInput(text: text, chatKey: chatKey, userID: message.from?.id) {
            return
        }

        try await generationCoordinator.handleIfNeeded(message: message, chatKey: chatKey)
    }
}
