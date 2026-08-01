import Foundation

/// Messages the referral program sends outside the generation pipeline
/// (roadmap step 10). Both payment paths — Telegram invoices and the crypto
/// monitor — announce a conversion bonus, so the copy lives in one place and
/// cannot drift between them.
enum ReferralPresenter {
    static func paymentBonusText(_ bonus: ReferralPaymentBonus) -> String {
        "💎 <b>Ваш друг \(bonus.friendLabel) оформил оплату — вам бонус"
            + " \(bonus.amount.formatted(fractionDigits: 2)) на баланс.</b>"
            + "\n\nПриглашённых, которые оплатили: <b>\(bonus.inviterPaidTotal)</b>."
            + "\n\nС баланса списывается стоимость каждого ответа, обычно доли цента, — подписка для этого не нужна."
    }

    static let inviteButton = InlineKeyboardButton(
        text: "🎁 Пригласить ещё",
        callback_data: BotCallbackAction.menu(action: MenuRoute.navigation(to: .referral)).rawData
    )

    static func paymentBonusMarkup() -> InlineKeyboardMarkup {
        InlineKeyboardMarkup(inline_keyboard: [[inviteButton]])
    }
}
