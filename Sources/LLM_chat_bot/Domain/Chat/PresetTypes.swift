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
        case .temp: return "Температура"
        case .history: return "Длина истории"
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

struct PendingInput: Sendable {
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
    let menuMessageID: Int
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
}

struct AdminPendingInput: Sendable {
    let kind: AdminPendingInputKind
    let menuMessageID: Int
    let payload: String?
}
