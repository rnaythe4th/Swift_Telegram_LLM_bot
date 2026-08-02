import Foundation

// One live "this chat is waiting for a typed value" state.
//
// Every menu button that asks for text arms the *same* slot, so a chat cannot
// hold two waits at once, arming a new one drops the old, "is anything
// pending?" is a single lookup, and the owner travels with the wait instead of
// in a parallel map that has to be swept for stale entries.

/// What the chat was asked to type. The applier is picked by this enum.
enum PendingKind: Sendable {
    /// Preset editor: `Название | Значение [| Сервис]`.
    case preset(PresetInput)
    /// Subscription price in Stars.
    case starsPrice
    /// Stars charged per $1 of credit packs.
    case starsPerUsd
    /// Model ID to pin as free.
    case freeModel
    /// Subscription price in USD, charged in crypto.
    case cryptoPrice
    /// Receiving address for one chain.
    case cryptoAddress(chain: CryptoChain)
    /// One more address for a chain's `uniqueAddress` pool.
    case cryptoPoolAdd(chain: CryptoChain)
    /// Admin / super-admin values; `AdminPendingInputKind` picks the applier.
    case admin(AdminPendingInput)
}

struct PendingRequest: Sendable {
    /// Storage key of whoever armed the wait. The wait itself is keyed by chat
    /// (the menu message it redraws lives there), but in a group the next
    /// message can come from anyone — and it must not be swallowed.
    var owner: UserKey?
    /// Menu message to redraw once the value lands.
    let menuMessageID: Int
    let kind: PendingKind
    /// When the button was tapped. A wait nobody answers must not sit in the
    /// chat forever: whoever armed it walks away, and the next thing they type
    /// — an hour later, a week later — is spent as the value. Instead of an
    /// answer they get "⚠️ Нужно число от 1 до 50" about a menu they have long
    /// forgotten, and the question never reaches the model.
    let armedAt: Date

    /// How long a tap keeps the chat listening. Long enough to look up a
    /// receiving address or write a role; short enough that a forgotten prompt
    /// is gone before the next conversation.
    static let lifetime: TimeInterval = 30 * 60

    func isLive(now: Date) -> Bool {
        now.timeIntervalSince(armedAt) < Self.lifetime
    }
}
