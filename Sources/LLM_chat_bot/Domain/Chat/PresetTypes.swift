import Foundation

struct Preset: Codable, Sendable, Equatable {
    let display: String
    let value: String
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
        case .model: return "GPT-4o | openai/gpt-4o"
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
}

struct AdminPendingInput: Sendable {
    let kind: AdminPendingInputKind
    let menuMessageID: Int
    let payload: String?
}
