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
    /// Payer's `UserKey` (§6) — never a raw @invoker.
    let payerKey: UserKey
    /// Referral bonuses and traffic attribution are keyed by userID. A pending
    /// record (someone the bot has only been told about) has none, and then
    /// those two steps simply have nothing to look up.
    let payerUserID: UserID?
    /// Chat the purchase was made from: what a subscription may claim, and
    /// where the confirmation goes.
    let chatID: ChatID
    let purpose: PurchasePurpose
    /// Vendor-side identifier: Telegram charge id, tx hash, gateway payment id.
    /// The whole point of the dedup, because every one of those transports
    /// redelivers.
    let idempotencyKey: String
    /// Which rail brought the money — recorded so the payment table can answer
    /// "where did this come from" without a join through three other places.
    let method: PaymentMethod
}

/// The rails a payment can arrive on.
enum PaymentMethod: String, Sendable, CaseIterable {
    case stars
    case card
    case crypto
    case external
    /// Super-admin simulation (`/simulate buy`), so a test purchase is visible
    /// as such in the payments table instead of looking like real revenue.
    case simulated
}

/// Outcome, for the caller to turn into the message its channel needs — the
/// wording differs per method ("принято 9.99 USDT", "оплата получена"), the
/// bookkeeping does not.
enum PaymentFulfillmentOutcome: Sendable {
    /// Seen before: nothing was applied, nothing should be announced.
    case duplicate
    /// The database refused the write, so nothing was applied *and* nothing was
    /// marked processed. The transport will deliver again; until then the
    /// caller must not tell anyone the purchase worked.
    case failed
    case subscription(activation: SubscriptionActivation, claim: ChatContextStore.ChatClaimOutcome)
    case credit(cents: Int, wallet: UserBalance)
}

/// What the money transaction actually committed, for the cache to mirror.
struct CommittedPayment: Sendable {
    let subscription: SubscriptionExtension?
    let wallet: UserBalance?
}

/// All fields are `let` and every one of them is `Sendable`, so the type is
/// concurrency-safe by construction rather than by assertion.
final class PaymentFulfillmentService: Sendable {
    private let state: ChatContextStore
    private let telegram: TelegramGatewayPort
    private let ledger: LedgerPort
    private let persistence: PersistenceCoordinator?
    private let metrics: RuntimeMetrics
    private let logger: LoggerPort
    /// The last gate before money is applied (§4.3). `pre_checkout_query` and
    /// the purchase page ask the same question earlier, but they only cover the
    /// rails that go through Telegram: crypto arrives from a blockchain poller
    /// and the hosted checkout from an HTTP endpoint, neither of which passes
    /// through either. Asking here covers every rail there is and every one
    /// added later.
    private let durability: LockedValue<StateDurability>

    init(
        state: ChatContextStore,
        telegram: TelegramGatewayPort,
        ledger: LedgerPort,
        persistence: PersistenceCoordinator?,
        metrics: RuntimeMetrics,
        logger: LoggerPort,
        durability: LockedValue<StateDurability> = LockedValue(.durable)
    ) {
        self.state = state
        self.telegram = telegram
        self.ledger = ledger
        self.persistence = persistence
        self.metrics = metrics
        self.logger = logger
        self.durability = durability
    }

