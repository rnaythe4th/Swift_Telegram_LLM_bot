enum MainMenuAudience: String, Codable, CaseIterable, Sendable {
    case regular, premium, admin, superAdmin, group

    var label: String {
        switch self {
        case .regular: return "Обычные пользователи"
        case .premium: return "Пользователи с премиум-доступом"
        case .admin: return "Администраторы"
        case .superAdmin: return "Супер-администраторы"
        case .group: return "Групповые чаты"
        }
    }
}

enum MainMenuButton: String, Codable, CaseIterable, Sendable {
    // Declaration order defines the default reading order for both providers.
    case role, model, style, history, reasoning, search, listen, tuning, presets
    case separator, examples, purchase, addToGroup, referral, help, admin, superAdmin, close

    func belongs(to audience: MainMenuAudience) -> Bool {
        switch self {
        case .listen: return audience == .group
        case .referral: return audience != .group
        case .admin: return audience == .admin || audience == .superAdmin || audience == .group
        case .superAdmin: return audience == .superAdmin || audience == .group
        default: return true
        }
    }

    func isRequired(for audience: MainMenuAudience) -> Bool {
        self == .superAdmin && audience == .superAdmin
    }

    func visibleByDefault(for audience: MainMenuAudience) -> Bool {
        guard audience == .regular else { return true }
        switch self {
        case .examples, .purchase, .addToGroup, .referral: return false
        default: return true
        }
    }
}

enum MainMenuEdit: String, Sendable {
    case show, hide, up, down, reset
}

struct MainMenuEntry: Codable, Equatable, Sendable {
    let button: MainMenuButton
    var visible: Bool
}

struct MainMenuConfig: Codable, Sendable {
    private var overrides: [MainMenuAudience: [MainMenuEntry]] = [:]

    static func defaults(for audience: MainMenuAudience) -> [MainMenuEntry] {
        MainMenuButton.allCases.filter { $0.belongs(to: audience) }.map {
            MainMenuEntry(button: $0, visible: $0.visibleByDefault(for: audience))
        }
    }

    func entries(for audience: MainMenuAudience) -> [MainMenuEntry] {
        let defaults = Self.defaults(for: audience)
        guard let stored = overrides[audience] else { return defaults }
        var seen = Set<MainMenuButton>()
        let entries = stored.compactMap { entry -> MainMenuEntry? in
            guard entry.button.belongs(to: audience), seen.insert(entry.button).inserted else { return nil }
            return MainMenuEntry(button: entry.button, visible: entry.visible || entry.button.isRequired(for: audience))
        }
        return entries + defaults.filter { !seen.contains($0.button) }
    }

    mutating func apply(_ edit: MainMenuEdit, to button: MainMenuButton?, for audience: MainMenuAudience) -> Bool {
        let current = entries(for: audience)
        let defaults = Self.defaults(for: audience)
        var entries = current
        switch edit {
        case .reset:
            entries = defaults
        case .show, .hide, .up, .down:
            guard let button, let index = entries.firstIndex(where: { $0.button == button }) else { return false }
            if edit == .show || edit == .hide {
                entries[index].visible = edit == .show || button.isRequired(for: audience)
            } else {
                let target = index + (edit == .up ? -1 : 1)
                guard entries.indices.contains(target) else { return false }
                entries.swapAt(index, target)
            }
        }
        guard current != entries else { return false }
        overrides[audience] = entries == defaults ? nil : entries
        return true
    }
}
