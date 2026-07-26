import Foundation

// Two-sided referral: binding, payouts, anti-fraud and the ledger.

extension ChatContextStore {
    // MARK: - Two-sided referral (roadmap step 10)

    func referralConfig() -> ReferralConfig { referralConfigValue }

    func setReferralConfig(_ config: ReferralConfig) {
        referralConfigValue = config.normalized
        dirtyConfigs.insert(.referrals)
    }

    private func markReferralLedgerDirty() {
        referralLedgerValue.prune()
        dirtyConfigs.insert(.referralLedger)
    }

    /// Display label of a user we know by ID — for referral texts, which name
    /// the other side of the pair.
    func displayLabel(forUserID userID: Int) -> String {
        userDirectoryValue.displayLabel(forKey: UserKey.forUserID(userID))
    }

    /// Whether we have ever met this person. Used to refuse a referral link
    /// carrying a userID that was never seen (a made-up or mistyped one).
    private func isKnownUser(_ userID: Int) -> Bool {
        userDirectoryValue.identity(userID: userID) != nil || chatMetaByID[userID] != nil
    }

    /// True when this person has used the bot before — the "new user only"
    /// anti-fraud rule. Signals: a private chat that already produced turns, an
    /// owned licence, or a wallet.
    func hasPriorBotActivity(userID: Int, username: String?) -> Bool {
        if let context = contexts[ChatKey(chatID: userID, threadID: 0)] {
            // `ensure` seeds history with the system message, so "used before"
            // means more than that one entry.
            if context.funnelFirstMessageCounted
                || context.cumulativeUsage.generationCount > 0
                || context.history.count > 1 { return true }
        }
        if userTenantMap[userID] != nil { return true }
        // Check both the permanent key and any record still pending under the
        // username they arrived with.
        var keys = [UserKey.forUserID(userID)]
        if let pending = UserKey.pending(username) { keys.append(pending) }
        for key in keys {
            if tenants[key] != nil { return true }
            if userBalances[key] != nil { return true }
        }
        return false
    }

    /// Attributes a new user to the inviter behind a `ref_` deep link. Pays
    /// nothing yet: the reward lands after the friend's first real answer
    /// (`redeemReferralIfDue`), which is what makes farming expensive.
    func bindReferral(invitedUserID: Int, invitedUsername: String?, inviterUserID: Int) -> ReferralBindOutcome {
        let config = referralConfigValue
        guard config.enabled else { return .disabled }
        guard invitedUserID != inviterUserID else {
            referralLedgerValue.refusedSelf += 1
            markReferralLedgerDirty()
            return .selfInvite
        }

        let invitedKey = String(invitedUserID)
        if let existing = referralLedgerValue.records[invitedKey] {
            referralLedgerValue.refusedRepeat += 1
            markReferralLedgerDirty()
            return .alreadyBound(inviter: existing.inviterUsername)
        }

        // A link the bot has never seen a matching person for is refused: there
        // is no wallet to pay into. No @username is needed on either side —
        // wallets are keyed by userID.
        guard isKnownUser(inviterUserID) else {
            referralLedgerValue.refusedUnknown += 1
            markReferralLedgerDirty()
            return .unknownInviter
        }
        let inviterLabel = displayLabel(forUserID: inviterUserID)
        let invited = UserKey.pending(invitedUsername)

        guard !hasPriorBotActivity(userID: invitedUserID, username: invitedUsername) else {
            referralLedgerValue.refusedNotNew += 1
            markReferralLedgerDirty()
            return .notNewUser
        }

        referralLedgerValue.records[invitedKey] = ReferralRecord(
            inviterUserID: inviterUserID,
            inviterUsername: inviterLabel,
            invitedUsername: invited
        )
        var tally = referralLedgerValue.tallies[String(inviterUserID)] ?? ReferralTally(username: inviterLabel)
        tally.username = inviterLabel
        tally.invited += 1
        referralLedgerValue.tallies[String(inviterUserID)] = tally
        markReferralLedgerDirty()
        bumpFunnel(.referralJoined)

        // The cap is checked again at payout time (it may be raised meanwhile),
        // but a friend who arrives past it must not be told about money that
        // will never come — the attribution still stands, only the promise goes.
        let cap = config.maxRewardsPerInviter
        if cap > 0, tally.rewarded >= cap {
            return .boundWithoutReward(inviter: inviterLabel)
        }
        return .bound(inviter: inviterLabel, inviteeRewardUsd: config.inviteeRewardUsd)
    }

