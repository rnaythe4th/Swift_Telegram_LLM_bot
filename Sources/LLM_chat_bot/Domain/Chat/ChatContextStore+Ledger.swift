import Foundation

// The cache side of money (§3.2).
//
// Wallets and subscription end dates are owned by the database now: they are
// written inside a transaction, and what lands here is a mirror of what was
// committed. Reads stay synchronous on the actor — hundreds of call sites ask
// "does this person have access?" on every turn, and a round trip for each of
// them would buy nothing: the advisory lock (§3.1) guarantees this process is
// the only writer, so the cache cannot go stale behind our back.
//
// Nothing in this file decides anything about money. It records decisions the
// database has already made.

extension ChatContextStore {
    /// What a tenant row needs if this payment is the one that creates it.
    func tenantDefaults(forKey key: UserKey) -> TenantDefaults {
        let source = tenants[key] ?? tenants[defaultOwnerKey]
        return TenantDefaults(
            ownerKey: key,
            model: source?.defaultModel ?? initialDefaultModel,
            role: source?.defaultRole ?? initialDefaultRole,
            historyLength: source?.defaultHistoryLength ?? initialDefaultHistoryLength
        )
    }

    /// The referral conversion bonus this payer would earn their inviter, or
    /// nil. Read before the payment commits so the amount can travel in the
    /// same ledger call; the record is only *stamped* afterwards, by
    /// `redeemReferralPaymentBonus`, which is what makes it once-only.
    func pendingReferralPaymentBonus(payerUserID: Int?) -> ReferralPaymentBonus? {
        guard let payerUserID else { return nil }
        let config = referralConfigValue
        guard config.enabled, config.payingFriendBonusCents > 0 else { return nil }
        guard let record = referralLedgerValue.records[String(payerUserID)], record.paidBonusAt == nil else {
            return nil
        }
        let tally = referralLedgerValue.tallies[String(record.inviterUserID)]
        return ReferralPaymentBonus(
            inviterUserID: record.inviterUserID,
            inviterLabel: displayLabel(forUserID: record.inviterUserID),
            friendLabel: displayLabel(forUserID: payerUserID),
            amount: config.payingFriendBonus,
            inviterPaidTotal: (tally?.paidConversions ?? 0) + 1
        )
    }

    /// Mirrors a committed payment into memory and does the bookkeeping that is
    /// not money: the chat claim, the funnel, the winback counter.
    func applyCommittedPayment(_ receipt: PaymentReceipt, committed: CommittedPayment) -> PaymentFulfillmentOutcome {
        if let wallet = committed.wallet {
            userBalances[receipt.payerKey] = wallet
            if case .credit(let cents) = receipt.purpose {
                bumpFunnel(.creditTopup)
                return .credit(cents: cents, wallet: wallet)
            }
            return .credit(cents: 0, wallet: wallet)
        }

        guard let subscription = committed.subscription else {
            return .credit(cents: 0, wallet: userBalances[receipt.payerKey] ?? .empty)
        }

        if tenants[receipt.payerKey] == nil {
            registerTenant(receipt.payerKey)
        }
        let hadDiscount = tenants[receipt.payerKey]?.winbackDiscount
        mutateTenantByOwner(receipt.payerKey) { tenant in
            tenant.paidUntil = subscription.paidUntil
            tenant.winbackDiscount = nil
        }

        // Never move a group away from a sponsor who is still paying for it
        // (§7 «Спонсор-герой»): a purchase buys the buyer access, not somebody
        // else's chat.
        let claim = claimChatForPayment(chatID: receipt.chatID, payerKey: receipt.payerKey)

        // A winback offer that was still valid at checkout is a conversion.
        if let hadDiscount, hadDiscount.isActive(grace: Self.checkoutDiscountGrace) {
            bumpFunnel(.winbackRedeemed)
        }

        let activation: SubscriptionActivation
        if subscription.wasUnlimited {
            activation = .alreadyUnlimited
        } else if subscription.isNew {
            activation = .started(until: subscription.paidUntil ?? Date())
            bumpFunnel(.paid)
        } else {
            activation = .extended(until: subscription.paidUntil ?? Date())
            bumpFunnel(.renewed)
        }
        return .subscription(activation: activation, claim: claim)
    }

    /// Mirrors a committed wallet credit that was not a purchase — a referral
    /// reward, a super-admin grant. Only the cache moves; the row was already
    /// written by the transaction, so this must **not** mark the wallet dirty
    /// or the write-behind sync would add the same money a second time.
    func applyCommittedCredit(key: UserKey, amount: Money) {
        guard amount.isPositive else { return }
        var wallet = userBalances[key] ?? .empty
        wallet.balance += amount
        wallet.updatedAt = Date()
        userBalances[key] = wallet
    }

    /// Mirrors a committed charge for one answer.
    func applyCommittedCharge(key: UserKey, debit: WalletDebit, real: Money) {
        guard var wallet = userBalances[key] else { return }
        wallet.balance = debit.remaining
        wallet.spentBilled += debit.charged
        wallet.spentReal += real
        wallet.updatedAt = Date()
        userBalances[key] = wallet
        if debit.depleted { bumpFunnel(.balanceEmpty) }
    }
}
