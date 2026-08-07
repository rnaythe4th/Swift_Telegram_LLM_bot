import Foundation

/// One saved value a chat can apply in a tap ("заготовка").
///
/// `id` is what a button carries, not the position: a keyboard drawn a minute
/// ago describes a list that may have changed since, and a delete addressed by
/// position removes whatever slid into that slot. The id survives edits, so a
/// stale button either hits the preset it named or nothing at all.
struct Preset: Codable, Sendable, Equatable, Identifiable {
    /// Stable short id — travels in `callback_data`, so it must survive edits
    /// and stay short (Telegram caps data at 64 bytes).
    let id: String
    let display: String
    let value: String
    // OpenRouter upstream provider pin (provider routing), model presets only.
    let provider: String?

    // Bounds: a preset list has to stay one message and one screen of buttons,
    // and a role preset is a paragraph rather than a field.
    static let maxIDLength = 8
    static let maxDisplayLength = 32
    static let maxValueLength = 1500
    static let maxProviderLength = 32

    init(id: String, display: String, value: String, provider: String? = nil) {
        self.id = id
        self.display = display
        self.value = value
        self.provider = provider
    }

    /// A preset nobody has an id for yet. Uniqueness is settled by `PresetList`,
    /// which is the only thing that can see the neighbours.
    init(display: String, value: String, provider: String? = nil) {
        self.init(id: Self.makeID(), display: display, value: value, provider: provider)
    }

    enum CodingKeys: String, CodingKey {
        case id, display, value, provider
    }

    /// `id` was added after the first rows were written, so a stored preset may
    /// not carry one. An empty id is a request for a fresh one, filled in by
    /// `PresetList.normalized` — the only place that knows which ids are taken.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: (try? c.decodeIfPresent(String.self, forKey: .id)) .flatMap { $0 } ?? "",
            display: try c.decode(String.self, forKey: .display),
            value: try c.decode(String.self, forKey: .value),
            provider: try c.decodeIfPresent(String.self, forKey: .provider)
        )
    }

    /// Random id. The first character is a letter so an id can never be read as
    /// a position by `presetTarget`, which still accepts buttons sent by an
    /// older build.
    static func makeID() -> String {
        let letters = Array("abcdefghjkmnpqrstuvwxyz")
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String([letters.randomElement()!] + (0..<3).map { _ in alphabet.randomElement()! })
    }

    // MARK: - Putting a preset into a message

    // A preset is arbitrary text somebody typed, and in a group *any* member can
    // add one. Stored raw — the value is a model id or a role the model is given,
    // and escaping would corrupt both — so the escaping happens where it turns
    // into markup. A button caption is not markup and takes `display` as it is.

    var escapedDisplay: String { Self.escapedForMessage(display) }
    var escapedValue: String { Self.escapedForMessage(value) }
    var escapedProvider: String? { provider.map(Self.escapedForMessage) }

    static func escapedForMessage(_ raw: String) -> String { MessageText.escaped(raw) }
}

/// The four preset lists, wherever they appear (tenant-wide or per-chat).
///
/// Presets are the one piece of state a *user* can grow: anyone may add presets
/// to their chat, every admin may add global ones, and both end up in a `jsonb`
/// row and on a page that has to fit in one Telegram message. So the bound lives
/// in the type — there is no `append`, only `add`, which refuses once the list
/// is full — and the same type normalizes whatever comes back from storage, so
/// neither a hand-written row nor a row from an older build can produce an
/// unsendable page or a duplicate id.
struct PresetList: Sendable, Equatable, RandomAccessCollection, ExpressibleByArrayLiteral {
    /// Per list, per scope: twelve buttons is already two screens on a phone.
    static let maxCount = 12

    private var items: [Preset]

    init(_ presets: [Preset] = []) {
        self.items = Self.normalized(presets)
    }

    init(arrayLiteral elements: Preset...) {
        self.init(elements)
    }

    // MARK: - Collection

    var startIndex: Int { items.startIndex }
    var endIndex: Int { items.endIndex }
    subscript(position: Int) -> Preset { items[position] }

    /// For the boundaries that speak plain arrays: persistence snapshots and
    /// callers that concatenate two lists before searching them.
    var asArray: [Preset] { items }

    // MARK: - Mutation

    enum AddOutcome: Sendable, Equatable {
        case added(Preset)
        /// The list already holds `PresetList.maxCount` presets.
        case full
    }

    @discardableResult
    mutating func add(display: String, value: String, provider: String? = nil) -> AddOutcome {
        guard items.count < Self.maxCount else { return .full }
        let candidate = Preset(
            id: Preset.makeID(),
            display: display,
            value: value,
            provider: provider
        )
        let before = items.count
        items = Self.normalized(items + [candidate])
        // Normalization rejects an empty display/value and re-issues a colliding
        // id, so the stored preset is the last one only if it survived.
        guard items.count > before, let stored = items.last else { return .full }
        return .added(stored)
    }

