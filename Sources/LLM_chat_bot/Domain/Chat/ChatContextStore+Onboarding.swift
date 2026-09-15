import Foundation

// Onboarding examples: the ready-made prompts shown in the greeting.

extension ChatContextStore {
    // MARK: - Onboarding examples (roadmap step 9)

    func onboardingConfig() -> OnboardingConfig { onboardingConfigValue }

    func setOnboardingConfig(_ config: OnboardingConfig) {
        onboardingConfigValue = config.normalized
        dirtyConfigs.insert(.onboarding)
    }

    /// Appends an example; nil when the list is full or the input normalized to
    /// nothing (the menu turns that into a toast).
    func addOnboardingExample(label: String, prompt: String) -> OnboardingExample? {
        var config = onboardingConfigValue
        guard config.examples.count < OnboardingConfig.maxExamples else { return nil }
        let example = OnboardingExample(
            id: OnboardingConfig.makeID(existing: config.examples),
            label: label,
            prompt: prompt
        )
        config.examples.append(example)
        setOnboardingConfig(config)
        // Re-read: normalization may have rejected an empty label/prompt.
        return onboardingConfigValue.example(id: example.id)
    }

    /// Edits an example in place, keeping its id (live buttons keep working) and
    /// its tap counter (stats stay comparable across wording tweaks).
    @discardableResult
    func updateOnboardingExample(id: String, label: String, prompt: String) -> Bool {
        var config = onboardingConfigValue
        guard let index = config.examples.firstIndex(where: { $0.id == id }) else { return false }
        config.examples[index].label = label
        config.examples[index].prompt = prompt
        setOnboardingConfig(config)
        return onboardingConfigValue.example(id: id) != nil
    }

    @discardableResult
    func removeOnboardingExample(id: String) -> Bool {
        var config = onboardingConfigValue
        let before = config.examples.count
        config.examples.removeAll { $0.id == id }
        guard config.examples.count < before else { return false }
        setOnboardingConfig(config)
        return true
    }

    /// Flips one example on/off; returns the new state (nil = unknown id).
    func toggleOnboardingExample(id: String) -> Bool? {
        var config = onboardingConfigValue
        guard let index = config.examples.firstIndex(where: { $0.id == id }) else { return nil }
        config.examples[index].enabled.toggle()
        let newValue = config.examples[index].enabled
        setOnboardingConfig(config)
        return newValue
    }

    /// Cycles where an example is offered: везде → личка → группы → везде.
    /// Returns the new placement, nil when the example is gone.
    @discardableResult
    func cycleOnboardingExamplePlacement(id: String) -> OnboardingPlacement? {
        var config = onboardingConfigValue
        guard let index = config.examples.firstIndex(where: { $0.id == id }) else { return nil }
        config.examples[index].placement = config.examples[index].placement.next
        setOnboardingConfig(config)
        return onboardingConfigValue.example(id: id)?.placement
    }

    /// Moves an example one slot up — the order is the button order in the
    /// greeting, so this is how the super-admin puts the best example first.
    @discardableResult
    func moveOnboardingExampleUp(id: String) -> Bool {
        var config = onboardingConfigValue
        guard let index = config.examples.firstIndex(where: { $0.id == id }), index > 0 else { return false }
        config.examples.swapAt(index, index - 1)
        setOnboardingConfig(config)
        return true
    }

    /// Looks up a tapped example and counts the tap (per-example stat + funnel).
    /// Deliberately tolerant of a disabled example: a greeting already delivered
    /// keeps working after the super-admin hides it from new greetings.
    func recordOnboardingTap(id: String) -> OnboardingExample? {
        guard let index = onboardingConfigValue.examples.firstIndex(where: { $0.id == id }) else { return nil }
        onboardingConfigValue.examples[index].taps += 1
        dirtyConfigs.insert(.onboarding)
        bumpFunnel(.exampleTapped)
        return onboardingConfigValue.examples[index]
    }

    func resetOnboardingTapStats() {
        for index in onboardingConfigValue.examples.indices {
            onboardingConfigValue.examples[index].taps = 0
        }
        dirtyConfigs.insert(.onboarding)
    }

    /// Restores the shipped example set, keeping the on/off switches as they are.
    func resetOnboardingExamplesToDefaults() {
        var config = OnboardingConfig.default
        config.enabled = onboardingConfigValue.enabled
        config.showInGroups = onboardingConfigValue.showInGroups
        setOnboardingConfig(config)
    }
}
