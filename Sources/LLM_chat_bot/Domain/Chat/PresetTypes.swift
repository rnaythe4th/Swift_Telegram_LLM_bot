import Foundation

struct Preset: Codable, Sendable, Equatable {
    let display: String
    let value: String
    // OpenRouter upstream provider pin (provider routing), model presets only.
    let provider: String?

    init(display: String, value: String, provider: String? = nil) {
        self.display = display
        self.value = value
        self.provider = provider
    }
}

enum PresetCategory: String, Sendable {
    case model, temp, history, role

    var displayName: String {
        switch self {
        case .model: return "Модель"
        case .temp: return "Стиль ответа"
        case .history: return "Память"
        case .role: return "Роль"
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
        case add
        case edit(index: Int)
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
    // Super-admin monetization inputs.
    case markupPercent
    case dailyPremiumLimit
    case balanceTopUp
    case cardProviderToken
    case cardPrice
    /// FX rate that prices USD credit packs on the card (roadmap step 2).
    case cardUsdRate
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
