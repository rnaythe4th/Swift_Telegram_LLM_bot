import Foundation

// Defaults and presets: tenant-scoped defaults, the four preset
// categories and their per-chat counterparts.

extension ChatContextStore {
    // MARK: - Defaults

    func defaultRole(chatID: Int) -> String {
        let baseRole = tenantState(for: chatID).defaultRole
        return roleWithCompanyMembers(chatID: chatID, role: baseRole + formatOptions)
    }

    func getDefaults(chatID: Int) -> (model: String, role: String, historyLength: Int) {
        let t = tenantState(for: chatID)
        return (t.defaultModel, t.defaultRole, t.defaultHistoryLength)
    }

    @discardableResult
    func setDefaultModel(_ model: String, chatID: Int) -> String {
        mutateTenant(for: chatID) { $0.defaultModel = model }
        return model
    }

    @discardableResult
    func setDefaultRole(_ role: String, chatID: Int) -> String {
        mutateTenant(for: chatID) { $0.defaultRole = role }
        return role
    }

    @discardableResult
    func setDefaultHistoryLength(_ length: Int, chatID: Int) -> Int {
        let clamped = max(1, length)
        mutateTenant(for: chatID) { $0.defaultHistoryLength = clamped }
        return clamped
    }

    // MARK: - Presets (tenant-scoped)

    func modelPresets(chatID: Int) -> [Preset] { tenantState(for: chatID).modelPresets }
    func tempPresets(chatID: Int) -> [Preset] { tenantState(for: chatID).tempPresets }
    func historyLengthPresets(chatID: Int) -> [Preset] { tenantState(for: chatID).historyLengthPresets }
    func rolePresets(chatID: Int) -> [Preset] { tenantState(for: chatID).rolePresets }

    func presets(for category: PresetCategory, chatID: Int) -> [Preset] {
        switch category {
        case .model: return modelPresets(chatID: chatID)
        case .temp: return tempPresets(chatID: chatID)
        case .history: return historyLengthPresets(chatID: chatID)
        case .role: return rolePresets(chatID: chatID)
        }
    }

    func addPreset(category: PresetCategory, display: String, value: String, provider: String? = nil, chatID: Int) -> Preset {
        let preset = Preset(display: display, value: value, provider: provider)
        mutateTenant(for: chatID) { tenant in
            switch category {
            case .model: tenant.modelPresets.append(preset)
            case .temp: tenant.tempPresets.append(preset)
            case .history: tenant.historyLengthPresets.append(preset)
            case .role: tenant.rolePresets.append(preset)
            }
        }
        return preset
    }

    func removePresetByIndex(category: PresetCategory, index: Int, chatID: Int) -> Bool {
        var success = false
        mutateTenant(for: chatID) { tenant in
            switch category {
            case .model:
                guard index >= 0, index < tenant.modelPresets.count else { return }
                tenant.modelPresets.remove(at: index)
                success = true
            case .temp:
                guard index >= 0, index < tenant.tempPresets.count else { return }
                tenant.tempPresets.remove(at: index)
                success = true
            case .history:
                guard index >= 0, index < tenant.historyLengthPresets.count else { return }
                tenant.historyLengthPresets.remove(at: index)
                success = true
            case .role:
                guard index >= 0, index < tenant.rolePresets.count else { return }
                tenant.rolePresets.remove(at: index)
                success = true
            }
        }
        return success
    }

    func editPreset(category: PresetCategory, index: Int, display: String, value: String, provider: String? = nil, chatID: Int) -> Bool {
        let preset = Preset(display: display, value: value, provider: provider)
        var success = false
        mutateTenant(for: chatID) { tenant in
            switch category {
            case .model:
                guard index >= 0, index < tenant.modelPresets.count else { return }
                tenant.modelPresets[index] = preset
                success = true
            case .temp:
                guard index >= 0, index < tenant.tempPresets.count else { return }
                tenant.tempPresets[index] = preset
                success = true
            case .history:
                guard index >= 0, index < tenant.historyLengthPresets.count else { return }
                tenant.historyLengthPresets[index] = preset
                success = true
            case .role:
                guard index >= 0, index < tenant.rolePresets.count else { return }
                tenant.rolePresets[index] = preset
                success = true
            }
        }
        return success
    }

    func addModelPreset(display: String, value: String, provider: String? = nil, chatID: Int) -> Preset {
        addPreset(category: .model, display: display, value: value, provider: provider, chatID: chatID)
    }

    func removeModelPreset(value: String, chatID: Int) -> Bool {
        var removed = false
        mutateTenant(for: chatID) { tenant in
            let before = tenant.modelPresets.count
            tenant.modelPresets.removeAll { $0.value == value }
            removed = tenant.modelPresets.count < before
        }
        return removed
    }

    func addTempPreset(display: String, value: String, chatID: Int) -> Preset {
        addPreset(category: .temp, display: display, value: value, chatID: chatID)
    }