    /// Replaces the preset with this id, keeping the id and the position.
    /// False means the button pointed at a preset that is no longer there.
    @discardableResult
    mutating func replace(id: String, display: String, value: String, provider: String? = nil) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        var updated = items
        updated[index] = Preset(id: id, display: display, value: value, provider: provider)
        let normalized = Self.normalized(updated)
        // An empty display or value would drop the preset instead of editing it.
        guard normalized.count == items.count else { return false }
        items = normalized
        return true
    }

    @discardableResult
    mutating func remove(id: String) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        items.remove(at: index)
        return true
    }

    /// Removes every preset carrying this value — the `/presets remove <value>`
    /// command, which addresses by what it does rather than by which one it is.
    @discardableResult
    mutating func removeAll(value: String) -> Bool {
        let before = items.count
        items.removeAll { $0.value == value }
        return items.count < before
    }

    func first(id: String) -> Preset? { items.first { $0.id == id } }

    // MARK: - Normalization

    private static func normalized(_ presets: [Preset]) -> [Preset] {
        var seen = Set<String>()
        var result: [Preset] = []
        for preset in presets.prefix(maxCount) {
            let display = String(
                preset.display.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Preset.maxDisplayLength)
            )
            let value = String(
                preset.value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Preset.maxValueLength)
            )
            let provider = preset.provider
                .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Preset.maxProviderLength)) }
                .flatMap { $0.isEmpty ? nil : $0 }
            guard !display.isEmpty, !value.isEmpty else { continue }
            var id = String(preset.id.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Preset.maxIDLength))
            if id.isEmpty || seen.contains(id) {
                repeat { id = Preset.makeID() } while seen.contains(id)
            }
            seen.insert(id)
            result.append(Preset(id: id, display: display, value: value, provider: provider))
        }
        return result
    }
}

extension PresetList: Codable {
    /// Stored as a bare array, the shape every existing row already has.
    init(from decoder: Decoder) throws {
        self.init(try [Preset](from: decoder))
    }

    func encode(to encoder: Encoder) throws {
        try items.encode(to: encoder)
    }
}

enum PresetCategory: String, Sendable, CaseIterable {
    case model, temp, history, role

    /// The word `/presets <тип> …` takes. `historylength` is the older spelling
    /// and still works.
    init?(commandWord: String) {
        switch commandWord.lowercased() {
        case "model": self = .model
        case "temp": self = .temp
        case "history", "historylength": self = .history
        case "role": self = .role
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .model: return "Модель"
        case .temp: return "Стиль ответа"
        case .history: return "Память"
        case .role: return "Роль"
        }
    }

    /// "Заготовки <этого>" — the genitive the command output reads with.
    var listName: String {
        switch self {
        case .model: return "моделей"
        case .temp: return "стиля ответа"
        case .history: return "памяти"
        case .role: return "ролей"
        }
    }

    var addExample: String {
        switch self {
        case .model: return "DeepSeek V4 | deepseek/deepseek-v4-pro | deepseek"
        case .temp: return "Низкая | 0.3"
        case .history: return "Короткая | 5"
        case .role: return "Физик | Ты физик, отвечай кратко."
        }
    }
}

struct ModelPriceInfo: Sendable {
    let inputPerToken: Double
    let outputPerToken: Double
}

/// Which preset the editor is about to write. Carried by `PendingKind.preset`,
/// which also holds the menu message this belongs to.
struct PresetInput: Sendable {
    enum Scope: Sendable {
        case global
        case chat
    }
    enum Kind: Sendable {
        /// The preset being edited, by id: the wait outlives the page that
        /// armed it (`PendingRequest.lifetime`), and a position does not.
        case add
        case edit(id: String)
    }
    let category: PresetCategory
    let scope: Scope
    let kind: Kind
}

enum AdminPendingInputKind: Sendable {
    case whitelistAdd
    case defaultsModel
    case defaultsRole
    case defaultsHistory
    case tenantAssignChat
    case tenantAddUser
    case tenantRegister
    case tenantRemove
    case superAdminAdd
    case superAdminRemove
    case simulateAs
    case adAddText
    // Built-in self-promo filling the free-tier ad slot (roadmap step 5).
    case selfPromoText
    case selfPromoEvery
    case selfPromoPause
    // User-level custom value inputs from the settings menu.
    case chatCustomRole
    case chatCustomModel
    case chatCustomTemp
    case chatCustomHistory
    /// How many overheard messages a listening chat keeps.
    case chatListenSize
    // Super-admin monetization inputs.
    case markupPercent
    case dailyPremiumLimit
    /// Daily spending ceilings (§4.1), in dollars; `0` removes the limit.
    case spendGlobalCap
    case spendTenantCap
    case balanceTopUp
    case cardProviderToken
    case cardPrice
    /// FX rate that prices USD credit packs on the card (roadmap step 2).
    case cardUsdRate
    // Hosted checkout (§7 «Внешняя касса»): merchant credentials and prices.
    case externalMerchantID
    case externalSecret
    case externalCallbackSecret
    case externalPrice
    case externalUsdRate
    /// `<код> | <название>` of one more rail on the vendor's checkout page.
    case externalMethodAdd
    // Renewal reminders / winback schedule (roadmap step 8).
    case reminderDaysBefore
    case reminderWinbackDays
    case reminderDiscount
    case reminderOfferHours
    case reminderInterval
    /// Idle days before a lapsed pay-as-you-go wallet gets one offer back.
    case reminderWalletDays
    // Greeting example prompts (roadmap step 9); edit carries the example id.
    case onboardingAdd
    case onboardingEdit
    // Reference modes; edit carries the mode id.
    case modeAdd
    case modeEdit
    /// The role a mode applies, edited on its own — it is a paragraph, not a
    /// field in a one-line form.
    case modeRole
    // Two-sided referral economics (roadmap step 10).
    case referralInviterReward
    case referralInviteeReward
    case referralCap
    /// Bonus the inviter gets when their friend first pays.
    case referralPaidBonus
}

/// An admin/super-admin value request. The menu message it redraws lives on
/// the enclosing `PendingRequest`.
struct AdminPendingInput: Sendable {
    let kind: AdminPendingInputKind
    let payload: String?

    init(kind: AdminPendingInputKind, payload: String? = nil) {
        self.kind = kind
        self.payload = payload
    }
}
