import Foundation

// Command dispatch: one switch from a parsed command to its handler,
// plus the per-chat settings commands that need no page of their own.

extension BotCommandHandler {
    func handle(_ parsed: ParsedBotCommand, chatKey: ChatKey, fromUser: TelegramUser?) async throws {
        switch parsed.name {
        case .whitelist:
            guard try await requireAdmin(fromUser, chatKey: chatKey) else { return }
            try await handleWhitelist(chatKey: chatKey, argument: parsed.argument)

        case .defaults:
            guard try await requireAdmin(fromUser, chatKey: chatKey) else { return }
            try await handleDefaults(chatKey: chatKey, argument: parsed.argument)

        case .chats:
            guard try await requireAdmin(fromUser, chatKey: chatKey) else { return }
            try await handleChats(chatKey: chatKey, fromUser: fromUser)

        case .users:
            guard try await requireAdmin(fromUser, chatKey: chatKey) else { return }
            try await handleUsers(chatKey: chatKey, fromUser: fromUser)

        case .presets:
            guard try await requireAdmin(fromUser, chatKey: chatKey) else { return }
            try await handlePresets(chatKey: chatKey, argument: parsed.argument)

        case .tenant:
            guard await isAdmin(fromUser, chatID: chatKey.chatID) else {
                try await sendUserFeedback(chatKey: chatKey, text: Texts.adminOnlyCommand)
                return
            }
            try await handleTenant(chatKey: chatKey, argument: parsed.argument, fromUser: fromUser)

        case .superadmin:
            guard await state.isRootSuperAdmin(username: actorKey(fromUser)) else {
                try await sendUserFeedback(chatKey: chatKey, text: Texts.rootSuperAdminOnlyCommand)
                return
            }
            try await handleSuperAdminCmd(chatKey: chatKey, argument: parsed.argument)

        case .buy:
            try await handleBuy(chatKey: chatKey, fromUser: fromUser)

        case .simulate:
            guard await state.isActuallySuperAdmin(username: actorKey(fromUser)) else {
                try await sendUserFeedback(chatKey: chatKey, text: Texts.superAdminOnlyCommand)
                return
            }
            try await handleSimulate(chatKey: chatKey, fromUser: fromUser, argument: parsed.argument)

        case .start:
            try await handleStart(chatKey: chatKey, argument: parsed.argument, fromUser: fromUser)

        case .forget:
            try await handleForget(chatKey: chatKey, fromUser: fromUser)

        case .chatid:
            try await handleChatID(chatKey: chatKey)

        case .inspect:
            guard await isSuperAdmin(fromUser) else {
                try await sendUserFeedback(chatKey: chatKey, text: Texts.superAdminOnlyCommand)
                return
            }
            try await handleInspect(chatKey: chatKey, argument: parsed.argument)

        case .ads:
            guard await isSuperAdmin(fromUser) else {
                try await sendUserFeedback(chatKey: chatKey, text: Texts.superAdminOnlyCommand)
                return
            }
            try await handleAds(chatKey: chatKey, argument: parsed.argument)

        case .balance:
            try await handleBalance(chatKey: chatKey, argument: parsed.argument, fromUser: fromUser)

        case .reminders:
            guard await isSuperAdmin(fromUser) else {
                try await sendUserFeedback(chatKey: chatKey, text: Texts.superAdminOnlyCommand)
                return
            }
            try await handleReminders(chatKey: chatKey, argument: parsed.argument, fromUser: fromUser)

        case .examples:
            try await handleExamples(chatKey: chatKey, argument: parsed.argument, fromUser: fromUser)

        case .referral:
            try await handleReferral(chatKey: chatKey, argument: parsed.argument, fromUser: fromUser)

        case .setRole, .clearHistory, .setTemp, .model, .defaultRole, .historyLength:
            try await handleChatValueCommand(parsed, chatKey: chatKey, fromUser: fromUser)

        case .showTokens, .showCost, .showModel, .backupNotify, .testMode, .reset, .resetStats:
            try await handleChatToggleCommand(parsed, chatKey: chatKey)

        case .provider, .reasoning:
            try await handleAiServiceCommand(parsed, chatKey: chatKey, fromUser: fromUser)

        case .help:
            let markup = InlineKeyboardMarkup(inline_keyboard: [
                [InlineKeyboardButton(text: "⚙️ Открыть меню", callback_data: BotCallbackAction.menu(action: MenuRoute.link(.open)).rawData)],
            ])
            _ = try await telegram.sendMessage(.init(
                chatID: chatKey.chatID,
                threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                replyTo: nil,
                text: BotCallbackHandler.faqText,
                replyMarkup: markup
            ))

        case .menu:
            await menuHandler.sendMenu(chatKey: chatKey, userID: fromUser?.id, username: fromUser?.username)

        case .history:
            try await handleHistory(chatKey: chatKey)

        case .mention, .unknown:
            return
        }
    }
}
