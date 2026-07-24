import Foundation

/// A super-admin ad shown in chats without an active paid licence.
///
/// Two throttles combine per chat:
///  - frequency: at most one ad per `everyNReplies` bot replies, and never
///    more often than `minIntervalSeconds` since the previous ad in that chat;
///  - pacing: with both `totalImpressionsTarget` and `endAt` set, impressions
///    are spread evenly across the campaign window instead of burning out on
///    day one.
struct AdCampaign: Codable, Sendable, Equatable {
    var id: String
    var text: String
    var buttonText: String?
    var buttonURL: String?
    var enabled: Bool
    /// Show after every N bot replies in a chat.
    var everyNReplies: Int
    /// Minimum pause between ads in one chat (any campaign).
    var minIntervalSeconds: Int
    /// Total impressions cap; nil = unlimited.
    var totalImpressionsTarget: Int?
    var impressionsUsed: Int
    var startAt: Date
    /// Campaign end; with a target set, impressions are paced until this date.
    var endAt: Date?
    var createdAt: Date

    static func makeID() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<5).map { _ in alphabet.randomElement()! })
    }

    static func new(text: String) -> AdCampaign {
        AdCampaign(
            id: makeID(),
            text: text,
            buttonText: nil,
            buttonURL: nil,
            enabled: true,
            everyNReplies: 10,
            minIntervalSeconds: 3600,
            totalImpressionsTarget: nil,
            impressionsUsed: 0,
            startAt: Date(),
            endAt: nil,
            createdAt: Date()
        )
    }

    /// Reserved id of the built-in self-promo campaign (never stored in the
    /// campaign list; recognised by the sender to skip the "Реклама" label).
    static let selfPromoID = "selfpromo"

    /// Built-in fallback shown in free-tier chats when no super-admin campaign
    /// is running: the ad slot promotes premium itself. Synthetic — it is never
    /// persisted, so it needs no dirty-tracking. Same default throttle as `new`.
    static var selfPromo: AdCampaign {
        AdCampaign(
            id: selfPromoID,
            text: "📣 Надоела реклама и лимиты? Премиум для чата откроет любой участник → /buy",
            buttonText: nil,
            buttonURL: nil,
            enabled: true,
            everyNReplies: 10,
            minIntervalSeconds: 3600,
            totalImpressionsTarget: nil,
            impressionsUsed: 0,
            startAt: Date(),
            endAt: nil,
            createdAt: Date()
        )
    }

    func isRunning(now: Date = Date()) -> Bool {
        guard enabled, now >= startAt else { return false }
        if let endAt, now >= endAt { return false }
        if let target = totalImpressionsTarget, impressionsUsed >= target { return false }
        return true
    }

    /// With a target and an end date, allow only the share of impressions
    /// proportional to elapsed time; otherwise no pacing restriction.
    func pacingAllows(now: Date = Date()) -> Bool {
        guard let target = totalImpressionsTarget, let endAt else { return true }
        let duration = endAt.timeIntervalSince(startAt)
        guard duration > 0 else { return true }
        let elapsed = max(0, now.timeIntervalSince(startAt))
        let allowed = Double(target) * min(1.0, elapsed / duration)
        return Double(impressionsUsed) < max(1.0, allowed)
    }
}
