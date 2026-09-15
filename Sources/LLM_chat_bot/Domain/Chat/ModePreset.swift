import Foundation

/// Who may switch a chat into this mode.
///
/// Decoded through its raw string with a **fail-closed** fallback: an
/// unrecognised tier (a row written by a newer build) is treated as `premium`.
/// `OnboardingPlacement` can afford to fall back to "show everywhere" — the
/// worst case there is a button in the wrong room. Here the worst case is every
/// free user pointed at the owner's most expensive model, silently, for as long
/// as the row is misread.
enum ModeTier: String, Codable, Sendable, CaseIterable {
    /// Available to everyone, including a chat with no subscription and no balance.
    case free
    /// Needs full access (subscription, sponsor, licence or a positive balance),
    /// or one unit of today's premium taste.
    case premium

    var badge: String {
        switch self {
        case .free: return "🆓"
        case .premium: return "⭐"
        }
    }

    var next: ModeTier {
        switch self {
        case .free: return .premium
        case .premium: return .free
        }
    }
}

/// One reference bundle of chat settings, authored by the super-admin.
///
/// A `Preset` writes a single field; a mode writes the whole working
/// combination in one tap — model, answer style, memory, reasoning and
/// optionally the role. That is the difference between selling
/// "temperature 0.2 and a 30-message history" and selling "📚 Точный".
struct ModePreset: Codable, Sendable, Equatable {
    /// Stable short id — travels in `callback_data`, so it must survive edits
    /// and stay short (Telegram caps data at 64 bytes).
    var id: String
    /// Button caption, e.g. "⚡ Быстрый".
    var title: String
    /// One line under the title on the settings page — what this mode is *for*.
    var subtitle: String
    /// `nil` means "whatever free model is available" — resolved at apply time
    /// through `fallbackFreeModel()`, so a free mode keeps working when the
    /// catalogue changes underneath it.
    var model: String?
    /// OpenRouter upstream provider pin for `model`.
    var modelProviderRouting: String?
    var temp: Float
    var maxHistory: Int
    var reasoning: ReasoningEffort?
    /// `nil` leaves the chat's own role alone: switching from "быстрый" to
    /// "точный" should not silently erase a role the user wrote themselves.
    var role: String?
    var tier: ModeTier
    var enabled: Bool
    /// Monitoring: how many times this mode was picked (persisted).
    var taps: Int

    init(
        id: String,
        title: String,
        subtitle: String,
        model: String?,
        modelProviderRouting: String? = nil,
        temp: Float,
        maxHistory: Int,
        reasoning: ReasoningEffort? = nil,
        role: String? = nil,
        tier: ModeTier,
        enabled: Bool = true,
        taps: Int = 0
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.model = model
        self.modelProviderRouting = modelProviderRouting
        self.temp = temp
        self.maxHistory = maxHistory
        self.reasoning = reasoning
        self.role = role
        self.tier = tier
        self.enabled = enabled
        self.taps = taps
    }

    // A mode is named and described by a super-admin, and every one of those
    // strings is printed into HTML — on the settings page every user sees, on
    // the editor, in the toasts. Stored raw (the role is what the model is
    // told), escaped where it becomes markup, like `Preset`: one `<` in a
    // title otherwise makes Telegram refuse the whole page.
    var escapedTitle: String { MessageText.escaped(title) }
    var escapedSubtitle: String { MessageText.escaped(subtitle) }
    var escapedRole: String? { role.map(MessageText.escaped) }
    var escapedModel: String? { model.map(MessageText.escaped) }

    enum CodingKeys: String, CodingKey {
        case id, title, subtitle, model, modelProviderRouting, temp, maxHistory
        case reasoning, role, tier, enabled, taps
    }

    /// Fields added later are optional, so one row written by an older build
    /// cannot take the whole mode list down with it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tier = (try? c.decodeIfPresent(String.self, forKey: .tier))
            .flatMap { $0.flatMap(ModeTier.init(rawValue:)) } ?? .premium
        let reasoning = (try? c.decodeIfPresent(String.self, forKey: .reasoning))
            .flatMap { $0.flatMap(ReasoningEffort.init(rawValue:)) }
        self.init(
            id: try c.decode(String.self, forKey: .id),
            title: try c.decode(String.self, forKey: .title),
            subtitle: try c.decodeIfPresent(String.self, forKey: .subtitle) ?? "",
            model: try c.decodeIfPresent(String.self, forKey: .model),
            modelProviderRouting: try c.decodeIfPresent(String.self, forKey: .modelProviderRouting),
            temp: try c.decodeIfPresent(Float.self, forKey: .temp) ?? 1.0,
            maxHistory: try c.decodeIfPresent(Int.self, forKey: .maxHistory) ?? 20,
            reasoning: reasoning,
            role: try c.decodeIfPresent(String.self, forKey: .role),
            tier: tier,
            enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
            taps: try c.decodeIfPresent(Int.self, forKey: .taps) ?? 0
        )
    }
}

/// Super-admin-tunable modes: the reference settings a user picks in one tap.
/// Persisted as one `bot_config` row (`GlobalConfigKey.modes`), so the whole set
/// — texts, models, tiers, order — is editable live without a redeploy.
///
/// Global, not tenant-scoped: these are the settings the bot's owner vouches
/// for. A sponsor buying a subscription is buying access to them, not the right
/// to redefine them.
struct ModePresetConfig: Codable, Sendable, Equatable {
    /// Master switch: off falls back to the old per-setting buttons for everyone.
    var enabled: Bool
    var modes: [ModePreset]
    /// The "working mode": the one a reset returns to, and the one behind the
    /// "↺ Рабочий режим" button. Free models are genuinely bad — a user who
    /// lands on one after the daily cap needs a one-tap way back to something
    /// that works, or they simply leave.
    var defaultModeID: String?

