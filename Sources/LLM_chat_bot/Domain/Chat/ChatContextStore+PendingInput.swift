import Foundation

// Pending typed input: what a chat is waiting for and who it belongs to.
//
// One slot per chat (`PendingRequest`), so there is nothing to keep in sync:
// arming replaces, consuming empties, and the owner cannot outlive the wait.

extension ChatContextStore {
    // MARK: - Arming and consuming

    /// Arms the chat's wait, replacing whatever it was waiting for before.
    ///
    /// The owner is carried over: a wait re-armed because the typed value was
    /// invalid had no button tap in between, so there is no new tapper to
    /// stamp — and a menu action always re-stamps the owner afterwards anyway.
    func setPending(_ kind: PendingKind, menuMessageID: Int, chatKey: ChatKey) {
        _pendingRequests[chatKey] = PendingRequest(
            owner: _pendingRequests[chatKey]?.owner,
            menuMessageID: menuMessageID,
            kind: kind
        )
    }

    /// What the chat is waiting for, without spending the wait.
    func pendingRequest(chatKey: ChatKey) -> PendingRequest? {
        _pendingRequests[chatKey]
    }

    func consumePending(chatKey: ChatKey) -> PendingRequest? {
        _pendingRequests.removeValue(forKey: chatKey)
    }

    func clearPending(chatKey: ChatKey) {
        _pendingRequests.removeValue(forKey: chatKey)
    }

    /// Is this chat waiting for a typed value of any kind?
    func hasAnyPendingInput(chatKey: ChatKey) -> Bool {
        _pendingRequests[chatKey] != nil
    }

    // MARK: - Ownership

    /// Remembers who a live wait belongs to. Called after every menu action, so
    /// a wait armed by a tap always carries the person who tapped.
    func notePendingInputOwner(_ userKey: String?, chatKey: ChatKey) {
        guard let userKey, _pendingRequests[chatKey] != nil else { return }
        _pendingRequests[chatKey]?.owner = userKey
    }

    /// Owner of the chat's live wait, or nil when nothing is pending.
    func pendingInputOwner(chatKey: ChatKey) -> String? {
        _pendingRequests[chatKey]?.owner
    }
}
