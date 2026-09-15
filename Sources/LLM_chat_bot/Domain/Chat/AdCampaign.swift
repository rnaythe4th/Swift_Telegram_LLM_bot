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

    /// Bounds a campaign's throttles, in the domain rather than in whoever is
    /// setting them (CLAUDE.md §17) — `SelfPromoConfig` already carries the same
    /// two, and the paid campaign had none at all. That mattered beyond taste:
    /// `/ads freq <id> 10 <minutes>` wrote `minutes * 60` straight into the row,
    /// and `Int` multiplication **traps** on overflow, so a long enough number
    /// in a chat message took the process down.
    static let repliesRange = SelfPromoConfig.repliesRange
    static let pauseMinutesRange = SelfPromoConfig.pauseMinutesRange

    /// Pause in seconds for a pause given in minutes, clamped to a day.
    static func pauseSeconds(minutes: Int) -> Int {
        pauseMinutesRange.clamping(minutes) * 60
    }

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
    /// campaign list; recognised by the sender to skip the "Реклама" label and
    /// to attach the purchase buttons).
    static let selfPromoID = "selfpromo"

    /// Built-in fallback shown in free-tier chats when no super-admin campaign
    /// is running: the ad slot promotes premium itself. Synthetic — the text and
    /// throttle come from `SelfPromoConfig` (a `bot_config` row), the campaign
    /// object itself is never persisted.
    static func selfPromo(_ config: SelfPromoConfig) -> AdCampaign {
        AdCampaign(
            id: selfPromoID,
            text: config.text,
            buttonText: nil,
            buttonURL: nil,
            enabled: config.enabled,
            everyNReplies: config.everyNReplies,
            minIntervalSeconds: config.minIntervalSeconds,
            totalImpressionsTarget: nil,
            impressionsUsed: config.impressions,
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

/// The built-in self-promo that fills the free-tier ad slot when no paid
/// campaign is running (roadmap step 5). Everything about it is a super-admin
/// knob — the wording is the pitch itself, and a hardcoded pitch cannot be
/// A/B-tested or muted. Persisted as `GlobalConfigKey.selfPromo`; `impressions`
/// lives here too, so the page can show what the slot actually did.
struct SelfPromoConfig: Codable, Sendable, Equatable {
    var enabled: Bool
    var text: String
    /// Show after every N bot replies in a chat.
    var everyNReplies: Int
    /// Minimum pause between ads in one chat.
    var minIntervalSeconds: Int
    /// Lifetime impressions of the built-in promo.
    var impressions: Int

    static let repliesRange = 1...100
    static let pauseMinutesRange = 0...1440
    static let maxTextLength = 500

    static let defaultText = "📣 Хотите умные модели без лимитов и без этой рекламы? Премиум открывает любой участник — и он работает сразу для всего чата."

    static let `default` = SelfPromoConfig(
        enabled: true,
        text: defaultText,
        everyNReplies: 10,
        minIntervalSeconds: 3600,
        impressions: 0
    )

    /// Clamped copy; applied both on set and on decode, so a hand-edited row
    /// can never turn the promo into a flood.
    var normalized: SelfPromoConfig {
        var copy = self
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.text = trimmed.isEmpty
            ? Self.defaultText
            : String(trimmed.prefix(Self.maxTextLength))
        copy.everyNReplies = min(max(everyNReplies, Self.repliesRange.lowerBound), Self.repliesRange.upperBound)
        copy.minIntervalSeconds = min(max(minIntervalSeconds, 0), Self.pauseMinutesRange.upperBound * 60)
        copy.impressions = max(0, impressions)
        return copy
    }

    init(enabled: Bool, text: String, everyNReplies: Int, minIntervalSeconds: Int, impressions: Int) {
        self.enabled = enabled
        self.text = text
        self.everyNReplies = everyNReplies
        self.minIntervalSeconds = minIntervalSeconds
        self.impressions = impressions
    }

    /// Every field optional on decode: a row written by an older build (or none
    /// at all) still yields a working promo.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = SelfPromoConfig.default
        self.init(
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? fallback.enabled,
            text: try container.decodeIfPresent(String.self, forKey: .text) ?? fallback.text,
            everyNReplies: try container.decodeIfPresent(Int.self, forKey: .everyNReplies) ?? fallback.everyNReplies,
            minIntervalSeconds: try container.decodeIfPresent(Int.self, forKey: .minIntervalSeconds) ?? fallback.minIntervalSeconds,
            impressions: try container.decodeIfPresent(Int.self, forKey: .impressions) ?? 0
        )
        self = normalized
    }
}
