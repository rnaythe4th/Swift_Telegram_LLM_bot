import Foundation

// Role gates for menu buttons.
//
// The gate used to be four lines copied at every guarded button: resolve the
// tapper's key, ask the store, answer a toast, return. Twenty-six copies of a
// security check is twenty-six chances to paste the wrong one — and one that
// forgets `answerCallback` leaves a button that appears to do nothing, which
// reads as a broken bot rather than as a refusal.
//
// All three take the callback, not a handle: the key must come from the
// userID (CLAUDE.md §17), and a raw handle locks out everyone without one.

extension BotMenuHandler {
    /// True when the tapper may act. On refusal the toast is already sent, so
    /// the caller only has to `return`.
    func requireSuperAdmin(_ callback: CallbackQuery) async -> Bool {
        await require(await state.isSuperAdmin(invokerKey(callback)),
                      callback: callback,
                      refusal: Texts.superAdminOnly)
    }

    /// Adding and removing super-admins — only the bot's owner (CLAUDE.md §6).
    func requireRootSuperAdmin(_ callback: CallbackQuery) async -> Bool {
        await require(await state.isRootSuperAdmin(invokerKey(callback)),
                      callback: callback,
                      refusal: Texts.rootSuperAdminOnly)
    }

    /// Licence owner for this chat. A super-admin passes too — `isAdmin`
    /// already accounts for that.
    func requireAdmin(_ callback: CallbackQuery, chatKey: ChatKey) async -> Bool {
        await require(await state.isAdmin(invokerKey(callback), chatID: chatKey.chatID),
                      callback: callback,
                      refusal: Texts.adminOnly)
    }

    /// Whoever runs the bot here: the super-admin, or the admin whose licence
    /// pays for this chat. Same test as `requireAdmin`, different refusal — the
    /// settings it guards are plumbing, not a paid feature, so pointing the
    /// person at the purchase page would be a lie.
    func requireOperator(_ callback: CallbackQuery, chatKey: ChatKey, refusal: String) async -> Bool {
        await require(await state.isAdmin(invokerKey(callback), chatID: chatKey.chatID),
                      callback: callback,
                      refusal: refusal)
    }

    /// Does this person meet the requirement, whatever it is? The one place the
    /// four audiences are turned into store questions, so the tap gate
    /// (`processAction`), the page gate (`showPage`) and the redraw gate
    /// (`renderPage`) cannot drift into asking three different things.
    ///
    /// `userID` is taken from the key when the caller has none: the whitelist a
    /// guest is on is keyed by userID, and dropping it made a redraw refuse
    /// somebody the tap had just let in.
    func satisfies(_ access: MenuAccess, chatKey: ChatKey, invoker: UserKey?, userID: UserID? = nil) async -> Bool {
        switch access {
        case .everyone:
            return true
        case .paidAccess:
            return await state.hasFullModelAccess(
                key: invoker,
                userID: userID ?? invoker?.userID,
                chatID: chatKey.chatID
            )
        case .chatOperator:
            return await state.isAdmin(invoker, chatID: chatKey.chatID)
        case .superAdmin:
            return await state.isSuperAdmin(invoker)
        }
    }

    /// Same question for a tap, with the refusal toast already sent.
    func allow(
        _ access: MenuAccess,
        chatKey: ChatKey,
        callback: CallbackQuery,
        refusal: String
    ) async -> Bool {
        await require(
            await satisfies(access, chatKey: chatKey, invoker: invokerKey(callback), userID: callback.from.id),
            callback: callback,
            refusal: refusal
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
