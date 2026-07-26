import Foundation

// Subscriptions: activation/extension, pricing with a winback discount,
// reminder & winback scheduling state.

extension ChatContextStore {
    // MARK: - Subscription

    static let subscriptionDays = 30

    /// Payment path: creates the tenant if needed and extends the subscription
    /// by `days` from max(now, current end). An unlimited tenant stays
    /// unlimited — paying never shortens access.
    func activatePaidSubscription(username: String, days: Int = ChatContextStore.subscriptionDays) -> SubscriptionActivation {
        let u = userKeyOrRaw(username)
        let isNew = tenants[u] == nil
        if isNew {
            registerTenant(username: u)
        }
        guard var tenant = tenants[u] else { return .alreadyUnlimited }

        if !isNew, tenant.paidUntil == nil {
            return .alreadyUnlimited
        }

        let base = max(Date(), tenant.paidUntil ?? Date())
        let until = base.addingTimeInterval(TimeInterval(days) * 86_400)
        tenant.paidUntil = until
        tenants[u] = tenant
        dirtyTenants.insert(u)
        return isNew ? .started(until: until) : .extended(until: until)
    }

    /// True when the owner exists and the subscription hasn't expired.
    /// Expired tenants keep their admin panel (to renew) but lose paid models.
    func tenantIsActive(_ ownerUsername: String) -> Bool {
        tenants[userKeyOrRaw(ownerUsername)]?.isActive ?? false
    }

    func tenantSubscription(ownerUsername: String) -> (exists: Bool, paidUntil: Date?, isActive: Bool) {
        guard let tenant = tenants[userKeyOrRaw(ownerUsername)] else {
            return (false, nil, false)
        }
        return (true, tenant.paidUntil, tenant.isActive)
    }

    /// Super-admin: extend by N days (from max(now, current end)).
    @discardableResult
    func extendTenantSubscription(username: String, days: Int) -> Date? {
        let u = userKeyOrRaw(username)
        guard var tenant = tenants[u] else { return nil }
        let base = max(Date(), tenant.paidUntil ?? Date())
        let until = base.addingTimeInterval(TimeInterval(days) * 86_400)
        tenant.paidUntil = until
        tenants[u] = tenant
        dirtyTenants.insert(u)
        return until
    }

    /// Super-admin: make the subscription unlimited.
    @discardableResult
    func setTenantUnlimited(username: String) -> Bool {
        let u = userKeyOrRaw(username)
        guard var tenant = tenants[u] else { return false }
        tenant.paidUntil = nil
        tenants[u] = tenant
        dirtyTenants.insert(u)
        return true
    }

    /// Super-admin: expire the subscription immediately.
    @discardableResult
    func expireTenantSubscription(username: String) -> Bool {
        let u = userKeyOrRaw(username)
        guard u != defaultOwnerKey, var tenant = tenants[u] else { return false }
        tenant.paidUntil = Date()
        tenants[u] = tenant
        dirtyTenants.insert(u)
        return true
    }

    // MARK: - Subscription lifecycle: reminders & winback (roadmap step 8)

    /// An invoice opened just before a winback offer ran out is still honored
    /// at checkout — the user must never be charged more than they were shown.
    static let checkoutDiscountGrace: TimeInterval = 3600

    func reminderConfig() -> SubscriptionReminderConfig { reminderConfigValue }

    func setReminderConfig(_ config: SubscriptionReminderConfig) {
        reminderConfigValue = config.normalized
        dirtyConfigs.insert(.reminders)
    }

    func remindersOptOut(username: String?) -> Bool {
        guard let u = userKey(username: username) else { return false }
        return tenants[u]?.remindersOptOut ?? false
    }

    /// Per-sponsor opt-out (toggle in their own admin panel).
    @discardableResult
    func setRemindersOptOut(username: String, optOut: Bool) -> Bool {
        let u = userKeyOrRaw(username)
        guard tenants[u] != nil else { return false }
        mutateTenantByOwner(u) { $0.remindersOptOut = optOut }
        return true
    }

