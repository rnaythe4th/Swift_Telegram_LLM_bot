import Foundation

/// Where an example prompt is offered. A DM and a group are different rooms:
/// "напиши пост" is a personal errand, "переведи" is something a group actually
/// does together — showing both everywhere wastes the two or three button slots
/// that decide whether a new user ever gets to a first answer.
enum OnboardingPlacement: String, Codable, Sendable, CaseIterable {
    case everywhere
    case privateOnly
    case groupsOnly

    func matches(isGroup: Bool) -> Bool {
        switch self {
        case .everywhere: return true
        case .privateOnly: return !isGroup
        case .groupsOnly: return isGroup
        }
    }

    /// Short caption for the super-admin button; the label doubles as the
    /// toggle, so it has to read at a glance.
    var shortLabel: String {
        switch self {
        case .everywhere: return "везде"
        case .privateOnly: return "личка"
        case .groupsOnly: return "группы"
        }
    }

    /// Cycles through the options — the menu button is a three-state toggle.
    var next: OnboardingPlacement {
        switch self {
        case .everywhere: return .privateOnly
        case .privateOnly: return .groupsOnly
        case .groupsOnly: return .everywhere
        }
    }
}

/// One ready-made prompt offered as a button in the greeting (roadmap step 9).
/// Tapping it runs the prompt as a normal turn, so a new user sees a real
/// answer without having to invent a first question.
struct OnboardingExample: Codable, Sendable, Equatable {
    /// Stable short id — goes into `callback_data` (`ex:<id>`), so it must stay
    /// the same across edits, and stay short (Telegram caps data at 64 bytes).
    var id: String
    /// Button caption.
    var label: String
    /// The prompt sent to the model.
    var prompt: String
    var enabled: Bool
    /// Where this one is offered — DM, groups, or both.
    var placement: OnboardingPlacement
    /// Monitoring: how many times this example was tapped (persisted).
    var taps: Int

    init(
        id: String,
        label: String,
        prompt: String,
        enabled: Bool = true,
        placement: OnboardingPlacement = .everywhere,
        taps: Int = 0
    ) {
        self.id = id
        self.label = label
        self.prompt = prompt
        self.enabled = enabled
        self.placement = placement
        self.taps = taps
    }

    // Both are super-admin text on their way into an HTML message (the editor
    // page, the toasts). Escaped where they become markup — the prompt is sent
    // to the model raw.
    var escapedLabel: String { MessageText.escaped(label) }
    var escapedPrompt: String { MessageText.escaped(prompt) }

    enum CodingKeys: String, CodingKey {
        case id, label, prompt, enabled, placement, taps
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Placement is decoded through its raw string rather than as the enum:
        // an unrecognised value (a row written by a newer build) must cost one
        // example its placement, not throw away the entire onboarding config —
        // texts, order and tap counters included.
        let placement = (try? c.decodeIfPresent(String.self, forKey: .placement))
            .flatMap { $0.flatMap(OnboardingPlacement.init(rawValue:)) } ?? .everywhere
        self.init(
            id: try c.decode(String.self, forKey: .id),
            label: try c.decode(String.self, forKey: .label),
            prompt: try c.decode(String.self, forKey: .prompt),
            enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
            placement: placement,
            taps: try c.decodeIfPresent(Int.self, forKey: .taps) ?? 0
        )
    }
}

/// Super-admin-tunable onboarding: which example prompts the greeting offers and
/// where. Persisted as one `bot_config` row (`GlobalConfigKey.onboarding`), so
/// the whole set is editable live from the super-menu without a redeploy — no
/// example text is hardcoded anywhere else.
struct OnboardingConfig: Codable, Sendable, Equatable {
    /// Master switch: off means the greeting carries no example buttons.
    var enabled: Bool
    /// Also offer the examples in the welcome the bot posts when added to a
    /// group (a tap there activates the whole chat at once).
    var showInGroups: Bool
    var examples: [OnboardingExample]

    // Bounds: the greeting must stay a greeting, and callback_data must fit.
    static let maxExamples = 6
    static let maxLabelLength = 40
    static let maxPromptLength = 600
    static let maxIDLength = 12

