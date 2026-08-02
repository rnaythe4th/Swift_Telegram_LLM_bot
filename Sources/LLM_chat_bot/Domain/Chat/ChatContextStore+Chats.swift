import Foundation

// Chat directory: listings, chat metadata, group greeting claim and invite
// links.

extension ChatContextStore {
    // MARK: - Chat listings

    func privateChats(ownedBy owner: UserKey? = nil) -> [(chatID: ChatID, threadID: Int64)] {
        contexts.keys
            .filter { $0.chatID.isPrivate }
            .filter { owner == nil || chatOwnership[$0.chatID] == owner }
            .map { (chatID: $0.chatID, threadID: $0.threadID) }
    }

    func groupChats(ownedBy owner: UserKey? = nil) -> [(chatID: ChatID, threadID: Int64)] {
        contexts.keys
            .filter { $0.chatID.isGroup }
            .filter { owner == nil || chatOwnership[$0.chatID] == owner }
            .map { (chatID: $0.chatID, threadID: $0.threadID) }
    }

    func chatsWithBackupNotify() -> [ChatKey] {
        contexts.filter { $0.value.backupNotify }.map(\.key)
    }

    func chatsUsing(model: String) -> [ChatKey] {
        contexts.filter { $0.value.model == model }.map(\.key)
    }

    func allTrackedModelIDs() -> Set<String> {
        var ids = Set<String>()
        for tenant in tenants.values {
            ids.insert(tenant.defaultModel)
            tenant.modelPresets.forEach { ids.insert($0.value) }
        }
        for ctx in contexts.values {
            ids.insert(ctx.model)
            ctx.chatModelPresets.forEach { ids.insert($0.value) }
        }
        return ids
    }

    // MARK: - Chat metadata (titles / usernames for admin tooling)

    func recordChatMeta(chatID: ChatID, info: ChatMetaInfo) {
        guard chatMetaByID[chatID] != info else { return }
        chatMetaByID[chatID] = info
        dirtyChats.insert(chatID)
        deletedChats.remove(chatID)
    }

    func chatMeta(chatID: ChatID) -> ChatMetaInfo? {
        chatMetaByID[chatID]
    }

    /// "Title" / "@username" when known, bare ID otherwise.
    func chatDisplayLabel(chatID: ChatID) -> String {
        chatMetaByID[chatID]?.displayLabel ?? String(chatID.value)
    }

    /// Records that the bot joined or left a chat (roadmap step 4). A chat the
    /// bot was removed from still owns its licence and history — it just stops
    /// being a delivery channel until the bot is back.
    func setBotPresence(chatID: ChatID, isMember: Bool, type: String? = nil, title: String? = nil) {
        var info = chatMetaByID[chatID]
            ?? ChatMetaInfo(type: type ?? "group", title: title, username: nil, firstName: nil)
        if let type { info.type = type }
        if let title { info.title = title }
        info.botRemoved = isMember ? nil : true
        guard chatMetaByID[chatID] != info else { return }
        chatMetaByID[chatID] = info
        dirtyChats.insert(chatID)
        deletedChats.remove(chatID)
    }

    /// True when the bot is known to have been removed from this chat.
    func isBotRemoved(chatID: ChatID) -> Bool {
        chatMetaByID[chatID]?.botRemoved == true
    }

    // MARK: - Retention (§7.2)

    /// Chats whose conversation is not up for expiry: anything a tenant's
    /// licence covers, and every DM belonging to somebody who pays. They are
    /// customers, and losing their history would be a downgrade of what they
    /// bought.
    func chatsWorthKeeping() -> Set<ChatID> {
        var keep = Set(chatOwnership.keys)
        // A paying person's own DM. `ChatID.privateChat(with:)` is the one
        // place the "a private chat's id is the user's id" convention lives,
        // so here it is named rather than assumed.
        for (owner, tenant) in tenants where tenant.isActive {
            if let account = owner.userID { keep.insert(account.privateChat) }
        }
        for (key, wallet) in userBalances where wallet.balance.isPositive {
            if let account = key.userID { keep.insert(account.privateChat) }
        }
        for key in superAdminKeys {
            if let account = key.userID { keep.insert(account.privateChat) }
        }
        return keep
    }

    /// Drops conversations the retention sweep already removed from storage —
    /// cache only, so this must not mark them dirty and write them back.
    func dropContexts(_ keys: [ChatKey]) {
        for key in keys {
            contexts.removeValue(forKey: key)
            dirtyContexts.remove(key)
        }
    }

    /// `/forget`: erases this chat's conversation on request. The wallet, the
    /// subscription and the money journal stay — they are the person's own
    /// evidence in a billing dispute, and deleting them would erase the proof
    /// rather than the data.
    func forgetChat(chatKey: ChatKey) -> Bool {
        guard contexts.removeValue(forKey: chatKey) != nil else { return false }
        dirtyContexts.remove(chatKey)
        deletedContexts.insert(chatKey)
        return true
    }

    // MARK: - Group welcome (roadmap step 4)

    /// One welcome per group entry. Telegram announces a join twice — as
    /// `my_chat_member` and as the `/start <payload>` message that the
    /// `?startgroup=` link posts into the chat — and the two arrive on
    /// different paths, so whichever lands first claims the greeting. The
    /// window is short enough that a genuine re-add (or a `/start` typed much
    /// later) still gets one.
    func claimGroupGreeting(chatID: ChatID, now: Date = Date()) -> Bool {
        if let last = _groupGreetedAt[chatID], now.timeIntervalSince(last) < Self.groupGreetingCooldown {
            return false
        }
        _groupGreetedAt[chatID] = now
        if _groupGreetedAt.count > 512 {
            // Bounded: drop entries that can no longer suppress anything.
            _groupGreetedAt = _groupGreetedAt.filter { now.timeIntervalSince($0.value) < Self.groupGreetingCooldown }
        }
        return true
    }

    // MARK: - Invite links (referral access under an admin's licence)

    func inviteToken(owner: UserKey) -> String? {
        let u = resolved(owner)
        return inviteRecords.first(where: { $0.value.ownerKey == u })?.key
    }

    /// Replaces the owner's invite with a fresh token (old links stop working).
    func regenerateInviteToken(owner: UserKey) -> String? {
        let u = resolved(owner)
        guard tenants[u] != nil else { return nil }
        for stale in inviteRecords.filter({ $0.value.ownerKey == u }).keys {
            inviteRecords.removeValue(forKey: stale)
            dirtyInvites.remove(stale)
            deletedInvites.insert(stale)
        }
        let token = Self.makeInviteToken()
        inviteRecords[token] = InviteRecord(ownerKey: u, createdAt: Date())
        dirtyInvites.insert(token)
        deletedInvites.remove(token)
        return token
    }

    /// Returns the issuing owner when the token is valid and their
    /// subscription is active.
    /// Owner key behind an invite token, if their subscription is still active.
    func redeemInvite(token: String) -> UserKey? {
        guard let record = inviteRecords[token],
              tenants[record.ownerKey]?.isActive == true else { return nil }
        return record.ownerKey
    }

    private static func makeInviteToken() -> String {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<16).map { _ in alphabet.randomElement()! })
    }
}
