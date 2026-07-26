import Foundation

// Ad campaigns and the built-in self-promo that fills an empty slot.

extension ChatContextStore {
    // MARK: - Ad campaigns

    func adCampaigns() -> [AdCampaign] {
        adCampaignList.sorted { $0.createdAt < $1.createdAt }
    }

    func adCampaign(id: String) -> AdCampaign? {
        adCampaignList.first { $0.id == id }
    }

    func upsertAdCampaign(_ campaign: AdCampaign) {
        if let index = adCampaignList.firstIndex(where: { $0.id == campaign.id }) {
            adCampaignList[index] = campaign
        } else {
            adCampaignList.append(campaign)
        }
        dirtyConfigs.insert(.ads)
    }

    @discardableResult
    func removeAdCampaign(id: String) -> Bool {
        let before = adCampaignList.count
        adCampaignList.removeAll { $0.id == id }
        let removed = adCampaignList.count < before
        if removed { dirtyConfigs.insert(.ads) }
        return removed
    }

    @discardableResult
    func setAdCampaignEnabled(id: String, enabled: Bool) -> Bool {
        guard let index = adCampaignList.firstIndex(where: { $0.id == id }) else { return false }
        adCampaignList[index].enabled = enabled
        dirtyConfigs.insert(.ads)
        return true
    }

    /// Counts a bot reply in an ad-eligible chat and returns the campaign to
    /// show now, if frequency/pacing allow one. Recording the impression and
    /// resetting the per-chat counters happens here so the decision is atomic.
    func nextAdToShow(chatKey: ChatKey) -> AdCampaign? {
        var context = ensure(chatKey: chatKey)
        context.adReplyCounter += 1
        contexts[chatKey] = context
        dirtyContexts.insert(chatKey)

        let now = Date()

        let candidates = adCampaignList.filter { campaign in
            campaign.isRunning(now: now)
                && campaign.pacingAllows(now: now)
                && context.adReplyCounter >= campaign.everyNReplies
                && (context.adLastShownAt.map {
                    now.timeIntervalSince($0) >= TimeInterval(campaign.minIntervalSeconds)
                } ?? true)
        }
        // Least-shown campaign first → fair rotation between active ads.
        if let chosen = candidates.min(by: { $0.impressionsUsed < $1.impressionsUsed }),
           let index = adCampaignList.firstIndex(where: { $0.id == chosen.id }) {
            adCampaignList[index].impressionsUsed += 1
            dirtyConfigs.insert(.ads)

            context.adReplyCounter = 0
            context.adLastShownAt = now
            contexts[chatKey] = context
            dirtyContexts.insert(chatKey)
            return adCampaignList[index]
        }

        // Fallback: the built-in self-promo fills the slot when no super-admin
        // campaign is running. If a real campaign is running but its throttle
        // isn't met this call, it owns the slot — don't undercut it. Text and
        // throttle are super-admin knobs (`SelfPromoConfig`); the campaign
        // object stays synthetic, only the impression counter is persisted.
        guard selfPromoConfigValue.enabled else { return nil }
        guard !adCampaignList.contains(where: { $0.isRunning(now: now) }) else { return nil }
        let promo = AdCampaign.selfPromo(selfPromoConfigValue)
        guard context.adReplyCounter >= promo.everyNReplies,
              context.adLastShownAt.map({ now.timeIntervalSince($0) >= TimeInterval(promo.minIntervalSeconds) }) ?? true
        else { return nil }

        context.adReplyCounter = 0
        context.adLastShownAt = now
        contexts[chatKey] = context
        dirtyContexts.insert(chatKey)
        selfPromoConfigValue.impressions += 1
        dirtyConfigs.insert(.selfPromo)
        bumpFunnel(.promoShown)
        return promo
    }

    // MARK: - Built-in self-promo (roadmap step 5)

    func selfPromoConfig() -> SelfPromoConfig { selfPromoConfigValue }

    /// Keeps the impression counter — editing the pitch is an A/B tweak, not a
    /// reason to lose what the slot has already done. Use `resetSelfPromoStats`
    /// for that.
    func setSelfPromoConfig(_ config: SelfPromoConfig) {
        var next = config.normalized
        next.impressions = selfPromoConfigValue.impressions
        selfPromoConfigValue = next
        dirtyConfigs.insert(.selfPromo)
    }

    func resetSelfPromoStats() {
        selfPromoConfigValue.impressions = 0
        dirtyConfigs.insert(.selfPromo)
    }
}
