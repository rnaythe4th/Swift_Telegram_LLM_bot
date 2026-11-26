import Foundation

// Page dispatch and shared access checks.

extension BotMenuHandler {
    func renderPage(
        _ page: MenuPage,
        chatKey: ChatKey,
        invoker: UserKey? = nil,
        purchaseBack: MenuPage = .main
    ) async -> MenuScreen {
        // Second line of defence for the paths that render without a callback
        // (a menu refreshed after text input): a personal page never draws its
        // contents into a group message.
        if page.isPersonal, chatKey.chatID.isGroup {
            var rows: Keyboard = []
            if !botUsername.isEmpty {
                rows.row([InlineKeyboardButton(text: "💬 Открыть бота", url: "https://t.me/\(botUsername)")])
            }
            rows.row(navButtons())
            return MenuScreen(page.privateOnlyNotice, rows)
        }
        // Same second line of defence for every gated page, not just the two
        // that used to be listed here. This path renders without a callback (a
        // menu redrawn after a typed value), minutes after the button was
        // tapped — long enough for a licence to lapse or a super-admin to be
        // removed, and the page would have been drawn to them anyway.
        let access = await pageAccess(page, chatKey: chatKey)
        if !(await satisfies(access, chatKey: chatKey, invoker: invoker)) {
            var rows = Keyboard()
            if access == .paidAccess {
                rows.row([buyButton("⚡ Открыть тонкую настройку", source: .tuning)])
            }
            rows.row(navButtons())
            let refusal = access == page.access ? page.restrictedNotice : access.refusal
            return MenuScreen(refusal, rows)
        }
        switch page {
        case .main:
            return await renderMain(chatKey: chatKey, invoker: invoker)
        case .role:
            return await renderRole(chatKey: chatKey)
        case .model:
            return await renderModel(chatKey: chatKey, invoker: invoker)
        case .temp, .tuningTemp:
            return await renderTemp(chatKey: chatKey, fromTuning: page == .tuningTemp)
        case .stats:
            return await renderStats(chatKey: chatKey, invoker: invoker)
        case .history:
            return await renderHistory(chatKey: chatKey, invoker: invoker)
        case .provider:
            return await renderProvider(chatKey: chatKey)
        case .reasoning:
            return await renderReasoning(chatKey: chatKey)
        case .tuning:
            return await renderTuning(chatKey: chatKey, invoker: invoker)
        case .presets:
            return await renderPresets(chatKey: chatKey, invoker: invoker)
        case .listen:
            return await renderListen(chatKey: chatKey, invoker: invoker)
        case .helpPage:
            return await renderHelp(chatKey: chatKey)
        case .pay:
            return await renderPay(chatKey: chatKey, invoker: invoker, backTo: purchaseBack)
        case .adminPanel:
            return await renderAdminPanel(chatKey: chatKey, invoker: invoker)
        case .adminHelp:
            return renderAdminHelp()
        case .adminChats:
            return await renderAdminChats(chatKey: chatKey, invoker: invoker)
        case .adminUsers:
            return await renderAdminUsers(chatKey: chatKey, invoker: invoker)
        case .adminWhitelist:
            return await renderAdminWhitelist(chatKey: chatKey)
        case .adminDefaults:
            return await renderAdminDefaults(chatKey: chatKey)
        case .superAdmin:
            return await renderSuperAdmin(chatKey: chatKey)
        case .superAdminHelp:
            return renderSuperAdminHelp()
        case .superStars:
            return await renderSuperStars(chatKey: chatKey)
        case .superCrypto:
            return await renderSuperCrypto(chatKey: chatKey)
        case .superCard:
            return await renderSuperCard(chatKey: chatKey)
        case .superExternalPay:
            return await renderSuperExternalPay(chatKey: chatKey)
        case .superFreeModels:
            return await renderSuperFreeModels(chatKey: chatKey)
        case .superTenants:
            return await renderSuperTenants(chatKey: chatKey)
        case .superAdmins:
            return await renderSuperAdmins(chatKey: chatKey, invoker: invoker)
        case .superSimulate:
            return await renderSuperSimulate(chatKey: chatKey, invoker: invoker)
        case .superChats:
            return await renderSuperChats(chatKey: chatKey)
        case .superAds:
            return await renderSuperAds(chatKey: chatKey)
        case .superBalances:
            return await renderSuperBalances(chatKey: chatKey)
        case .superFunnel:
            return await renderSuperFunnel(chatKey: chatKey)
        case .superReminders:
            return await renderSuperReminders(chatKey: chatKey)
        case .superOnboarding:
            return await renderSuperOnboarding(chatKey: chatKey)
        case .superModes:
            return await renderSuperModes(chatKey: chatKey)
        case .superReferrals:
            return await renderSuperReferrals(chatKey: chatKey)
        case .superTraffic:
            return await renderSuperTraffic(chatKey: chatKey)
        case .superSpend:
            return await renderSpendPolicy()
        case .referral:
            // Private chats only (guarded at the nav gate): the DM's id names
            // the person whose link and wallet the page is about.
            return await renderReferral(chatKey: chatKey, userID: chatKey.chatID.asUserID ?? UserID(chatKey.chatID.value))
        case .adminInvite:
            return await renderAdminInvite(chatKey: chatKey, invoker: invoker)
        case .close:
            return MenuScreen("Меню закрыто. Откройте снова — /menu", [])
        }
    }

}