    /// Notices due right now. Pure decision: the caller sends them and reports
    /// back through `markNoticeSent`, so a failed send is retried next sweep
    /// (bounded by each notice's own window) instead of being lost.
    func dueSubscriptionNotices(now: Date = Date()) -> [SubscriptionNoticeTarget] {
        let config = reminderConfigValue
        guard config.enabled else { return [] }
        var targets: [SubscriptionNoticeTarget] = []
        // Super-admins own the bot rather than buy from it; selling the owner a
        // winback offer for their own product is noise, and the funnel already
        // leaves them out of the sponsor tallies.
        for (owner, tenant) in tenants where !superAdminUsernames.contains(owner) {
            guard let paidUntil = tenant.paidUntil, !tenant.remindersOptOut else { continue }
            // Flags belong to one cycle; a renewal invalidates them.
            let sent = tenant.noticeCycleUntil == paidUntil ? tenant.sentNotices : []
            guard let notice = config.dueNotice(paidUntil: paidUntil, alreadySent: sent, now: now) else {
                continue
            }
            targets.append(SubscriptionNoticeTarget(
                username: owner,
                label: displayLabel(forKey: owner),
                notice: notice,
                paidUntil: paidUntil,
                privateChatID: privateChatID(forKey: owner),
                groupChatIDs: ownedGroupChatIDs(owner: owner)
            ))
        }
        return targets.sorted { $0.username < $1.username }
    }

    /// Records a delivered notice against the cycle it was computed for. A
    /// renewal in between changes `paidUntil` → the mark is dropped, so the new
    /// cycle keeps its own reminder.
    @discardableResult
    func markNoticeSent(username: String, notice: SubscriptionNotice, paidUntil: Date) -> Bool {
        let u = userKeyOrRaw(username)
        guard let tenant = tenants[u], tenant.paidUntil == paidUntil else { return false }
        mutateTenantByOwner(u) { state in
            if state.noticeCycleUntil != paidUntil {
                state.noticeCycleUntil = paidUntil
                state.sentNotices = []
            }
            state.sentNotices.insert(notice.key)
        }
        return true
    }

    /// Attaches a winback discount; the next subscription purchase by this user
    /// is priced with it on every payment method.
    @discardableResult
    func grantWinbackDiscount(username: String, percent: Int, hours: Int, now: Date = Date()) -> SubscriptionDiscount? {
        let u = userKeyOrRaw(username)
        guard tenants[u] != nil, percent > 0, hours > 0 else { return nil }
        // A live offer is never re-issued. The sweep grants the discount before
        // sending, so a transient Telegram error (notice left unmarked, retried
        // next sweep) would otherwise push the deadline forward every hour: an
        // "истекает через 48 часов" that never actually expires. A percent
        // changed mid-window takes effect on the next offer, not this one.
        if let existing = tenants[u]?.winbackDiscount, existing.isActive(now: now) { return existing }
        let discount = SubscriptionDiscount(
            percent: percent,
            expiresAt: now.addingTimeInterval(Double(hours) * 3600)
        )
        mutateTenantByOwner(u) { $0.winbackDiscount = discount }
        return discount
    }

    /// The discount honored right now, if any.
    func subscriptionDiscount(username: String?, grace: TimeInterval = 0, now: Date = Date()) -> SubscriptionDiscount? {
        guard let u = userKey(username: username), let discount = tenants[u]?.winbackDiscount else { return nil }
        return discount.isActive(now: now, grace: grace) ? discount : nil
    }

    /// Clears the offer after a purchase (one-shot). Returns it when it was
    /// still valid, so the caller can count the winback conversion.
    @discardableResult
    func consumeWinbackDiscount(username: String) -> SubscriptionDiscount? {
        let u = userKeyOrRaw(username)
        guard let discount = tenants[u]?.winbackDiscount else { return nil }
        mutateTenantByOwner(u) { $0.winbackDiscount = nil }
        return discount.isActive(grace: Self.checkoutDiscountGrace) ? discount : nil
    }

    /// Super-admin escape hatch: drops every live offer at once (e.g. after a
    /// misconfigured discount went out).
    @discardableResult
    func clearAllWinbackDiscounts() -> Int {
        var cleared = 0
        for (owner, tenant) in tenants where tenant.winbackDiscount != nil {
            mutateTenantByOwner(owner) { $0.winbackDiscount = nil }
            cleared += 1
        }
        return cleared
    }