    static let `default` = OnboardingConfig(
        enabled: true,
        showInGroups: true,
        examples: [
            OnboardingExample(
                id: "post",
                label: "✍️ Написать пост",
                prompt: "Напиши короткий пост для Telegram-канала о том, как ИИ-ассистент экономит время в повседневных задачах. Живой тон, без воды, 3–4 абзаца, в конце — один вопрос читателю.",
                placement: .privateOnly
            ),
            OnboardingExample(
                id: "explain",
                label: "💡 Объяснить простыми словами",
                prompt: "Объясни простыми словами, как работают нейросети — так, будто мне 12 лет. Один бытовой пример и три коротких вывода."
            ),
            OnboardingExample(
                id: "translate",
                label: "🌍 Перевести",
                prompt: "Переведи на английский: «Привет! Мы подключили ИИ-ассистента в наш чат — задай ему любой вопрос». Дай два варианта: дружелюбный и деловой."
            ),
            OnboardingExample(
                id: "summar",
                label: "📝 Пересказать обсуждение",
                prompt: "Сейчас я пришлю кусок переписки, а ты сделай из него короткую выжимку: о чём договорились, что осталось нерешённым и кто что должен сделать. Ответь одной фразой, что готов, и жди текст.",
                placement: .groupsOnly
            ),
        ]
    )

    /// Examples actually shown/tappable right now, for the room they are being
    /// rendered into.
    func activeExamples(inGroup: Bool) -> [OnboardingExample] {
        guard enabled else { return [] }
        return examples.filter { $0.enabled && $0.placement.matches(isGroup: inGroup) }
    }

    /// Every enabled example, regardless of room — for admin surfaces that only
    /// need to know whether the feature has anything to show at all.
    var enabledExamples: [OnboardingExample] {
        enabled ? examples.filter(\.enabled) : []
    }

    func example(id: String) -> OnboardingExample? {
        examples.first { $0.id == id }
    }

    /// Clamped copy. Every setter and the decoder go through this, so a stored
    /// or hand-typed value can never produce an unsendable keyboard.
    var normalized: OnboardingConfig {
        var copy = self
        var seen = Set<String>()
        copy.examples = examples.compactMap { example -> OnboardingExample? in
            var item = example
            item.id = String(item.id.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxIDLength))
            item.label = String(item.label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxLabelLength))
            item.prompt = String(item.prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxPromptLength))
            item.taps = max(0, item.taps)
            guard !item.id.isEmpty, !item.label.isEmpty, !item.prompt.isEmpty else { return nil }
            guard seen.insert(item.id).inserted else { return nil }
            return item
        }
        if copy.examples.count > Self.maxExamples {
            copy.examples = Array(copy.examples.prefix(Self.maxExamples))
        }
        return copy
    }

    /// Random id for a newly added example; collisions are dropped by
    /// `normalized`, so uniqueness is checked against the current list.
    static func makeID(existing: [OnboardingExample]) -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        let used = Set(existing.map(\.id))
        for _ in 0..<20 {
            let candidate = String((0..<4).map { _ in alphabet.randomElement()! })
            if !used.contains(candidate) { return candidate }
        }
        return String(Int(Date().timeIntervalSince1970).description.suffix(6))
    }

    enum CodingKeys: String, CodingKey {
        case enabled, showInGroups, examples
    }

    init(enabled: Bool, showInGroups: Bool, examples: [OnboardingExample]) {
        self.enabled = enabled
        self.showInGroups = showInGroups
        self.examples = examples
    }

    /// Missing fields fall back to the defaults, so a row written by an older
    /// build still decodes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = OnboardingConfig.default
        self.init(
            enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? fallback.enabled,
            showInGroups: try c.decodeIfPresent(Bool.self, forKey: .showInGroups) ?? fallback.showInGroups,
            examples: try c.decodeIfPresent([OnboardingExample].self, forKey: .examples) ?? fallback.examples
        )
        self = self.normalized
    }
}
