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
    /// and pay: 30% markup → 1.3. Display only — money is marked up with
    /// `Money.multiplied(byPercent:)`, which is integral.
    func priceMultiplier() -> Double {
        1.0 + Double(markupPercentValue) / 100.0
    }

    /// Customer-facing total for a usage record. Rows that predate markup
    /// carry no billed value — approximate with the current rate.
    func billedCost(of usage: CumulativeUsage) -> Money {
        usage.totalBilledCost.isPositive
            ? usage.totalBilledCost
            : usage.totalCost.multiplied(byPercent: markupPercentValue)
    }

    func balance(username: String?) -> UserBalance? {
        guard let u = userKey(username: username) else { return nil }
        return userBalances[u]
    }

    func hasPositiveBalance(username: String?) -> Bool {
        balance(username: username)?.balance.isPositive ?? false
    }

    /// Key of the wallet that should pay for this person's answers, or nil when
    /// there is nothing to charge. Resolved by userID first, so a person with
    /// no @username still spends the balance they topped up.
    ///
    /// "Has money" means at least `minimumBillableBalance`, not "more than
    /// zero": sub-cent dust cannot pay for an answer, and billing against it
    /// means the answer costs more than the wallet held (§4.4).
    func billingKey(username: String?, userID: Int?) -> String? {
        userKeys(username: username, userID: userID)
            .first { (userBalances[$0]?.balance ?? .zero) >= Self.minimumBillableBalance }
    }

    /// Adds (or subtracts, for corrections) to the user's balance. Creates the
    /// wallet on first credit.
    @discardableResult
    func creditBalance(username: String, amount: Money) -> UserBalance {
        creditBalance(key: userKeyOrRaw(username), amount: amount)
    }

    /// Same, for a caller that already holds the person's key — the referral
    /// payout, which addresses wallets by userID and never by @username.
    @discardableResult
    func creditBalance(key: String, amount: Money) -> UserBalance {
        var wallet = userBalances[key] ?? .empty
        // A correction may be negative; a wallet may not. The same floor is a
        // `check` constraint on the column (§2.1).
        wallet.balance = (wallet.balance + amount).clampedToZero
        wallet.updatedAt = Date()
        userBalances[key] = wallet
        markWalletDirty(key)
        return wallet
    }

    /// A credit pack the person actually paid for, as opposed to a referral
    /// bonus or a super-admin grant. Tracked separately because "has paid real
    /// money at least once" is what makes a lapsed wallet worth an offer, and
    /// what tells the super-admin who is a customer (§7 «Возврат по балансу»).
    /// Topping up also reopens the lapse cycle: coming back earns a new notice.
    @discardableResult
    func creditPurchasedBalance(username: String, amount: Money) -> UserBalance {
        creditPurchasedBalance(key: userKeyOrRaw(username), amount: amount)
    }

    @discardableResult
    func creditPurchasedBalance(key: String, amount: Money) -> UserBalance {
        var wallet = creditBalance(key: key, amount: amount)
        wallet.toppedUp = wallet.toppedUp + amount
        wallet.lapsedNoticeAt = nil
        userBalances[key] = wallet
        markWalletDirty(key)
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
            guard wallet.toppedUp.isPositive, wallet.lapsedNoticeAt == nil else { continue }
            // The bot's owners are not sold the bot's own product — same rule
            // the subscription sweep follows.
            guard !superAdminUsernames.contains(key) else { continue }
            // Still has money, or is covered by a subscription: not lapsed.
            guard wallet.balance <= Self.lapsedWalletThreshold else { continue }
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
                toppedUp: wallet.toppedUp,
                idleDays: max(1, Int(now.timeIntervalSince(lastSeen) / 86_400))
            ))
        }
        return targets.sorted { $0.toppedUp > $1.toppedUp }
    }

    /// A wallet is "empty enough" below this: sub-cent dust is not money.
    static let lapsedWalletThreshold = Money.cents(1)

    /// Below this a wallet is not billed at all. Dust is not "has money": one
    /// expensive answer eats the remainder whole and the person gets an answer
    /// worth more than their balance. The difference is a gift of fractions of
    /// a cent — but a bounded, counted one (`MetricName.billingShortfallNanos`).
    static let minimumBillableBalance = Money.cents(2)

    /// Stamps a delivered lapsed-wallet offer, so it goes out once per lapse.
    /// Only called after a successful send — a failed one is retried next sweep.
    @discardableResult
    func markWalletWinbackSent(key: String, now: Date = Date()) -> Bool {
        guard var wallet = userBalances[key] else { return false }
        wallet.lapsedNoticeAt = now
        userBalances[key] = wallet
        markWalletDirty(key)
        return true
    }

    /// How many wallets are lapsed right now, and how many already heard from
    /// us — the monitoring line on the super-admin reminders page.
    func lapsedWalletStats(now: Date = Date()) -> (due: Int, notified: Int, payers: Int) {
        var notified = 0
        var payers = 0
        for wallet in userBalances.values where wallet.toppedUp.isPositive {
            payers += 1
            if wallet.lapsedNoticeAt != nil { notified += 1 }
        }
        return (dueWalletWinbacks(now: now).count, notified, payers)
    }

    @discardableResult
    func setBalanceAmount(username: String, amount: Money) -> UserBalance {
        let u = userKeyOrRaw(username)
        var wallet = userBalances[u] ?? .empty
        wallet.balance = amount.clampedToZero
        wallet.updatedAt = Date()
        userBalances[u] = wallet
        markWalletDirty(u)
        return wallet
    }

    @discardableResult
    func removeBalance(username: String) -> Bool {
        let key = userKeyOrRaw(username)
        guard userBalances.removeValue(forKey: key) != nil else { return false }
        dirtyWallets.remove(key)
        deletedWallets.insert(key)
        return true
    }

    /// One wallet changed in the cache. The row itself is written through the
    /// ledger transaction; this set is what carries a change that happened
    /// outside one (a rename adopting a wallet) to storage.
    func markWalletDirty(_ key: String) {
        dirtyWallets.insert(key)
        deletedWallets.remove(key)
    }

    func allBalances() -> [(key: String, label: String, wallet: UserBalance)] {
        userBalances
            .map { (key: $0.key, label: displayLabel(forKey: $0.key), wallet: $0.value) }
            .sorted { $0.label < $1.label }
    }

    /// What the footer will show as the post-charge balance. The real charge is
    /// a ledger transaction (`LedgerTransaction.debit`); the formula here is the
    /// same one, floor included, so the projection and the deduction agree.
    func projectedBalanceAfterCharge(username: String, realCost: Money) -> Money {
        let current = userBalances[userKeyOrRaw(username)]?.balance ?? .zero
        return (current - realCost.multiplied(byPercent: markupPercentValue)).clampedToZero
    }

}