    /// Pays a pending referral pair once the invited user has produced their
    /// first real answer. Credits both wallets and resolves the record in one
    /// actor step, so a crash can never leave money credited twice or a pair
    /// half-paid. Returns nil when there is nothing to pay.
    func redeemReferralIfDue(userID: Int, username: String?) -> ReferralPayout? {
        let config = referralConfigValue
        guard config.enabled else { return nil }
        let key = String(userID)
        guard var record = referralLedgerValue.records[key], record.isPending else { return nil }

        // Both wallets are addressed by userID, so a missing or changed
        // @username can no longer hold a payout back — the labels below are
        // only what the notifications will say.
        let invited = UserKey.pending(username) ?? record.invitedUsername
        if let invited { record.invitedUsername = invited }
        record.inviterUsername = displayLabel(forUserID: record.inviterUserID)

        var tally = referralLedgerValue.tallies[String(record.inviterUserID)]
            ?? ReferralTally(username: record.inviterUsername)
        tally.username = record.inviterUsername

        // Anti-farming cap: beyond it the pair resolves without a payout, so it
        // is never retried, and the refusal stays visible to the super-admin.
        let cap = config.maxRewardsPerInviter
        if cap > 0, tally.rewarded >= cap {
            record.rewardedAt = Date()
            record.blocked = true
            tally.blocked += 1
            referralLedgerValue.records[key] = record
            referralLedgerValue.tallies[String(record.inviterUserID)] = tally
            markReferralLedgerDirty()
            return nil
        }

        let inviterReward = config.inviterRewardUsd
        let inviteeReward = config.inviteeRewardUsd
        if inviterReward > 0 {
            creditBalance(key: UserKey.forUserID(record.inviterUserID), amountUsd: inviterReward)
        }
        if inviteeReward > 0 {
            creditBalance(key: UserKey.forUserID(userID), amountUsd: inviteeReward)
        }

        record.rewardedAt = Date()
        record.inviterRewardUsd = inviterReward
        record.inviteeRewardUsd = inviteeReward
        tally.rewarded += 1
        tally.earnedUsd += inviterReward
        referralLedgerValue.paidOutUsd += inviterReward + inviteeReward
        referralLedgerValue.records[key] = record
        referralLedgerValue.tallies[String(record.inviterUserID)] = tally
        markReferralLedgerDirty()
        bumpFunnel(.referralRewarded)

        return ReferralPayout(
            inviterUserID: record.inviterUserID,
            inviterUsername: record.inviterUsername,
            inviterRewardUsd: inviterReward,
            invitedUsername: invited,
            invitedLabel: displayLabel(forUserID: userID),
            inviteeRewardUsd: inviteeReward,
            inviterRewardedTotal: tally.rewarded
        )
    }

    /// Pays the inviter their one-off bonus the first time their invited friend
    /// actually spends money (subscription or credit pack). Credits the wallet
    /// and stamps the record in one actor step, so a redelivered payment cannot
    /// pay twice. Returns nil when there is nothing to pay.
    ///
    /// The anti-farming cap deliberately does not apply: it exists to make
    /// farming *free* signups pointless, and this bonus only fires on money
    /// that already came in.
    func redeemReferralPaymentBonus(payerUserID: Int) -> ReferralPaymentBonus? {
        let config = referralConfigValue
        guard config.enabled, config.payingFriendBonusCents > 0 else { return nil }
        let key = String(payerUserID)
        guard var record = referralLedgerValue.records[key], record.paidBonusAt == nil else { return nil }

        let bonus = config.payingFriendBonusUsd
        record.inviterUsername = displayLabel(forUserID: record.inviterUserID)
        var tally = referralLedgerValue.tallies[String(record.inviterUserID)]
            ?? ReferralTally(username: record.inviterUsername)
        tally.username = record.inviterUsername

        creditBalance(key: UserKey.forUserID(record.inviterUserID), amountUsd: bonus)
        record.paidBonusAt = Date()
        record.paidBonusUsd = bonus
        tally.paidConversions += 1
        tally.earnedUsd += bonus
        referralLedgerValue.paidOutUsd += bonus
        referralLedgerValue.records[key] = record
        referralLedgerValue.tallies[String(record.inviterUserID)] = tally
        markReferralLedgerDirty()
        bumpFunnel(.referralPaidBonus)

        return ReferralPaymentBonus(
            inviterUserID: record.inviterUserID,
            inviterLabel: record.inviterUsername,
            friendLabel: displayLabel(forUserID: payerUserID),
            amountUsd: bonus,
            inviterPaidTotal: tally.paidConversions
        )
    }

    /// Personal referral state for the `/ref` page.
    func referralUserStats(userID: Int) -> ReferralUserStats {
        let tally = referralLedgerValue.tallies[String(userID)]
        let pending = referralLedgerValue.records.values
            .filter { $0.inviterUserID == userID && $0.isPending }
            .count
        let cap = referralConfigValue.maxRewardsPerInviter
        return ReferralUserStats(
            invited: tally?.invited ?? 0,
            rewarded: tally?.rewarded ?? 0,
            pending: pending,
            earnedUsd: tally?.earnedUsd ?? 0,
            paidConversions: tally?.paidConversions ?? 0,
            capRemaining: cap > 0 ? max(0, cap - (tally?.rewarded ?? 0)) : nil,
            incoming: referralLedgerValue.records[String(userID)]
        )
    }

    /// Program-wide numbers for the super-admin page and `/metrics`.
    func referralOverview(topLimit: Int = 5) -> ReferralOverview {
        let ledger = referralLedgerValue
        return ReferralOverview(
            bound: ledger.records.count,
            pending: ledger.pendingCount,
            rewarded: ledger.rewardedCount,
            blocked: ledger.blockedCount,
            paidOutUsd: ledger.paidOutUsd,
            inviters: ledger.tallies.count,
            top: ledger.topInviters(limit: topLimit),
            paidConversions: ledger.paidConversionCount,
            refusedSelf: ledger.refusedSelf,
            refusedRepeat: ledger.refusedRepeat,
            refusedNotNew: ledger.refusedNotNew,
            refusedUnknown: ledger.refusedUnknown
        )
    }

    /// Wipes attributions and aggregates (super-admin reset). Destructive: the
    /// "one attribution per person" guard forgets everyone, so previously
    /// invited users could be attributed again if they are still "new".
    @discardableResult
    func clearReferralLedger() -> Int {
        let count = referralLedgerValue.records.count
        referralLedgerValue = .empty
        dirtyConfigs.insert(.referralLedger)
        return count
    }
}
