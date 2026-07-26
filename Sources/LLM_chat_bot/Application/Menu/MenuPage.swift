import Foundation

// Every page of the inline menu. The raw value is what travels in
// callback_data (`menu:nav:<page>`).

enum MenuPage: String {
    case main
    case role
    case model
    case temp
    case stats
    case history
    case provider
    case reasoning
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