    /// Subscription prices for this user with any active winback discount
    /// applied. Single source of truth for menus, `/buy`, crypto invoices and
    /// pre-checkout validation.
    ///
    /// - Parameter applying: use this discount instead of the stored one.
    ///   Nothing is granted or consumed — it exists so the super-admin preview
    ///   quotes the same numbers on every payment method a real offer would,
    ///   card included.
    func subscriptionPricing(
        username: String?,
        grace: TimeInterval = 0,
        now: Date = Date(),
        applying: SubscriptionDiscount? = nil
    ) -> SubscriptionPricing {
        let cardPrice = _cardConfig.isEnabled ? _cardConfig.priceMinorUnits : nil
        var pricing = SubscriptionPricing(
            discount: nil,
            starsFull: _starsPrice,
            stars: _starsPrice,
            cryptoCentsFull: _cryptoPriceUsdCents,
            cryptoCents: _cryptoPriceUsdCents,
            cardMinorUnitsFull: cardPrice,
            cardMinorUnits: cardPrice,
            cardLabelFull: cardPrice.map { _cardConfig.currency.format(minorUnits: $0) },
            cardLabel: cardPrice.map { _cardConfig.currency.format(minorUnits: $0) }
        )
        guard let discount = applying ?? subscriptionDiscount(username: username, grace: grace, now: now) else {
            return pricing
        }
        pricing.discount = discount
        pricing.stars = _starsPrice.map { discount.apply(to: $0) }
        pricing.cryptoCents = _cryptoPriceUsdCents.map { discount.apply(to: $0) }
        // Card: never dip below the provider minimum — Telegram rejects it.
        pricing.cardMinorUnits = cardPrice.map { max(_cardConfig.currency.minMinorUnits, discount.apply(to: $0)) }
        pricing.cardLabel = pricing.cardMinorUnits.map { _cardConfig.currency.format(minorUnits: $0) }
        return pricing
    }

    /// The person's DM with the bot, if they ever wrote to it (Telegram forbids
    /// bot-initiated conversations, so this is the only way to reach them
    /// personally).
    ///
    /// For an identified user this is exact: a Telegram private chat's ID *is*
    /// the user's ID. Only a pending record still has to be matched by the
    /// username we were told about.
    ///
    /// A DM the person blocked (`my_chat_member` → kicked) is not a channel:
    /// every send there fails with 403, so returning it would make the sweep
    /// retry the same dead address on every pass.
    func privateChatID(forKey key: String) -> Int? {
        if let userID = UserKey.userID(from: key) {
            guard let meta = chatMetaByID[userID], meta.type == "private", meta.botRemoved != true else { return nil }
            return userID
        }
        for (chatID, meta) in chatMetaByID
        where chatID > 0 && meta.type == "private"
            && meta.botRemoved != true
            && meta.username?.lowercased() == key {
            return chatID
        }
        return nil
    }

    /// Group chats the owner's licence covers *and* the bot can still post to.
    /// A chat it was kicked out of stays owned (re-adding restores it) but is
    /// not a delivery channel, so broadcasts skip it instead of burning a send.
    func ownedGroupChatIDs(owner: String) -> [Int] {
        let u = userKeyOrRaw(owner)
        return chatOwnership
            .filter { $0.key < 0 && $0.value == u && chatMetaByID[$0.key]?.botRemoved != true }
            .map(\.key)
            .sorted()
    }

    /// Monitoring snapshot for the super-admin reminders page: who is about to
    /// lapse, who just did, who carries a live offer, who can't be reached.
    func subscriptionLifecycleStats(now: Date = Date()) -> SubscriptionLifecycleStats {
        let config = reminderConfigValue
        let lead = Double(max(config.daysBeforeExpiry, 1)) * 86_400
        let winbackHorizon = Double((config.winbackDays.max() ?? 7)) * 86_400 + config.winbackCatchUpWindow
        var stats = SubscriptionLifecycleStats()
        // Same population the sweep works on — a page that lists people the
        // sweep will never contact reads as a bug report.
        for (owner, tenant) in tenants where !superAdminUsernames.contains(owner) {
            guard let paidUntil = tenant.paidUntil else { continue }
            stats.sponsors += 1
            let reachable = privateChatID(forKey: owner) != nil || !ownedGroupChatIDs(owner: owner).isEmpty
            if !reachable { stats.unreachable += 1 }
            if tenant.remindersOptOut { stats.optedOut += 1 }
            let row = SubscriptionLifecycleStats.Row(
                username: owner,
                label: displayLabel(forKey: owner),
                paidUntil: paidUntil,
                reachable: reachable,
                optedOut: tenant.remindersOptOut
            )
            if paidUntil > now {
                if paidUntil.timeIntervalSince(now) <= lead { stats.expiringSoon.append(row) }
            } else if now.timeIntervalSince(paidUntil) <= winbackHorizon {
                stats.recentlyExpired.append(row)
            }
            if let discount = tenant.winbackDiscount, discount.isActive(now: now) {
                stats.activeDiscounts.append((label: displayLabel(forKey: owner), discount: discount))
            }
        }
        stats.expiringSoon.sort { $0.paidUntil < $1.paidUntil }
        stats.recentlyExpired.sort { $0.paidUntil > $1.paidUntil }
        stats.activeDiscounts.sort { $0.label < $1.label }
        return stats
    }
}
