import Foundation

// Pending typed input: what a chat is waiting for and who it belongs to.
//
// One slot per chat (`PendingRequest`), so there is nothing to keep in sync:
// arming replaces, consuming empties, and the owner cannot outlive the wait.
// A wait also cannot outlive its own usefulness — every read goes through
// `livePending`, which drops it once `PendingRequest.lifetime` has passed.

extension ChatContextStore {
    /// Above this many chats waiting at once, expired slots are swept on the
    /// next arm. Nothing removes a wait nobody answers, and a map that only
    /// ever grows is the same leak whatever it holds.
    private static var pendingRequestSweepThreshold: Int { 256 }

    // MARK: - Arming and consuming

    /// Arms the chat's wait, replacing whatever it was waiting for before.
    ///
    /// The owner is carried over: a wait re-armed because the typed value was
    /// invalid had no button tap in between, so there is no new tapper to
    /// stamp — and a menu action always re-stamps the owner afterwards anyway.
    /// Carried over from a *live* wait only: inheriting the owner of one that
    /// already expired would hand the new prompt to whoever tapped last week.
    func setPending(_ kind: PendingKind, menuMessageID: Int, chatKey: ChatKey, now: Date = Date()) {
        let owner = livePending(chatKey: chatKey, now: now)?.owner
        _pendingRequests[chatKey] = PendingRequest(
            owner: owner,
            menuMessageID: menuMessageID,
            kind: kind,
            armedAt: now
        )
        if _pendingRequests.count > Self.pendingRequestSweepThreshold {
            _pendingRequests = _pendingRequests.filter { $0.value.isLive(now: now) }
        }
    }

    /// What the chat is waiting for, without spending the wait.
    func pendingRequest(chatKey: ChatKey, now: Date = Date()) -> PendingRequest? {
        livePending(chatKey: chatKey, now: now)
    }

    func consumePending(chatKey: ChatKey, now: Date = Date()) -> PendingRequest? {
        guard let request = livePending(chatKey: chatKey, now: now) else { return nil }
        _pendingRequests.removeValue(forKey: chatKey)
        return request
    }

    func clearPending(chatKey: ChatKey) {
        _pendingRequests.removeValue(forKey: chatKey)
    }

    /// Is this chat waiting for a typed value of any kind?
    func hasAnyPendingInput(chatKey: ChatKey, now: Date = Date()) -> Bool {
        livePending(chatKey: chatKey, now: now) != nil
    }

    /// The single door to the slot: an expired wait is not returned and not
    /// kept, so nothing downstream has to remember to check the clock.
    private func livePending(chatKey: ChatKey, now: Date) -> PendingRequest? {
        guard let request = _pendingRequests[chatKey] else { return nil }
        guard request.isLive(now: now) else {
            _pendingRequests.removeValue(forKey: chatKey)
            return nil
        }
        return request
    }

    // MARK: - Ownership

    /// Remembers who a live wait belongs to. Called after every menu action, so
    /// a wait armed by a tap always carries the person who tapped.
    func notePendingInputOwner(_ userKey: UserKey?, chatKey: ChatKey, now: Date = Date()) {
        guard let userKey, livePending(chatKey: chatKey, now: now) != nil else { return }
        _pendingRequests[chatKey]?.owner = userKey
    }

    /// Owner of the chat's live wait, or nil when nothing is pending.
    func pendingInputOwner(chatKey: ChatKey, now: Date = Date()) -> UserKey? {
        livePending(chatKey: chatKey, now: now)?.owner
    }
}
