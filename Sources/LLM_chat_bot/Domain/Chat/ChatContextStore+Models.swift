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

    func isFreeModel(_ id: String) -> Bool {
        guard let effective = effectiveFreeModelIDs() else { return true }
        return effective.contains(id)
    }

    /// The fallback model, deterministically. `Set.first` is arbitrary and
    /// changes between runs and even between mutations — a chat dropped to the
    /// free tier would land on a different model every time, so answer quality
    /// would swing for no visible reason and the super-admin could not choose
    /// the backup. Pinned models win in the order they were pinned.
    func firstFreeModel() -> String? {
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
