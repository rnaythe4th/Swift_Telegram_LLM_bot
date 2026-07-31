import Foundation

// Role gates for menu buttons.
//
// The gate used to be four lines copied at every guarded button: resolve the
// tapper's key, ask the store, answer a toast, return. Twenty-six copies of a
// security check is twenty-six chances to paste the wrong one — and one that
// forgets `answerCallback` leaves a button that appears to do nothing, which
// reads as a broken bot rather than as a refusal.
//
// All three take the callback, not a username: the key must come from the
// userID (CLAUDE.md §17), and a raw handle locks out everyone without one.

extension BotMenuHandler {
    /// True when the tapper may act. On refusal the toast is already sent, so
    /// the caller only has to `return`.
    func requireSuperAdmin(_ callback: CallbackQuery) async -> Bool {
        await require(await state.isSuperAdmin(username: invokerKey(callback)),
                      callback: callback,
                      refusal: Texts.superAdminOnly)
    }

    /// Adding and removing super-admins — only the bot's owner (CLAUDE.md §6).
    func requireRootSuperAdmin(_ callback: CallbackQuery) async -> Bool {
        await require(await state.isRootSuperAdmin(username: invokerKey(callback)),
                      callback: callback,
                      refusal: Texts.rootSuperAdminOnly)
    }

    /// Licence owner for this chat. A super-admin passes too — `isAdmin`
    /// already accounts for that.
    func requireAdmin(_ callback: CallbackQuery, chatKey: ChatKey) async -> Bool {
        await require(await state.isAdmin(username: invokerKey(callback), chatID: chatKey.chatID),
                      callback: callback,
                      refusal: Texts.adminOnly)
    }

    /// Whoever runs the bot here: the super-admin, or the admin whose licence
    /// pays for this chat. Same test as `requireAdmin`, different refusal — the
    /// settings it guards are plumbing, not a paid feature, so pointing the
    /// person at the purchase page would be a lie.
    func requireOperator(_ callback: CallbackQuery, chatKey: ChatKey, refusal: String) async -> Bool {
        await require(await state.isAdmin(username: invokerKey(callback), chatID: chatKey.chatID),
                      callback: callback,
                      refusal: refusal)
    }

    /// Subscription, sponsor, licence or a positive balance — the line between
    /// "picks a reference mode" and "takes the settings apart".
    func hasFullAccess(_ callback: CallbackQuery, chatKey: ChatKey) async -> Bool {
        await state.hasFullModelAccess(
            username: invokerKey(callback),
            userID: callback.from.id,
            chatID: chatKey.chatID
        )
    }

    private func require(_ allowed: Bool, callback: CallbackQuery, refusal: String) async -> Bool {
        guard allowed else {
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: refusal)
            return false
        }
        return true
    }
}
