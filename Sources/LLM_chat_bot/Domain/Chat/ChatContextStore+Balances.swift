import Foundation

// Pay-as-you-go wallets: markup, charges, top-ups and lapsed-wallet
// winback.

extension ChatContextStore {
    // MARK: - Markup & balances (pay-as-you-go)

    func markupPercent() -> Int { markupPercentValue }

    func setMarkupPercent(_ percent: Int) {
        markupPercentValue = max(0, min(500, percent))
        dirtyConfigs.insert(.markup)
    }

    /// Daily free-premium "taste" allowance (roadmap step 6). Super-admin knob.
    func dailyPremiumLimit() -> Int { dailyPremiumLimitValue }

    func setDailyPremiumLimit(_ value: Int) {
        dailyPremiumLimitValue = max(0, min(100, value))
        dirtyConfigs.insert(.dailyPremiumLimit)
    }

    /// Multiplier applied to real provider cost for everything customers see
    /// and pay: 30% markup → 1.3.
    func priceMultiplier() -> Double {
        1.0 + Double(markupPercentValue) / 100.0
    }

    /// Customer-facing total for a usage record. Rows written before markup
    /// existed carry no billed value — approximate with the current rate.
    func billedCost(of usage: CumulativeUsage) -> Double {
        if usage.totalBilledCost > 0 { return usage.totalBilledCost }
        return usage.totalCost * priceMultiplier()
    }

    func balance(username: String?) -> UserBalance? {
        guard let u = userKey(username: username) else { return nil }
        return userBalances[u]
    }

    func hasPositiveBalance(username: String?) -> Bool {
        (balance(username: username)?.balanceUsd ?? 0) > 0
    }

    /// Key of the wallet that should pay for this person's answers, or nil when
    /// there is nothing to charge. Resolved by userID first, so a person with
    /// no @username still spends the balance they topped up.
    func billingKey(username: String?, userID: Int?) -> String? {
        userKeys(username: username, userID: userID)
            .first { (userBalances[$0]?.balanceUsd ?? 0) > 0 }
    }

    /// Adds (or subtracts, for corrections) to the user's balance. Creates the
    /// wallet on first credit.
    @discardableResult
    func creditBalance(username: String, amountUsd: Double) -> UserBalance {
        creditBalance(key: userKeyOrRaw(username), amountUsd: amountUsd)
    }

    /// Same, for a caller that already holds the person's key — the referral
    /// payout, which addresses wallets by userID and never by @username.
    @discardableResult
    func creditBalance(key: String, amountUsd: Double) -> UserBalance {
        var wallet = userBalances[key] ?? .empty
        wallet.balanceUsd += amountUsd
        wallet.updatedAt = Date()
        userBalances[key] = wallet
        dirtyConfigs.insert(.balances)
        return wallet
    }

    /// A credit pack the person actually paid for, as opposed to a referral
    /// bonus or a super-admin grant. Tracked separately because "has paid real
    /// money at least once" is what makes a lapsed wallet worth an offer, and
    /// what tells the super-admin who is a customer (§7 «Возврат по балансу»).
    /// Topping up also reopens the lapse cycle: coming back earns a new notice.
    @discardableResult
    func creditPurchasedBalance(username: String, amountUsd: Double) -> UserBalance {
        creditPurchasedBalance(key: userKeyOrRaw(username), amountUsd: amountUsd)
    }

    @discardableResult
    func creditPurchasedBalance(key: String, amountUsd: Double) -> UserBalance {
        var wallet = creditBalance(key: key, amountUsd: amountUsd)
        wallet.toppedUpUsd += amountUsd
        wallet.lapsedNoticeAt = nil
        userBalances[key] = wallet
        dirtyConfigs.insert(.balances)
        return wallet
    }

    // MARK: - Lapsed wallets (roadmap step 8, applied to pay-as-you-go)

