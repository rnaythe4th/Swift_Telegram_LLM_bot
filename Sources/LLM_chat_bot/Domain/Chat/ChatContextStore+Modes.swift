import Foundation

// Reference modes: the super-admin-authored bundles of chat settings a user
// picks in one tap, and applying one to a chat.

extension ChatContextStore {

    // MARK: - Reading

    func modeConfig() -> ModePresetConfig { modeConfigValue }

    func activeModes() -> [ModePreset] { modeConfigValue.activeModes }

    func mode(id: String) -> ModePreset? { modeConfigValue.mode(id: id) }

    func defaultMode() -> ModePreset? { modeConfigValue.defaultMode }

    /// Which concrete model a mode runs on. `nil` in the mode means "any free
    /// one", which is resolved here rather than stored, so the free tier keeps
    /// working when OpenRouter's catalogue changes underneath it.
    func resolveModeModel(_ mode: ModePreset) -> String? {
        mode.model ?? fallbackFreeModel()
    }

    // MARK: - Writing (super-admin)

    func setModeConfig(_ config: ModePresetConfig) {
        modeConfigValue = config.normalized
        dirtyConfigs.insert(.modes)
    }

    private func mutateModes(_ block: (inout ModePresetConfig) -> Void) {
        var config = modeConfigValue
        block(&config)
        setModeConfig(config)
    }

    func setModesEnabled(_ enabled: Bool) {
        mutateModes { $0.enabled = enabled }
    }

    /// Adds a new mode or replaces the one with the same id, keeping its tap
    /// counter: editing the wording of a mode must not reset its statistics.
    func upsertMode(_ mode: ModePreset) {
        mutateModes { config in
            if let index = config.modes.firstIndex(where: { $0.id == mode.id }) {
                var updated = mode
                updated.taps = config.modes[index].taps
                config.modes[index] = updated
            } else {
                config.modes.append(mode)
            }
        }
    }

    @discardableResult
    func removeMode(id: String) -> Bool {
        guard modeConfigValue.modes.contains(where: { $0.id == id }) else { return false }
        mutateModes { config in
            config.modes.removeAll { $0.id == id }
            if config.defaultModeID == id { config.defaultModeID = nil }
        }
        return true
    }

    func toggleModeEnabled(id: String) {
        mutateModes { config in
            guard let index = config.modes.firstIndex(where: { $0.id == id }) else { return }
            config.modes[index].enabled.toggle()
        }
    }

    func cycleModeTier(id: String) {
        mutateModes { config in
            guard let index = config.modes.firstIndex(where: { $0.id == id }) else { return }
            config.modes[index].tier = config.modes[index].tier.next
        }
    }

    func moveModeUp(id: String) {
        mutateModes { config in
            guard let index = config.modes.firstIndex(where: { $0.id == id }), index > 0 else { return }
            config.modes.swapAt(index, index - 1)
        }
    }

    func setDefaultMode(id: String) {
        mutateModes { config in
            guard config.modes.contains(where: { $0.id == id }) else { return }
            config.defaultModeID = id
        }
    }

    func resetModes() {
        setModeConfig(.default)
    }

    func clearModeTaps() {
        mutateModes { config in
            for index in config.modes.indices { config.modes[index].taps = 0 }
        }
    }

    // MARK: - Applying to a chat

    /// Writes the whole bundle in one actor step and reports what landed.
    /// `nil` means the mode is unknown or has no model to run on (a free mode
    /// while the catalogue is unreachable) — the caller must say so rather than
    /// half-apply the settings.
    @discardableResult
    func applyMode(chatKey: ChatKey, modeID: String) -> ModePreset? {
        guard let mode = modeConfigValue.mode(id: modeID), let model = resolveModeModel(mode) else { return nil }
        let effectiveRole = mode.role.map {
            roleWithCompanyMembers(chatID: chatKey.chatID, role: $0 + formatOptions)
        }
        mutate(chatKey: chatKey) { context in
            let modelChanged = context.model != model || context.modelProviderRouting != mode.modelProviderRouting
            context.model = model
            context.modelProviderRouting = mode.modelProviderRouting
            context.temp = mode.temp
            context.maxHistory = mode.maxHistory
            context.reasoningEffort = mode.reasoning
            if let effectiveRole { context.role = effectiveRole }
            // The chat is on a model of its own choosing again, so there is
            // nothing left for the cap fallback to restore (roadmap step 6).
            context.downgradedFromModel = nil
            context.activeModeID = mode.id
            // Changing the model mid-conversation confuses every provider, and
            // the rest of the bot already promises "при смене модели переписка
            // очищается". Re-picking the mode the chat is already on must not
            // cost it the conversation.
            if modelChanged || effectiveRole != nil {
                context.history = [.init(role: "system", content: context.role)]
                context.pendingTurns = []
            }
        }
        return mode
    }

    /// Engagement counter, same idea as `OnboardingExample.taps`: which of the
    /// reference modes people actually pick is the only signal for whether the
    /// list is right. Counted by the button handler, not by `applyMode` — a
    /// reset also applies a mode, and counting that would make the working mode
    /// look popular for no reason.
    func noteModeTap(id: String) {
        mutateModes { config in
            guard let index = config.modes.firstIndex(where: { $0.id == id }) else { return }
            config.modes[index].taps += 1
        }
    }

    /// The mode a chat currently sits on, or `nil` when its settings have been
    /// hand-edited since (the page then says "изменён").
    func activeMode(chatKey: ChatKey) -> ModePreset? {
        guard let id = ensure(chatKey: chatKey).activeModeID else { return nil }
        return modeConfigValue.mode(id: id)
    }
}
