import Foundation

// Spending ceilings (§4.1): the only thing standing between a subscriber with a
// heavy group and an unbounded provider bill.
//
// The bot caps concurrency and the free tier's daily taste of premium. Neither
// caps money. A $5 subscription buys a 500-person group on an expensive model,
// and today the first sign of it is the OpenRouter invoice — weeks later, after
// it has been paid.

extension ChatContextStore {
    func spendPolicy() -> SpendPolicy { spendPolicyValue }

    func setSpendPolicy(_ policy: SpendPolicy) {
        spendPolicyValue = policy
        dirtyConfigs.insert(.spendPolicy)
    }

    /// Adds what an answer really cost the owner to today's running totals.
    /// Called from `appendAssistant`, next to the usage it already records, so
    /// a new answer path cannot be billed to nobody.
    func recordProviderSpend(chatID: Int, real: Money) {
        guard real.isPositive else { return }
        dailySpendValue.record(real, tenant: chatOwnership[chatID] ?? defaultOwnerKey)
    }

    /// Today's provider spend, in total and per tenant — the monitoring half of
    /// the ceilings page. Names are resolved here so the page never handles a
    /// storage key (§17).
    func spendToday() -> SpendOverview {
        var ledger = dailySpendValue
        ledger.rollOverIfNeeded()
        dailySpendValue = ledger
        let top = ledger.byTenant
            .map { SpendOverview.Row(label: displayLabel(forKey: $0.key), spent: $0.value) }
            .sorted { $0.spent > $1.spent }
        return SpendOverview(total: ledger.total, topTenants: top)
    }

    /// Whether a paid answer is still within the ceilings, and which one it hit.
    /// Free models cost nothing and are never gated: a cap that switches the bot
    /// off entirely would turn an accounting limit into an outage.
    func spendVerdict(chatID: Int) -> SpendCapVerdict? {
        let policy = spendPolicyValue
        guard policy.isEnabled else { return nil }
        var ledger = dailySpendValue
        ledger.rollOverIfNeeded()
        dailySpendValue = ledger

        if policy.hasGlobalCap, ledger.total >= policy.dailyGlobalCap {
            return .global(spent: ledger.total, cap: policy.dailyGlobalCap)
        }
        let owner = chatOwnership[chatID] ?? defaultOwnerKey
        if policy.hasTenantCap {
            let spent = ledger.spent(tenant: owner)
            if spent >= policy.dailyPerTenantCap {
                return .tenant(spent: spent, cap: policy.dailyPerTenantCap, response: policy.onTenantCap)
            }
        }
        return nil
    }

    /// What the sponsor sees on their own panel. A ceiling nobody can see is not
    /// a protection, it is an unexplained downgrade of something they paid for.
    func spendStatusLine(forKey key: UserKey) -> String? {
        let policy = spendPolicyValue
        guard policy.hasTenantCap else { return nil }
        var ledger = dailySpendValue
        ledger.rollOverIfNeeded()
        dailySpendValue = ledger
        let spent = ledger.spent(tenant: resolved(key))
        return "📊 Расход за сегодня · <b>\(spent.formatted(fractionDigits: 2))</b> из \(policy.dailyPerTenantCap.formatted(fractionDigits: 2))"
    }
}
