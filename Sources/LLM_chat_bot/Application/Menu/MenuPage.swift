import Foundation

// Every page of the inline menu. The raw value is what travels in
// callback_data (`menu:nav:<page>`).

enum MenuPage: String, CaseIterable {
    case main
    case role
    case model
    case temp
    case stats
    case history
    case provider
    case reasoning
    /// Everything a mode sets by hand — model, style, memory, reasoning. Behind
    /// full access: a free user picks a reference mode, a paying one may take
    /// the settings apart.
    case tuning
    case helpPage = "help"
    case pay
    case adminPanel = "admin"
    case adminHelp = "adminhelp"
    case adminChats = "adminchats"
    case adminUsers = "adminusers"
    case adminWhitelist = "adminwl"
    case adminDefaults = "admindef"
    case superAdmin = "superadmin"
    case superAdminHelp = "superadminhelp"
    case superStars = "superstars"
    case superCrypto = "supercrypto"
    case superCard = "supercard"
    /// Hosted checkout: Сбер/СБП/карты/крипта through one aggregator (§7).
    case superExternalPay = "superextpay"
    case superFreeModels = "superfreemodels"
    case superTenants = "supertenants"
    case superAdmins = "superadmins"
    case superSimulate = "supersim"
    case superChats = "superchats"
    case superAds = "superads"
    case superBalances = "superbal"
    case superFunnel = "superfunnel"
    case superReminders = "superreminders"
    case superOnboarding = "superonboarding"
    case superModes = "supermodes"
    case superReferrals = "superref"
    case superTraffic = "supersrc"
    case referral = "ref"
    case adminInvite = "admininvite"
    case close

    /// Pages whose body belongs to one person: their invite link (anyone who
    /// reads it gets paid access at the owner's expense), their referral link,
    /// everyone's wallets. In a group the menu is a single shared message —
    /// whoever taps, all members read the result — so these are DM-only.
    var isPersonal: Bool {
        switch self {
        case .referral, .adminInvite, .superBalances: return true
        default: return false
        }
    }

    /// Pages a free-tier chat may not open: the hand-tuning of settings the
    /// reference modes own. Two reasons, and both matter.
    ///
    /// Money: memory length and reasoning are per-answer cost multipliers, and
    /// a free user turning them up spends the owner's money, not their own.
    /// Sales: "разобрать настройки по винтикам" is a real thing to sell, it
    /// costs nothing to give away with premium, and refusing it here is the
    /// only paywall a user meets *while already trying to do something*.
    ///
    /// Checked twice, like `isPersonal` — at `showPage` and again at
    /// `renderPage`, because a page can also be redrawn after a typed value.
    /// Note that `.tuning` itself is *not* here. It is the hub, and a free user
    /// must be able to open it and see what is inside: a locked door you can
    /// look through sells, a door that will not open at all just annoys — the
    /// same reason the ⭐ modes stay on the settings page.
    var requiresFullAccess: Bool {
        switch self {
        case .temp, .reasoning: return true
        default: return false
        }
    }

    /// Pages only whoever runs the bot may open: the super-admin, or the admin
    /// whose subscription pays for this chat. "Сервис ИИ" is plumbing — the
    /// wrong choice there silently disables reasoning and half the models, and
    /// no user has ever needed it.
    var requiresOperator: Bool {
        switch self {
        case .provider: return true
        default: return false
        }
    }

    var restrictedNotice: String {
        switch self {
        case .provider: return "🔒 Сервис ИИ настраивает владелец бота"
        default: return "⭐ Тонкая настройка — с премиумом или балансом"
        }
    }

    /// The settings page a preset category belongs to. Their raw values happen
    /// to coincide, which is exactly why this is spelled out: a renamed page
    /// should break the build, not the "← К выбору" button.
    init(category: PresetCategory) {
        switch category {
        case .model: self = .model
        case .temp: self = .temp
        case .history: self = .history
        case .role: self = .role
        }
    }

    /// Label of the button that leads *back* to this page. It lives next to
    /// the page rather than at each of the 30-odd call sites, so a button can
    /// no longer promise "← К супер-админу" and navigate somewhere else — and
    /// the same destination cannot end up with two different names, which is
    /// exactly what had happened to `.adminPanel`.
    var backLabel: String {
        switch self {
        case .superAdmin: return "← К супер-админу"
        case .adminPanel: return "← К моему премиуму"
        case .superTenants: return "← К тенантам"
        case .superChats: return "← К списку чатов"
        case .superAdminHelp: return "← К разделам справки"
        case .tuning: return "← К настройкам"
        // The four chat-setting pickers are only ever returned to from the
        // preset editor, where "back" means "back to picking one".
        case .model, .role, .temp, .history: return "← К выбору"
        default: return Texts.back
        }
    }

    var privateOnlyNotice: String {
        switch self {
        case .referral:
            return "🎁 Ссылка-приглашение личная — откройте её в личке с ботом: /ref"
        case .adminInvite:
            return "🔗 Ссылка-приглашение личная: по ней доступ выдаётся за ваш счёт. Откройте /menu в личке с ботом."
        case .superBalances:
            return "💰 Балансы — личные данные людей. Откройте /menu в личке с ботом."
        default:
            return "Эта страница доступна только в личке с ботом: /menu"
        }
    }
}