    func removeTempPreset(value: String, chatID: Int) -> Bool {
        var removed = false
        mutateTenant(for: chatID) { tenant in
            let before = tenant.tempPresets.count
            tenant.tempPresets.removeAll { $0.value == value }
            removed = tenant.tempPresets.count < before
        }
        return removed
    }

    func addHistoryLengthPreset(display: String, value: String, chatID: Int) -> Preset {
        addPreset(category: .history, display: display, value: value, chatID: chatID)
    }

    func removeHistoryLengthPreset(value: String, chatID: Int) -> Bool {
        var removed = false
        mutateTenant(for: chatID) { tenant in
            let before = tenant.historyLengthPresets.count
            tenant.historyLengthPresets.removeAll { $0.value == value }
            removed = tenant.historyLengthPresets.count < before
        }
        return removed
    }

    func addRolePreset(display: String, value: String, chatID: Int) -> Preset {
        addPreset(category: .role, display: display, value: value, chatID: chatID)
    }

    func removeRolePreset(value: String, chatID: Int) -> Bool {
        var removed = false
        mutateTenant(for: chatID) { tenant in
            let before = tenant.rolePresets.count
            tenant.rolePresets.removeAll { $0.value == value }
            removed = tenant.rolePresets.count < before
        }
        return removed
    }

    // MARK: - Initial preset seeding (called at boot)

    func setModelPresets(_ presets: [Preset]) {
        mutateTenantByOwner(defaultOwnerUsername) { $0.modelPresets = presets }
    }

    func setTempPresets(_ presets: [Preset]) {
        mutateTenantByOwner(defaultOwnerUsername) { $0.tempPresets = presets }
    }

    func setHistoryLengthPresets(_ presets: [Preset]) {
        mutateTenantByOwner(defaultOwnerUsername) { $0.historyLengthPresets = presets }
    }

    func setRolePresets(_ presets: [Preset]) {
        mutateTenantByOwner(defaultOwnerUsername) { $0.rolePresets = presets }
    }

    // MARK: - Per-chat preset management

    func chatPresets(category: PresetCategory, chatKey: ChatKey) -> [Preset] {
        let ctx = ensure(chatKey: chatKey)
        switch category {
        case .model: return ctx.chatModelPresets
        case .temp: return ctx.chatTempPresets
        case .history: return ctx.chatHistoryLengthPresets
        case .role: return ctx.chatRolePresets
        }
    }

    func addChatPreset(category: PresetCategory, chatKey: ChatKey, display: String, value: String, provider: String? = nil) -> Preset {
        let preset = Preset(display: display, value: value, provider: provider)
        mutate(chatKey: chatKey) { ctx in
            switch category {
            case .model: ctx.chatModelPresets.append(preset)
            case .temp: ctx.chatTempPresets.append(preset)
            case .history: ctx.chatHistoryLengthPresets.append(preset)
            case .role: ctx.chatRolePresets.append(preset)
            }
        }
        return preset
    }

    func removeChatPresetByIndex(category: PresetCategory, chatKey: ChatKey, index: Int) -> Bool {
        var success = false
        mutate(chatKey: chatKey) { ctx in
            switch category {
            case .model:
                guard index >= 0, index < ctx.chatModelPresets.count else { return }
                ctx.chatModelPresets.remove(at: index)
                success = true
            case .temp:
                guard index >= 0, index < ctx.chatTempPresets.count else { return }
                ctx.chatTempPresets.remove(at: index)
                success = true
            case .history:
                guard index >= 0, index < ctx.chatHistoryLengthPresets.count else { return }
                ctx.chatHistoryLengthPresets.remove(at: index)
                success = true
            case .role:
                guard index >= 0, index < ctx.chatRolePresets.count else { return }
                ctx.chatRolePresets.remove(at: index)
                success = true
            }
        }
        return success
    }

    func editChatPreset(category: PresetCategory, chatKey: ChatKey, index: Int, display: String, value: String, provider: String? = nil) -> Bool {
        let preset = Preset(display: display, value: value, provider: provider)
        var success = false
        mutate(chatKey: chatKey) { ctx in
            switch category {
            case .model:
                guard index >= 0, index < ctx.chatModelPresets.count else { return }
                ctx.chatModelPresets[index] = preset
                success = true
            case .temp:
                guard index >= 0, index < ctx.chatTempPresets.count else { return }
                ctx.chatTempPresets[index] = preset
                success = true
            case .history:
                guard index >= 0, index < ctx.chatHistoryLengthPresets.count else { return }
                ctx.chatHistoryLengthPresets[index] = preset
                success = true
            case .role:
                guard index >= 0, index < ctx.chatRolePresets.count else { return }
                ctx.chatRolePresets[index] = preset
                success = true
            }
        }
        return success
    }
}
