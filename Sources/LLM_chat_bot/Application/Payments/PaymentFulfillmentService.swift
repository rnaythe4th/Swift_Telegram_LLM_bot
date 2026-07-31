import Foundation

// What happens after money actually arrives — once, for every payment method.
//
// The list is long, every item is invisible when skipped, and each one is
// somebody's money: idempotency, activation or credit, the chat claim that must
// not steal a sponsor's group, the one-shot winback discount, funnel counters,
// the referral conversion bonus, paid-traffic attribution and the write-through
// flush that has to happen *before* anyone is told (CLAUDE.md §7, §17).
//
// It used to be copied per method, and the documentation had to warn that a new
// payment path "forgetting" traffic attribution silently zeroes a campaign's
// CAC. A new payment path now gets the whole list by construction: build a
// `PaymentReceipt`, hand it over, render the message from what comes back.

/// What was bought, by whom, and how the payment is deduplicated.
struct PaymentReceipt: Sendable {
    /// Payer's `UserKey` (§6) — never a raw @username.
    let payerKey: String
    /// Referral bonuses and traffic attribution are keyed by userID. A pending
    /// record (someone the bot has only been told about) has none, and then
    /// those two steps simply have nothing to look up.
    let payerUserID: Int?
    /// Chat the purchase was made from: what a subscription may claim, and
    /// where the confirmation goes.
    let chatID: Int
    let purpose: PurchasePurpose
    /// Vendor-side identifier: Telegram charge id, tx hash, gateway payment id.
    /// The whole point of the dedup, because every one of those transports
    /// redelivers.
    let idempotencyKey: String
}

/// Outcome, for the caller to turn into the message its channel needs — the
/// wording differs per method ("принято 9.99 USDT", "оплата получена"), the
/// bookkeeping does not.
enum PaymentFulfillmentOutcome: Sendable {
    /// Seen before: nothing was applied, nothing should be announced.
    case duplicate
    case subscription(activation: SubscriptionActivation, claim: ChatContextStore.ChatClaimOutcome)
    case credit(cents: Int, wallet: UserBalance)
}

final class PaymentFulfillmentService: @unchecked Sendable {
    private let state: ChatContextStore
    private let telegram: TelegramGatewayPort
    private let persistence: PersistenceCoordinator?
    private let metrics: RuntimeMetrics
    private let logger: LoggerPort

    init(
        state: ChatContextStore,
        telegram: TelegramGatewayPort,
        persistence: PersistenceCoordinator?,
        metrics: RuntimeMetrics,
        logger: LoggerPort
    ) {
        self.state = state
        self.telegram = telegram
        self.persistence = persistence
        self.metrics = metrics
        self.logger = logger
    }

    /// Applies a payment and returns what it bought. Everything is persisted
    /// before this returns, so a caller may announce the purchase without
    /// wondering whether a SIGTERM in the next second would take it back.
    func fulfil(_ receipt: PaymentReceipt) async -> PaymentFulfillmentOutcome {
        if await state.isPaymentProcessed(chargeID: receipt.idempotencyKey) {
            await metrics.increment(MetricName.paymentsDeduplicated)
            logger.info("duplicate payment ignored (\(receipt.idempotencyKey))")
            return .duplicate
        }

        let outcome: PaymentFulfillmentOutcome
        switch receipt.purpose {
        case .subscription:
            let activation = await state.activatePaidSubscription(username: receipt.payerKey)
            // Never move a group away from a sponsor who is still paying for it
            // (§7 «Спонсор-герой»): a purchase buys the buyer access, not
            // somebody else's chat.
            let claim = await state.claimChatForPayment(chatID: receipt.chatID, payerKey: receipt.payerKey)
            // A winback offer is one-shot: consume it whether or not it was
            // still valid, and count the ones that brought the payment back.
            if await state.consumeWinbackDiscount(username: receipt.payerKey) != nil {
                await state.bumpFunnel(.winbackRedeemed)
            }
            switch activation {
            case .started: await state.bumpFunnel(.paid)
            case .extended: await state.bumpFunnel(.renewed)
            case .alreadyUnlimited: break
            }
            outcome = .subscription(activation: activation, claim: claim)

        case .credit(let cents):
            // `creditPurchasedBalance`, never `creditBalance`: only it records
            // that real money was paid, which is what makes a lapsed wallet
            // worth a comeback offer later (§7).
            let wallet = await state.creditPurchasedBalance(key: receipt.payerKey, amountUsd: Double(cents) / 100.0)
            await state.bumpFunnel(.creditTopup)
            outcome = .credit(cents: cents, wallet: wallet)
        }

        await state.markPaymentProcessed(chargeID: receipt.idempotencyKey)

        // Referral (§7): a friend who pays is what the programme is for. Both
        // this and the traffic attribution below run *before* the flush, so the
        // bonus and the campaign credit are as durable as the payment.
        let referralBonus = await redeemReferralBonus(userID: receipt.payerUserID)
        if let userID = receipt.payerUserID {
            await state.recordTrafficSourcePayment(userID: userID)
        }
        await metrics.increment(MetricName.paymentsProcessed)
        // Payments never wait out the 2s debounce.
        await persistence?.flushNow()

        if let referralBonus {
            await announceReferralBonus(referralBonus)
        }
        return outcome
    }

    private func redeemReferralBonus(userID: Int?) async -> ReferralPaymentBonus? {
        guard let userID else { return nil }
        return await state.redeemReferralPaymentBonus(payerUserID: userID)
    }

    /// Tells an inviter their friend converted. The money is already on their
    /// balance, so a failed DM (blocked bot, never wrote to it) costs nothing
    /// but the good news.
    private func announceReferralBonus(_ bonus: ReferralPaymentBonus) async {
        let delivered = (try? await telegram.sendMessage(.init(
            chatID: bonus.inviterUserID,
            threadID: nil,
            replyTo: nil,
            text: ReferralPresenter.paymentBonusText(bonus),
            replyMarkup: ReferralPresenter.paymentBonusMarkup()
        ))) != nil
        if !delivered {
            logger.warning("referral: could not notify \(bonus.inviterLabel) about the conversion bonus")
        }
        logger.info("referral conversion bonus: \(bonus.inviterLabel) +$\(bonus.amountUsd) (friend \(bonus.friendLabel))")
    }
}
