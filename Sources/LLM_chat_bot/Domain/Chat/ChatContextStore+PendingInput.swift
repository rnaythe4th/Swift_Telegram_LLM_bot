import Foundation

// Pending typed input: what a chat is waiting for and who it belongs to.

extension ChatContextStore {
    // MARK: - Pending input

    func setPendingInput(_ input: PendingInput, chatKey: ChatKey) {
        _pendingInputs[chatKey] = input
    }

    func consumePendingInput(chatKey: ChatKey) -> PendingInput? {
        _pendingInputs.removeValue(forKey: chatKey)
    }

    func clearPendingInput(chatKey: ChatKey) {
        _pendingInputs.removeValue(forKey: chatKey)
    }

    func hasPendingInput(chatKey: ChatKey) -> Bool {
        _pendingInputs[chatKey] != nil
    }

    // MARK: - Pending free model input

    func setPendingFreeModelInput(menuMessageID: Int, chatKey: ChatKey) {
        _pendingFreeModelInputs[chatKey] = menuMessageID
    }

    func consumePendingFreeModelInput(chatKey: ChatKey) -> Int? {
        _pendingFreeModelInputs.removeValue(forKey: chatKey)
    }

    func hasPendingFreeModelInput(chatKey: ChatKey) -> Bool {
        _pendingFreeModelInputs[chatKey] != nil
    }

    func clearPendingFreeModelInput(chatKey: ChatKey) {
        _pendingFreeModelInputs.removeValue(forKey: chatKey)
    }

    // MARK: - Pending input ownership

    /// Is this chat waiting for a typed value of any kind?
    func hasAnyPendingInput(chatKey: ChatKey) -> Bool {
        _pendingInputs[chatKey] != nil
            || _pendingStarsPriceInputs[chatKey] != nil
            || _pendingStarsPerUsdInputs[chatKey] != nil
            || _pendingFreeModelInputs[chatKey] != nil
            || _pendingCryptoPriceInputs[chatKey] != nil
            || _pendingCryptoAddressInputs[chatKey] != nil
            || _pendingCryptoPoolAddInputs[chatKey] != nil
            || _pendingAdminInputs[chatKey] != nil
    }

    /// Remembers who a live wait belongs to; forgets it once nothing is pending.
    /// Called after every menu action, so a new wait always carries its owner
    /// and a consumed one leaves nothing behind.
    func notePendingInputOwner(_ userKey: String?, chatKey: ChatKey) {
        guard hasAnyPendingInput(chatKey: chatKey) else {
            _pendingInputOwners.removeValue(forKey: chatKey)
            return
        }
        guard let userKey else { return }
        _pendingInputOwners[chatKey] = userKey
    }

    /// Owner of the chat's live wait, or nil when nothing is pending (a stale
    /// entry left by a consumed wait is dropped here rather than lingering).
    func pendingInputOwner(chatKey: ChatKey) -> String? {
        guard hasAnyPendingInput(chatKey: chatKey) else {
            _pendingInputOwners.removeValue(forKey: chatKey)
            return nil
        }
        return _pendingInputOwners[chatKey]
    }

    func setAdminPendingInput(_ input: AdminPendingInput, chatKey: ChatKey) {
        _pendingAdminInputs[chatKey] = input
    }

    func consumeAdminPendingInput(chatKey: ChatKey) -> AdminPendingInput? {
        _pendingAdminInputs.removeValue(forKey: chatKey)
    }

    func hasAdminPendingInput(chatKey: ChatKey) -> Bool {
        _pendingAdminInputs[chatKey] != nil
    }

    func clearAdminPendingInput(chatKey: ChatKey) {
        _pendingAdminInputs.removeValue(forKey: chatKey)
    }

    func setPendingCryptoPoolAddInput(menuMessageID: Int, chain: CryptoChain, chatKey: ChatKey) {
        _pendingCryptoPoolAddInputs[chatKey] = (menuMessageID, chain)
    }

    func consumePendingCryptoPoolAddInput(chatKey: ChatKey) -> (menuMessageID: Int, chain: CryptoChain)? {
        _pendingCryptoPoolAddInputs.removeValue(forKey: chatKey)
    }

    func hasPendingCryptoPoolAddInput(chatKey: ChatKey) -> Bool {
        _pendingCryptoPoolAddInputs[chatKey] != nil
    }

    func clearPendingCryptoPoolAddInput(chatKey: ChatKey) {
        _pendingCryptoPoolAddInputs.removeValue(forKey: chatKey)
    }
}
