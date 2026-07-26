import Foundation

// Funnel counters, the /metrics report and paid-traffic attribution.

extension ChatContextStore {
    // MARK: - Funnel analytics (roadmap step 7)

    /// Records one funnel event. Persisted (dirties GlobalConfigKey.funnel) both
    /// as an all-time total and in today's bucket.
    func bumpFunnel(_ event: FunnelEvent, by amount: Int = 1) {
        bumpFunnelCounter(key: event.rawValue, by: amount)
    }

    /// Counts a purchase-page open together with the surface it came from, so
    /// the pain-point upsells can be compared with the plain menu button.
    func bumpPurchaseOpen(source: PurchaseSource) {
        bumpFunnelCounter(key: FunnelEvent.openPurchase.rawValue)
        bumpFunnelCounter(key: source.counterKey)
    }

    private func bumpFunnelCounter(key: String, by amount: Int = 1) {
        funnelCounters[key, default: 0] += amount
        dirtyConfigs.insert(.funnel)
        funnelDailyValue.bump(key: key, by: amount)
        dirtyConfigs.insert(.funnelDaily)
    }

    /// Counts the `firstMessage` activation the first time a chat produces an LLM
    /// turn. Idempotent per chat via a persisted flag on the context, so a
    /// restart never re-counts it.
    func markFirstMessageIfNeeded(chatKey: ChatKey) {
        var context = ensure(chatKey: chatKey)
        guard !context.funnelFirstMessageCounted else { return }
        context.funnelFirstMessageCounted = true
        contexts[chatKey] = context
        dirtyContexts.insert(chatKey)
        bumpFunnel(.firstMessage)
    }

    /// Funnel event counts plus sponsor tallies derived live from tenant state:
    /// active = paying now, expired = churned, unlimited = comped. Super-admins
    /// are excluded — they are not paying sponsors.
    func funnelReport() -> FunnelReport {
        let now = Date()
        let lead = Double(max(reminderConfigValue.daysBeforeExpiry, 1)) * 86_400
        var active = 0, expired = 0, unlimited = 0, expiringSoon = 0, offers = 0
        for (owner, tenant) in tenants where !superAdminUsernames.contains(owner) {
            if let until = tenant.paidUntil {
                if until > now {
                    active += 1
                    if until.timeIntervalSince(now) <= lead { expiringSoon += 1 }
                } else {
                    expired += 1
                }
            } else {
                unlimited += 1
            }
            if tenant.winbackDiscount?.isActive(now: now) == true { offers += 1 }
        }
        return FunnelReport(
            counters: funnelCounters,
            todayCounters: funnelDailyValue.counts(lastDays: 1, now: now),
            weekCounters: funnelDailyValue.counts(lastDays: 7, now: now),
            monthCounters: funnelDailyValue.counts(lastDays: 30, now: now),
            retention: userDirectoryValue.retention(now: now),
            sponsorsActive: active,
            sponsorsExpired: expired,
            sponsorsUnlimited: unlimited,
            sponsorsExpiringSoon: expiringSoon,
            winbackOffersActive: offers,
            referralPending: referralLedgerValue.pendingCount,
            referralRewarded: referralLedgerValue.rewardedCount,
            referralPaidCents: Int((referralLedgerValue.paidOutUsd * 100).rounded()),
            referralConversions: referralLedgerValue.paidConversionCount
        )
    }

    // MARK: - Paid-traffic attribution (`src_` deep links)

    func trafficSourceLedger() -> TrafficSourceLedger { trafficSourceLedgerValue }

    private func markTrafficSourcesDirty() {
        trafficSourceLedgerValue.prune()
        dirtyConfigs.insert(.trafficSources)
    }

    /// Files a person under the campaign whose link they opened.
    ///
    /// Two rules keep the numbers honest, because CAC is computed from them:
    /// **first touch wins** (a later link never steals a customer an earlier
    /// campaign paid to acquire), and somebody who was already using the bot is
    /// not an acquisition at all — they are counted separately so a channel
    /// cannot inflate its arrivals with people it did not bring.
    @discardableResult
    func bindTrafficSource(userID: Int, tag rawTag: String, username: String?) -> TrafficSourceBindOutcome {
        guard let tag = TrafficSourceLink.sanitize(rawTag) else { return .knownUser }
        let key = String(userID)

        if let existing = trafficSourceLedgerValue.attributions[key] {
            trafficSourceLedgerValue.repeatOpens += 1
            markTrafficSourcesDirty()
            return .alreadyAttributed(tag: existing.tag)
        }

        if hasPriorBotActivity(userID: userID, username: username) {
            trafficSourceLedgerValue.knownUserOpens += 1
            markTrafficSourcesDirty()
            return .knownUser
        }

        let now = Date()
        let stored = trafficSourceLedgerValue.storageTag(for: tag)
        trafficSourceLedgerValue.attributions[key] = TrafficSourceAttribution(tag: stored, joinedAt: now)
        var tally = trafficSourceLedgerValue.tallies[stored] ?? TrafficSourceTally(firstSeenAt: now)
        tally.joined += 1
        tally.lastSeenAt = now
        trafficSourceLedgerValue.tallies[stored] = tally
        markTrafficSourcesDirty()
        return .bound(tag: stored)
    }

    /// Marks that an attributed person got a real answer. Idempotent — the
    /// caller runs on every turn.
    func markTrafficSourceActivation(userID: Int) {
        let key = String(userID)
        guard var record = trafficSourceLedgerValue.attributions[key], record.activatedAt == nil else { return }
        let now = Date()
        record.activatedAt = now
        trafficSourceLedgerValue.attributions[key] = record
        var tally = trafficSourceLedgerValue.tallies[record.tag] ?? TrafficSourceTally(firstSeenAt: now)
        tally.activated += 1
        tally.lastSeenAt = now
        trafficSourceLedgerValue.tallies[record.tag] = tally
        markTrafficSourcesDirty()
    }

    /// Credits a payment to the campaign that brought the payer. `payers` counts
    /// distinct people (the CAC denominator), `payments` counts every purchase,
    /// so repeat buyers show up without distorting the acquisition cost.
    func recordTrafficSourcePayment(userID: Int) {
        let key = String(userID)
        guard var record = trafficSourceLedgerValue.attributions[key] else { return }
        let now = Date()
        let isFirstPayment = record.paidAt == nil
        if isFirstPayment { record.paidAt = now }
        record.payments += 1
        trafficSourceLedgerValue.attributions[key] = record
        var tally = trafficSourceLedgerValue.tallies[record.tag] ?? TrafficSourceTally(firstSeenAt: now)
        if isFirstPayment { tally.payers += 1 }
        tally.payments += 1
        tally.lastSeenAt = now
        trafficSourceLedgerValue.tallies[record.tag] = tally
        markTrafficSourcesDirty()
    }

    func trafficSourceOverview() -> TrafficSourceOverview {
        let ledger = trafficSourceLedgerValue
        return TrafficSourceOverview(
            rows: ledger.ranked(),
            joined: ledger.totalJoined,
            activated: ledger.totalActivated,
            payers: ledger.totalPayers,
            payments: ledger.totalPayments,
            repeatOpens: ledger.repeatOpens,
            knownUserOpens: ledger.knownUserOpens
        )
    }

    func clearTrafficSources() {
        trafficSourceLedgerValue = .empty
        dirtyConfigs.insert(.trafficSources)
    }
}
