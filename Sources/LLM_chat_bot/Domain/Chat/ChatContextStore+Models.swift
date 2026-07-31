import Foundation

// Free-model catalogue: super-admin pins plus the live OpenRouter set.

extension ChatContextStore {
    // MARK: - Free model access

    func freeModelIDs() -> [String] { _freeModelIDs }

    func setFreeModelIDs(_ ids: [String]) {
        _freeModelIDs = ids.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        dirtyConfigs.insert(.freeModels)
    }

    @discardableResult
    func addFreeModel(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !_freeModelIDs.contains(trimmed) else { return false }
        _freeModelIDs.append(trimmed)
        dirtyConfigs.insert(.freeModels)
        return true
    }

    @discardableResult
    func removeFreeModel(_ id: String) -> Bool {
        let before = _freeModelIDs.count
        _freeModelIDs.removeAll { $0 == id }
        let removed = _freeModelIDs.count < before
        if removed { dirtyConfigs.insert(.freeModels) }
        return removed
    }

    func effectiveFreeModelIDs() -> Set<String>? {
        let pinned = _freeModelIDs
        let openRouter = _openRouterFreeModelIDs
        guard !pinned.isEmpty || openRouter != nil else { return nil }
        var result = Set(pinned)
        if let openRouter { result.formUnion(openRouter) }
        return result
    }

    /// Everything a person **without** a subscription and without a balance is
    /// allowed to run: the zero-cost set above plus the models behind 🆓 modes.
    ///
    /// This is the single answer to "may this model be used for free", and every
    /// gate must ask it rather than `effectiveFreeModelIDs()`. Free OpenRouter
    /// models are genuinely poor, and a new user who meets one first simply
    /// leaves; putting a cheap paid model behind the free mode is how the owner
    /// buys a decent first impression, and the gate has to honour that choice.
    ///
    /// `nil` still means "catalogue unknown" — callers treat that as
    /// "assume paid" (see `GenerationCoordinator.resolveDailyPremium`).
    func allowedFreeModelIDs() -> Set<String>? {
        let fromModes = modeConfigValue.freeTierModelIDs
        guard let zeroCost = effectiveFreeModelIDs() else {
            return fromModes.isEmpty ? nil : fromModes
        }
        return zeroCost.union(fromModes)
    }

    /// The fallback model, deterministically. `Set.first` is arbitrary and
    /// changes between runs and even between mutations — a chat dropped to the
    /// free tier would land on a different model every time, so answer quality
    /// would swing for no visible reason and the super-admin could not choose
    /// the backup.
    ///
    /// Order: the model of the working 🆓 mode (the owner's deliberate pick for
    /// the free tier), then pinned models in the order they were pinned, then
    /// the zero-cost set sorted.
    func fallbackFreeModel() -> String? {
        if let fromMode = modeConfigValue.defaultMode.flatMap({ $0.tier == .free ? $0.model : nil }) {
            return fromMode
        }
        if let freeMode = modeConfigValue.activeModes.first(where: { $0.tier == .free })?.model {
            return freeMode
        }
        if let pinned = _freeModelIDs.first { return pinned }
        return effectiveFreeModelIDs()?.sorted().first
    }

    func openRouterFreeModelIDs() -> Set<String>? { _openRouterFreeModelIDs }

    func updateOpenRouterFreeModelIDs(_ ids: Set<String>) {
        _openRouterFreeModelIDs = ids
    }

    func openRouterModelPrice(for id: String) -> ModelPriceInfo? { _openRouterModelPrices[id] }

    func openRouterModelPrices() -> [String: ModelPriceInfo] { _openRouterModelPrices }

    func updateOpenRouterModelPrices(_ prices: [String: ModelPriceInfo]) {
        for (k, v) in prices { _openRouterModelPrices[k] = v }
    }
}
