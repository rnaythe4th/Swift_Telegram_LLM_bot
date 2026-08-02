import Foundation

// Defaults and presets: tenant-scoped defaults, the four preset
// categories and their per-chat counterparts.

/// Where each category's presets live. One switch instead of one per operation:
/// a fifth category then fails to compile until it has been given a home, and
/// no operation can quietly address the wrong list.
extension PresetCategory {
    var tenantPresets: WritableKeyPath<TenantState, PresetList> {
        switch self {
        case .model: return \.modelPresets
        case .temp: return \.tempPresets
        case .history: return \.historyLengthPresets
        case .role: return \.rolePresets
        }
    }

    var chatPresets: WritableKeyPath<ChatContext, PresetList> {
        switch self {
        case .model: return \.chatModelPresets
        case .temp: return \.chatTempPresets
        case .history: return \.chatHistoryLengthPresets
        case .role: return \.chatRolePresets
        }
    }
}

extension ChatContextStore {
    // MARK: - Defaults

    func defaultRole(chatID: ChatID) -> String {
        let baseRole = tenantState(for: chatID).defaultRole
        return roleWithCompanyMembers(chatID: chatID, role: baseRole + formatOptions)
    }

    func getDefaults(chatID: ChatID) -> (model: String, role: String, historyLength: Int) {
        let t = tenantState(for: chatID)
        return (t.defaultModel, t.defaultRole, t.defaultHistoryLength)
    }

    @discardableResult
    func setDefaultModel(_ model: String, chatID: ChatID) -> String {
        mutateTenant(for: chatID) { $0.defaultModel = model }
        return model
    }

    @discardableResult
    func setDefaultRole(_ role: String, chatID: ChatID) -> String {
        mutateTenant(for: chatID) { $0.defaultRole = role }
        return role
    }

    /// The tenant default every new chat starts on, so it is bounded by the
    /// same range as the per-chat setting — otherwise it is a way in for a
    /// memory length no button can produce.
    @discardableResult
    func setDefaultHistoryLength(_ length: Int, chatID: ChatID) -> Int {
        let clamped = ChatContext.historyRange.clamping(length)
        mutateTenant(for: chatID) { $0.defaultHistoryLength = clamped }
        return clamped
    }

    // MARK: - Presets (tenant-scoped)

    func modelPresets(chatID: ChatID) -> [Preset] { presets(for: .model, chatID: chatID) }
    func tempPresets(chatID: ChatID) -> [Preset] { presets(for: .temp, chatID: chatID) }
    func historyLengthPresets(chatID: ChatID) -> [Preset] { presets(for: .history, chatID: chatID) }
    func rolePresets(chatID: ChatID) -> [Preset] { presets(for: .role, chatID: chatID) }

    func presets(for category: PresetCategory, chatID: ChatID) -> [Preset] {
        tenantState(for: chatID)[keyPath: category.tenantPresets].asArray
    }

    func addPreset(
        category: PresetCategory,
        display: String,
        value: String,
        provider: String? = nil,
        chatID: ChatID
    ) -> PresetList.AddOutcome {
        var outcome: PresetList.AddOutcome = .full
        mutateTenant(for: chatID) { tenant in
            outcome = tenant[keyPath: category.tenantPresets].add(display: display, value: value, provider: provider)
        }
        return outcome
    }

    /// False means the button named a preset that is no longer in the list —
    /// somebody edited it from another message while this page was open.
    func removePreset(category: PresetCategory, id: String, chatID: ChatID) -> Bool {
        var removed = false
        mutateTenant(for: chatID) { tenant in
            removed = tenant[keyPath: category.tenantPresets].remove(id: id)
        }
        return removed
    }

    func editPreset(
        category: PresetCategory,
        id: String,
        display: String,
        value: String,
        provider: String? = nil,
        chatID: ChatID
    ) -> Bool {
        var edited = false
        mutateTenant(for: chatID) { tenant in
            edited = tenant[keyPath: category.tenantPresets].replace(
                id: id,
                display: display,
                value: value,
                provider: provider
            )
        }
        return edited
    }

    /// `/presets <category> remove <value>`: addresses a preset by what it does,
    /// which is what someone typing a command has in front of them.
    func removePreset(category: PresetCategory, value: String, chatID: ChatID) -> Bool {
        var removed = false
        mutateTenant(for: chatID) { tenant in
            removed = tenant[keyPath: category.tenantPresets].removeAll(value: value)
        }
        return removed
    }

    // MARK: - Initial preset seeding (called at boot)

    func setPresets(_ category: PresetCategory, _ presets: [Preset]) {
        mutateTenantByOwner(configuredOwnerKey) { $0[keyPath: category.tenantPresets] = PresetList(presets) }
    }

    // MARK: - Per-chat preset management

    func chatPresets(category: PresetCategory, chatKey: ChatKey) -> [Preset] {
        ensure(chatKey: chatKey)[keyPath: category.chatPresets].asArray
    }

    func addChatPreset(
        category: PresetCategory,
        chatKey: ChatKey,
        display: String,
        value: String,
        provider: String? = nil
    ) -> PresetList.AddOutcome {
        var outcome: PresetList.AddOutcome = .full
        mutate(chatKey: chatKey) { ctx in
            outcome = ctx[keyPath: category.chatPresets].add(display: display, value: value, provider: provider)
        }
        return outcome
    }

    func removeChatPreset(category: PresetCategory, chatKey: ChatKey, id: String) -> Bool {
        var removed = false
        mutate(chatKey: chatKey) { ctx in
            removed = ctx[keyPath: category.chatPresets].remove(id: id)
        }
        return removed
    }

    func editChatPreset(
        category: PresetCategory,
        chatKey: ChatKey,
        id: String,
        display: String,
        value: String,
        provider: String? = nil
    ) -> Bool {
        var edited = false
        mutate(chatKey: chatKey) { ctx in
            edited = ctx[keyPath: category.chatPresets].replace(
                id: id,
                display: display,
                value: value,
                provider: provider
            )
        }
        return edited
    }
}