    // Bounds: the settings page must stay one message and one screen of buttons.
    static let maxModes = 6
    static let maxTitleLength = 32
    static let maxSubtitleLength = 60
    static let maxIDLength = 12
    static let maxRoleLength = 1500
    /// A mode writes straight into a chat's settings, so it is bounded by the
    /// same ranges the settings are (`ChatContext`) — not by a second pair.
    static let historyRange = ChatContext.historyRange
    static let tempRange = ChatContext.tempRange

    static let `default` = ModePresetConfig(
        enabled: true,
        modes: [
            ModePreset(
                id: "fast",
                title: "⚡ Быстрый",
                subtitle: "короткие ответы, отвечает мгновенно",
                model: nil,
                temp: 1.0,
                maxHistory: 20,
                tier: .free
            ),
            ModePreset(
                id: "smart",
                title: "🧠 Умный",
                subtitle: "разбирается в сложном, отвечает по делу",
                model: "google/gemini-3-flash-preview",
                temp: 0.7,
                maxHistory: 20,
                reasoning: .medium,
                tier: .premium
            ),
            ModePreset(
                id: "creative",
                title: "🎨 Творческий",
                subtitle: "тексты, идеи, необычные формулировки",
                model: "x-ai/grok-4.3",
                temp: 1.6,
                maxHistory: 20,
                tier: .premium
            ),
            ModePreset(
                id: "precise",
                title: "📚 Точный",
                subtitle: "думает перед ответом, минимум выдумок",
                model: "deepseek/deepseek-v4-pro",
                temp: 0.2,
                maxHistory: 30,
                reasoning: .high,
                tier: .premium
            ),
        ],
        defaultModeID: "fast"
    )

    /// Modes actually offered right now.
    var activeModes: [ModePreset] {
        guard enabled else { return [] }
        return modes.filter(\.enabled)
    }

    func mode(id: String) -> ModePreset? {
        modes.first { $0.id == id }
    }

    /// The working mode: the configured default if it is still enabled,
    /// otherwise the first enabled free one, otherwise the first enabled one.
    var defaultMode: ModePreset? {
        let active = activeModes
        if let id = defaultModeID, let mode = active.first(where: { $0.id == id }) { return mode }
        return active.first { $0.tier == .free } ?? active.first
    }

    /// Every model a free-tier user may reach through a mode. Feeds
    /// `allowedFreeModelIDs()` — a free mode pointing at a cheap paid model is a
    /// deliberate super-admin choice, and the gate has to honour it.
    var freeTierModelIDs: Set<String> {
        Set(activeModes.filter { $0.tier == .free }.compactMap(\.model))
    }

    /// Clamped copy. Every setter and the decoder go through this, so neither a
    /// stored row nor a hand-typed value can produce an unsendable keyboard or
    /// an out-of-range temperature.
    var normalized: ModePresetConfig {
        var copy = self
        var seen = Set<String>()
        copy.modes = modes.compactMap { mode -> ModePreset? in
            var item = mode
            item.id = String(item.id.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxIDLength))
            item.title = String(item.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxTitleLength))
            item.subtitle = String(item.subtitle.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxSubtitleLength))
            item.model = item.model
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
            item.modelProviderRouting = item.modelProviderRouting
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
            item.role = item.role
                .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxRoleLength)) }
                .flatMap { $0.isEmpty ? nil : $0 }
            item.temp = Self.tempRange.clamping(item.temp)
            item.maxHistory = Self.historyRange.clamping(item.maxHistory)
            item.taps = max(0, item.taps)
            guard !item.id.isEmpty, !item.title.isEmpty else { return nil }
            guard seen.insert(item.id).inserted else { return nil }
            return item
        }
        if copy.modes.count > Self.maxModes {
            copy.modes = Array(copy.modes.prefix(Self.maxModes))
        }
        if let id = copy.defaultModeID, !copy.modes.contains(where: { $0.id == id }) {
            copy.defaultModeID = nil
        }
        return copy
    }

    /// Random id for a newly added mode; collisions are dropped by `normalized`,
    /// so uniqueness is checked against the current list.
    static func makeID(existing: [ModePreset]) -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        let used = Set(existing.map(\.id))
        for _ in 0..<20 {
            let candidate = String((0..<4).map { _ in alphabet.randomElement()! })
            if !used.contains(candidate) { return candidate }
        }
        return String(Int(Date().timeIntervalSince1970).description.suffix(6))
    }

    enum CodingKeys: String, CodingKey {
        case enabled, modes, defaultModeID
    }

    init(enabled: Bool, modes: [ModePreset], defaultModeID: String?) {
        self.enabled = enabled
        self.modes = modes
        self.defaultModeID = defaultModeID
    }

    /// Missing fields fall back to the defaults, so a row written by an older
    /// build still decodes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ModePresetConfig.default
        self.init(
            enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? fallback.enabled,
            modes: try c.decodeIfPresent([ModePreset].self, forKey: .modes) ?? fallback.modes,
            defaultModeID: try c.decodeIfPresent(String.self, forKey: .defaultModeID) ?? fallback.defaultModeID
        )
        self = self.normalized
    }
}