    /// Wallets worth one "come back" offer: the person paid real money, spent
    /// it all, has no subscription covering them, has been quiet for at least
    /// `walletWinbackDays`, and has not been offered this before.
    ///
    /// The audience is intentionally narrow — proven payers only. Everyone else
    /// already meets an offer at the moment of pain (empty balance, daily cap),
    /// and an unsolicited broadcast to free users buys nothing but blocks.
    func dueWalletWinbacks(now: Date = Date()) -> [WalletWinbackTarget] {
        let config = reminderConfigValue
        guard config.enabled, config.walletWinbackDays > 0 else { return [] }
        let idleCutoff = Double(config.walletWinbackDays) * 86_400
        var targets: [WalletWinbackTarget] = []

        for (key, wallet) in userBalances {
            guard wallet.toppedUpUsd > 0, wallet.lapsedNoticeAt == nil else { continue }
            // The bot's owners are not sold the bot's own product — same rule
            // the subscription sweep follows.
            guard !superAdminUsernames.contains(key) else { continue }
            // Still has money, or is covered by a subscription: not lapsed.
            guard wallet.balanceUsd <= Self.lapsedWalletThresholdUsd else { continue }
            if let tenant = tenants[key] {
                if tenant.isActive || tenant.remindersOptOut { continue }
            }
            guard let userID = UserKey.userID(from: key),
                  let chatID = privateChatID(forKey: key) else { continue }
            // Idle for long enough. `seenAt` is refreshed on every update, so
            // somebody who is still around never lands here.
            let lastSeen = userDirectoryValue.identity(userID: userID)?.seenAt ?? wallet.updatedAt
            guard let lastSeen, now.timeIntervalSince(lastSeen) >= idleCutoff else { continue }

            targets.append(WalletWinbackTarget(
                key: key,
                label: displayLabel(forKey: key),
                privateChatID: chatID,
                toppedUpUsd: wallet.toppedUpUsd,
                idleDays: max(1, Int(now.timeIntervalSince(lastSeen) / 86_400))
            ))
        }
        return targets.sorted { $0.toppedUpUsd > $1.toppedUpUsd }
    }

    /// A wallet is "empty enough" below this: sub-cent dust is not money.
    static let lapsedWalletThresholdUsd = 0.01

    /// Stamps a delivered lapsed-wallet offer, so it goes out once per lapse.
    /// Only called after a successful send — a failed one is retried next sweep.
    @discardableResult
    func markWalletWinbackSent(key: String, now: Date = Date()) -> Bool {
        guard var wallet = userBalances[key] else { return false }
        wallet.lapsedNoticeAt = now
        userBalances[key] = wallet
        dirtyConfigs.insert(.balances)
        return true
    }

    /// How many wallets are lapsed right now, and how many already heard from
    /// us — the monitoring line on the super-admin reminders page.
    func lapsedWalletStats(now: Date = Date()) -> (due: Int, notified: Int, payers: Int) {
        var notified = 0
        var payers = 0
        for wallet in userBalances.values where wallet.toppedUpUsd > 0 {
            payers += 1
            if wallet.lapsedNoticeAt != nil { notified += 1 }
        }
        return (dueWalletWinbacks(now: now).count, notified, payers)
    }

    @discardableResult
    func setBalanceAmount(username: String, amountUsd: Double) -> UserBalance {
        let u = userKeyOrRaw(username)
        var wallet = userBalances[u] ?? .empty
        wallet.balanceUsd = amountUsd
        wallet.updatedAt = Date()
        userBalances[u] = wallet
        dirtyConfigs.insert(.balances)
        return wallet
    }

    @discardableResult
    func removeBalance(username: String) -> Bool {
        let removed = userBalances.removeValue(forKey: userKeyOrRaw(username)) != nil
        if removed { dirtyConfigs.insert(.balances) }
        return removed
    }

    func allBalances() -> [(key: String, label: String, wallet: UserBalance)] {
        userBalances
            .map { (key: $0.key, label: displayLabel(forKey: $0.key), wallet: $0.value) }
            .sorted { $0.label < $1.label }
    }

    /// What the footer will show as the post-charge balance. The actual charge
    /// happens in `appendAssistant`; formula is identical.
    func projectedBalanceAfterCharge(username: String, realCost: Double) -> Double {
        let current = userBalances[userKeyOrRaw(username)]?.balanceUsd ?? 0
        return current - realCost * priceMultiplier()
    }

    /// Returns true when this charge is the one that emptied the wallet — the
    /// caller turns that into a single "top up" pitch at the pain point
    /// (roadmap step 5). Subsequent turns bill nobody (`billingKey` requires a
    /// positive balance), so this can only fire once per top-up cycle.
    @discardableResult
    func chargeBalance(username: String, billedUsd: Double, realUsd: Double) -> Bool {
        guard billedUsd > 0 else { return false }
        let u = userKeyOrRaw(username)
        var wallet = userBalances[u] ?? .empty
        let wasPositive = wallet.balanceUsd > 0
        wallet.balanceUsd -= billedUsd
        wallet.spentBilledUsd += billedUsd
        wallet.spentRealUsd += realUsd
        wallet.updatedAt = Date()
        userBalances[u] = wallet
        dirtyConfigs.insert(.balances)
        let depleted = wasPositive && wallet.balanceUsd <= 0
        if depleted { bumpFunnel(.balanceEmpty) }
        return depleted
    }
}