    /// Applies a payment and returns what it bought. Everything is committed
    /// before this returns, so a caller may announce the purchase without
    /// wondering whether a SIGTERM in the next second would take it back.
    ///
    /// The order matters and is the whole reason this method exists:
    ///
    /// 1. **Claim, credit and extend inside one transaction.** The idempotency
    ///    key is taken by `insert … on conflict do nothing returning`, so the
    ///    check and the claim are one statement and a redelivery cannot slip
    ///    between them — not on another task, not in another process. The money
    ///    the payment moves is written in the same transaction: either the
    ///    person has the subscription (or the credit) and the payment is
    ///    recorded, or neither happened.
    /// 2. **Mirror it into memory.** The store is a cache for wallets and
    ///    subscription dates now; it is updated from what the database
    ///    committed, never the other way round.
    /// 3. **The rest is write-behind.** Chat claim, winback consumption, funnel
    ///    counters, referral bookkeeping and traffic attribution are not money
    ///    leaving anyone's pocket, and the claim already guarantees they run at
    ///    most once per payment.
    func fulfil(_ receipt: PaymentReceipt) async -> PaymentFulfillmentOutcome {
        // Applying a payment into a memory that dies with the process is the
        // one thing worse than not applying it: the money is gone and there is
        // nothing left that says it arrived. `.failed` is exactly the right
        // answer here — every transport already knows to keep its door open on
        // it (Telegram redelivers for 24 hours, crypto leaves the invoice open
        // and holds its cursor, the aggregator is not acknowledged), so the
        // payment lands intact once storage is back.
        let durability = durability.value
        guard durability.acceptsPayments else {
            await metrics.increment(MetricName.paymentsRefusedVolatile)
            logger.error(
                "not applying payment \(receipt.idempotencyKey): state is \(durability.statusLine)"
                + " — awaiting redelivery"
            )
            return .failed
        }

        let defaults = await state.tenantDefaults(forKey: receipt.payerKey)
        let referralBonusDue = await state.pendingReferralPaymentBonus(payerUserID: receipt.payerUserID)

        let committed: CommittedPayment?
        do {
            committed = try await ledger.inTransaction { transaction in
                guard try await transaction.claimPayment(receipt) else { return nil }
                switch receipt.purpose {
                case .subscription:
                    let extended = try await transaction.extendSubscription(
                        receipt.payerKey,
                        days: ChatContextStore.subscriptionDays,
                        defaults: defaults
                    )
                    // A winback offer is one-shot; clearing it belongs to the
                    // same commit as the price it discounted.
                    try await transaction.setWinbackDiscount(receipt.payerKey, nil)
                    return CommittedPayment(subscription: extended, wallet: nil)
                case .credit(let cents):
                    let wallet = try await transaction.credit(
                        receipt.payerKey,
                        .cents(cents),
                        kind: .topup,
                        purchased: true,
                        ref: receipt.idempotencyKey
                    )
                    return CommittedPayment(subscription: nil, wallet: wallet)
                }
            }
        } catch {
            // Nothing was committed, so nothing is announced and the payment is
            // not marked processed: the next delivery (Telegram retries for 24
            // hours, the aggregator until acknowledged) will apply it.
            logger.error("payment \(receipt.idempotencyKey) could not be committed, will retry on redelivery: \(error)")
            await metrics.increment(MetricName.persistenceErrors)
            return .failed
        }

        guard let committed else {
            await metrics.increment(MetricName.paymentsDeduplicated)
            logger.info("duplicate payment ignored (\(receipt.idempotencyKey))")
            return .duplicate
        }

        // The conversion bonus is money too, so it goes through the ledger — in
        // its own transaction, because failing to pay a bonus must not undo a
        // subscription somebody already paid for.
        var referralBonus: ReferralPaymentBonus?
        if let due = referralBonusDue, let friendUserID = receipt.payerUserID {
            do {
                // The claim, not the record's timestamp, is what makes this
                // once-only: the timestamp is write-behind state, and a crash
                // between crediting and flushing it would pay again.
                let paid = try await ledger.inTransaction { transaction in
                    guard try await transaction.claim("refbonus:\(friendUserID)") else { return false }
                    try await transaction.credit(
                        UserKey.identified(due.inviterUserID),
                        due.amount,
                        kind: .referral,
                        purchased: false,
                        ref: "refbonus:\(friendUserID)"
                    )
                    return true
                }
                if paid {
                    referralBonus = await state.redeemReferralPaymentBonus(payerUserID: friendUserID)
                    if let referralBonus {
                        await state.applyCommittedCredit(
                            key: UserKey.identified(referralBonus.inviterUserID),
                            amount: referralBonus.amount
                        )
                    }
                }
            } catch {
                logger.error("referral conversion bonus for \(due.inviterLabel) not credited: \(error)")
            }
        }

        let outcome = await state.applyCommittedPayment(receipt, committed: committed)
        if let userID = receipt.payerUserID {
            await state.recordTrafficSourcePayment(userID: userID)
        }
        await metrics.increment(MetricName.paymentsProcessed)
        // The write-behind half is flushed straight away as well: the money is
        // already durable, but the chat claim and the funnel should not wait
        // out a debounce that a redeploy could cut short.
        await persistence?.flushNow()

        if let referralBonus {
            await announceReferralBonus(referralBonus)
        }
        return outcome
    }

    /// Tells an inviter their friend converted. The money is already on their
    /// balance, so a failed DM (blocked bot, never wrote to it) costs nothing
    /// but the good news.
    private func announceReferralBonus(_ bonus: ReferralPaymentBonus) async {
        let delivered = (try? await telegram.sendMessage(.init(
            chatID: bonus.inviterUserID.privateChat,
            threadID: nil,
            replyTo: nil,
            text: ReferralPresenter.paymentBonusText(bonus),
            replyMarkup: ReferralPresenter.paymentBonusMarkup()
        ))) != nil
        if !delivered {
            logger.warning("referral: could not notify \(bonus.inviterLabel) about the conversion bonus")
        }
        logger.info("referral conversion bonus: \(bonus.inviterLabel) +\(bonus.amount) (friend \(bonus.friendLabel))")
    }
}
