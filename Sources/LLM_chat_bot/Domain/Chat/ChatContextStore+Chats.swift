import Foundation

// Chat directory: listings, chat metadata, group greeting claim and invite
// links.

extension ChatContextStore {
    // MARK: - Chat listings

    func privateChats(ownedBy owner: String? = nil) -> [(chatID: Int, threadID: Int64)] {
        contexts.keys
            .filter { $0.chatID > 0 }
            .filter { owner == nil || chatOwnership[$0.chatID] == owner }
            .map { (chatID: $0.chatID, threadID: $0.threadID) }
    }

    func groupChats(ownedBy owner: String? = nil) -> [(chatID: Int, threadID: Int64)] {
        contexts.keys
            .filter { $0.chatID < 0 }
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

    func recordChatMeta(chatID: Int, info: ChatMetaInfo) {
        guard chatMetaByID[chatID] != info else { return }
        chatMetaByID[chatID] = info
        dirtyConfigs.insert(.chatMeta)
    }

    func chatMeta(chatID: Int) -> ChatMetaInfo? {
        chatMetaByID[chatID]
    }

    /// "Title" / "@username" when known, bare ID otherwise.
    func chatDisplayLabel(chatID: Int) -> String {
        chatMetaByID[chatID]?.displayLabel ?? String(chatID)
    }

    /// Records that the bot joined or left a chat (roadmap step 4). A chat the
    /// bot was removed from still owns its licence and history — it just stops
    /// being a delivery channel until the bot is back.
    func setBotPresence(chatID: Int, isMember: Bool, type: String? = nil, title: String? = nil) {
        var info = chatMetaByID[chatID]
            ?? ChatMetaInfo(type: type ?? "group", title: title, username: nil, firstName: nil)
        if let type { info.type = type }
        if let title { info.title = title }
        info.botRemoved = isMember ? nil : true
        guard chatMetaByID[chatID] != info else { return }
        chatMetaByID[chatID] = info
        dirtyConfigs.insert(.chatMeta)
    }

    /// True when the bot is known to have been removed from this chat.
    func isBotRemoved(chatID: Int) -> Bool {
        chatMetaByID[chatID]?.botRemoved == true
    }

    // MARK: - Group welcome (roadmap step 4)

    /// One welcome per group entry. Telegram announces a join twice — as
    /// `my_chat_member` and as the `/start <payload>` message that the
    /// `?startgroup=` link posts into the chat — and the two arrive on
    /// different paths, so whichever lands first claims the greeting. The
    /// window is short enough that a genuine re-add (or a `/start` typed much
    /// later) still gets one.
    func claimGroupGreeting(chatID: Int, now: Date = Date()) -> Bool {
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

    func inviteToken(owner: String) -> String? {
        let u = userKeyOrRaw(owner)
        return inviteRecords.first(where: { $0.value.ownerUsername == u })?.key
    }

    /// Replaces the owner's invite with a fresh token (old links stop working).
    func regenerateInviteToken(owner: String) -> String? {
        let u = userKeyOrRaw(owner)
        guard tenants[u] != nil else { return nil }
        inviteRecords = inviteRecords.filter { $0.value.ownerUsername != u }
        let token = Self.makeInviteToken()
        inviteRecords[token] = InviteRecord(ownerUsername: u, createdAt: Date())
        dirtyConfigs.insert(.invites)
        return token
    }

    @discardableResult
    func revokeInviteToken(owner: String) -> Bool {
        let u = userKeyOrRaw(owner)
        let before = inviteRecords.count
        inviteRecords = inviteRecords.filter { $0.value.ownerUsername != u }
        if inviteRecords.count != before {
            dirtyConfigs.insert(.invites)
            return true
        }
        return false
    }

    /// Returns the issuing owner when the token is valid and their
    /// subscription is active.
    /// Owner key behind an invite token, if their subscription is still active.
    func redeemInvite(token: String) -> String? {
        guard let record = inviteRecords[token],
              tenants[record.ownerUsername]?.isActive == true else { return nil }
        return record.ownerUsername
    }

    private static func makeInviteToken() -> String {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<16).map { _ in alphabet.randomElement()! })
    }
}
