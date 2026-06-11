import Foundation

enum SimulatedRole: String, Sendable, CaseIterable {
    case admin
    case regularUser = "user"
}

struct TenantState: Sendable {
    var ownerUsername: String
    var defaultModel: String
    var defaultRole: String
    var defaultHistoryLength: Int
    var modelPresets: [Preset]
    var tempPresets: [Preset]
    var historyLengthPresets: [Preset]
    var rolePresets: [Preset]
    var whitelistedUserIDs: Set<Int>
    var adminUsernames: Set<String>
    var licensedUsernames: Set<String>
    var cumulativeUsage: CumulativeUsage
}

struct TenantStatsRow: Sendable {
    let username: String
    let usage: CumulativeUsage
    let chatCount: Int
    let licensedUserCount: Int
    let isSuperAdmin: Bool
}

struct ChatContext: Sendable {
    enum PendingTurnState: Sendable {
        case pending
        case completed(String)
        case cancelled
    }

    struct PendingTurn: Sendable {
        let generationID: GenerationID
        let userMessage: ChatMessage
        var state: PendingTurnState
    }

    var role: String
    var history: [ChatMessage]
    var pendingTurns: [PendingTurn]
    var model: String
    // OpenRouter upstream provider pin for the current model (provider routing).
    var modelProviderRouting: String?
    var temp: Float
    var showStats: Bool
    var maxHistory: Int
    var showCost: Bool
    var showModel: Bool
    var provider: ServiceProvider
    var suffix: Int?
    var reasoningEffort: ReasoningEffort?
    var backupNotify: Bool
    var cumulativeUsage: CumulativeUsage
    var chatModelPresets: [Preset]
    var chatTempPresets: [Preset]
    var chatHistoryLengthPresets: [Preset]
    var chatRolePresets: [Preset]
}

struct GenerationSnapshot: Sendable {
    let provider: ServiceProvider
    let model: String
    let providerRouting: String?
    let temperature: Float
    let options: GenerationOptions
    let messages: [ChatMessage]
}

struct HelpData: Sendable {
    let model: String
    let modelProviderRouting: String?
    let role: String
    let temp: Float
    let maxHistory: Int
    let showTokens: Bool
    let showCost: Bool
    let showModel: Bool
    let defaultRole: String
    let provider: ServiceProvider
    let reasoningEffort: ReasoningEffort?
    let testModeSuffix: Int?
    let backupNotify: Bool
    let cumulativeUsage: CumulativeUsage
}

actor ChatContextStore {
    private var contexts: [ChatKey: ChatContext] = [:]
    private var tenants: [String: TenantState] = [:]
    private var chatOwnership: [Int: String] = [:]
    private var userTenantMap: [Int: String] = [:]

    private var superAdminUsernames: Set<String>
    private let rootSuperAdminUsername: String
    let defaultOwnerUsername: String
    var formatOptions: String
    let companyChatId: Int
    let companyMembers: String
    let defaultSuffix: Int?

    private let initialDefaultModel: String
    private let initialDefaultRole: String
    private let initialDefaultHistoryLength: Int

    private var _pendingInputs: [ChatKey: PendingInput] = [:]
    private var _starsPrice: Int? = nil
    private var _pendingStarsPriceInputs: [ChatKey: Int] = [:]
    private var _pendingFreeModelInputs: [ChatKey: Int] = [:]
    private var _freeModelIDs: [String] = []
    private var _openRouterFreeModelIDs: Set<String>? = nil
    private var _openRouterModelPrices: [String: ModelPriceInfo] = [:]

    private var _cryptoPriceUsdCents: Int? = nil
    private var _cryptoAddresses: [CryptoChain: String] = [:]
    private var _cryptoInvoices: [String: CryptoInvoice] = [:]
    private var _cryptoSlotCounters: [CryptoAsset: Int] = [:]
    private var _cryptoMatchMode: CryptoMatchMode = .amountDelta
    private var _cryptoAddressPools: [CryptoChain: [String]] = [:]
    private var _pendingCryptoPriceInputs: [ChatKey: Int] = [:]
    private var _pendingCryptoAddressInputs: [ChatKey: (menuMessageID: Int, chain: CryptoChain)] = [:]
    private var _pendingCryptoPoolAddInputs: [ChatKey: (menuMessageID: Int, chain: CryptoChain)] = [:]

    private var _simulatedRoles: [String: SimulatedRole] = [:]

    private var _pendingAdminInputs: [ChatKey: AdminPendingInput] = [:]

    init(
        ownerUsername: String,
        model: String,
        systemPrompt: String,
        formatOptions: String,
        companyChatId: Int,
        companyMembers: String,
        defaultHistoryLength: Int,
        defaultSuffix: Int?
    ) {
        let owner = ownerUsername.lowercased()
        self.superAdminUsernames = [owner]
        self.rootSuperAdminUsername = owner
        self.defaultOwnerUsername = owner
        self.formatOptions = formatOptions
        self.companyChatId = companyChatId
        self.companyMembers = companyMembers
        self.defaultSuffix = defaultSuffix
        self.initialDefaultModel = model
        self.initialDefaultRole = systemPrompt
        self.initialDefaultHistoryLength = defaultHistoryLength
        self.tenants = [
            owner: TenantState(
                ownerUsername: owner,
                defaultModel: model,
                defaultRole: systemPrompt,
                defaultHistoryLength: defaultHistoryLength,
                modelPresets: [],
                tempPresets: [],
                historyLengthPresets: [],
                rolePresets: [],
                whitelistedUserIDs: [],
                adminUsernames: [],
                licensedUsernames: [],
                cumulativeUsage: .zero
            )
        ]
    }

    // MARK: - Tenant routing helpers

    private func tenantState(for chatID: Int) -> TenantState {
        let owner = chatOwnership[chatID] ?? defaultOwnerUsername
        return tenants[owner] ?? tenants[defaultOwnerUsername]!
    }

    private func mutateTenant(for chatID: Int, _ block: (inout TenantState) -> Void) {
        let owner = chatOwnership[chatID] ?? defaultOwnerUsername
        guard var tenant = tenants[owner] else { return }
        block(&tenant)
        tenants[owner] = tenant
    }

    private func mutateTenantByOwner(_ ownerUsername: String, _ block: (inout TenantState) -> Void) {
        let u = ownerUsername.lowercased()
        guard var tenant = tenants[u] else { return }
        block(&tenant)
        tenants[u] = tenant
    }

    // MARK: - Tenant management

    func registerTenant(username: String) {
        let u = username.lowercased()
        guard tenants[u] == nil else { return }
        let defaults = tenants[defaultOwnerUsername]
        tenants[u] = TenantState(
            ownerUsername: u,
            defaultModel: defaults?.defaultModel ?? initialDefaultModel,
            defaultRole: defaults?.defaultRole ?? initialDefaultRole,
            defaultHistoryLength: defaults?.defaultHistoryLength ?? initialDefaultHistoryLength,
            modelPresets: [],
            tempPresets: [],
            historyLengthPresets: [],
            rolePresets: [],
            whitelistedUserIDs: [],
            adminUsernames: [],
            licensedUsernames: [],
            cumulativeUsage: .zero
        )
    }

    @discardableResult
    func removeTenant(username: String) -> Bool {
        let u = username.lowercased()
        guard u != defaultOwnerUsername, tenants[u] != nil else { return false }
        tenants.removeValue(forKey: u)
        chatOwnership = chatOwnership.filter { $0.value != u }
        userTenantMap = userTenantMap.filter { $0.value != u }
        return true
    }

    func listTenants() -> [String] {
        Array(tenants.keys).sorted()
    }

    func isTenant(username: String) -> Bool {
        tenants[username.lowercased()] != nil
    }

    func chatOwner(chatID: Int) -> String? {
        chatOwnership[chatID]
    }

    func effectiveOwnerUsername(chatID: Int) -> String {
        chatOwnership[chatID] ?? defaultOwnerUsername
    }

    @discardableResult
    func assignChat(chatID: Int, to ownerUsername: String) -> Bool {
        let u = ownerUsername.lowercased()
        guard tenants[u] != nil else { return false }
        chatOwnership[chatID] = u
        return true
    }

    @discardableResult
    func unassignChat(chatID: Int) -> String? {
        chatOwnership.removeValue(forKey: chatID)
    }

    func chatsOwnedBy(_ ownerUsername: String) -> [Int] {
        let u = ownerUsername.lowercased()
        return chatOwnership.compactMap { $0.value == u ? $0.key : nil }
    }

    func autoAssignIfNeeded(chatID: Int, senderUsername: String?, senderUserID: Int?) {
        guard chatOwnership[chatID] == nil else { return }
        if let username = senderUsername?.lowercased(), tenants[username] != nil {
            chatOwnership[chatID] = username
        } else if let userID = senderUserID, let owner = userTenantMap[userID] {
            chatOwnership[chatID] = owner
        }
    }

    // MARK: - Auth

    func isSuperAdmin(username: String?) -> Bool {
        guard let u = username?.lowercased() else { return false }
        guard superAdminUsernames.contains(u) else { return false }
        return _simulatedRoles[u] == nil
    }

    /// Raw super-admin check that ignores any active simulation. Use only for
    /// gating commands that must remain reachable while a simulation is active
    /// (e.g. `/simulate` itself).
    func isActuallySuperAdmin(username: String?) -> Bool {
        guard let u = username?.lowercased() else { return false }
        return superAdminUsernames.contains(u)
    }

    /// True only for the immutable bootstrap super-admin (default @maythe4th).
    /// Only this user may add or remove other super-admins.
    func isRootSuperAdmin(username: String?) -> Bool {
        guard let u = username?.lowercased() else { return false }
        return u == rootSuperAdminUsername
    }

    func listSuperAdmins() -> [String] {
        superAdminUsernames.sorted()
    }

    @discardableResult
    func addSuperAdmin(target: String) -> Bool {
        let u = target.lowercased()
        guard !u.isEmpty else { return false }
        return superAdminUsernames.insert(u).inserted
    }

    @discardableResult
    func removeSuperAdmin(target: String) -> Bool {
        let u = target.lowercased()
        guard u != rootSuperAdminUsername else { return false }
        return superAdminUsernames.remove(u) != nil
    }

    func simulatedRole(username: String?) -> SimulatedRole? {
        guard let u = username?.lowercased() else { return nil }
        guard superAdminUsernames.contains(u) else { return nil }
        return _simulatedRoles[u]
    }

    @discardableResult
    func setSimulatedRole(username: String, role: SimulatedRole?) -> Bool {
        let u = username.lowercased()
        guard superAdminUsernames.contains(u) else { return false }
        if let role {
            _simulatedRoles[u] = role
        } else {
            _simulatedRoles.removeValue(forKey: u)
        }
        return true
    }

    func isTenantOwner(username: String?, chatID: Int) -> Bool {
        guard let u = username?.lowercased() else { return false }
        if superAdminUsernames.contains(u) {
            if _simulatedRoles[u] != nil { return false }
            return true
        }
        return effectiveOwnerUsername(chatID: chatID) == u
    }

    func isAdmin(username: String?, chatID: Int) -> Bool {
        guard let u = username?.lowercased() else { return false }
        if let sim = _simulatedRoles[u], superAdminUsernames.contains(u) {
            return sim == .admin
        }
        if superAdminUsernames.contains(u) { return true }
        let owner = effectiveOwnerUsername(chatID: chatID)
        if u == owner { return true }
        return tenants[owner]?.adminUsernames.contains(u) ?? false
    }

    func isWhitelisted(userID: Int, chatID: Int) -> Bool {
        tenantState(for: chatID).whitelistedUserIDs.contains(userID)
    }

    func addToWhitelist(userID: Int, chatID: Int) {
        mutateTenant(for: chatID) { $0.whitelistedUserIDs.insert(userID) }
        let owner = effectiveOwnerUsername(chatID: chatID)
        userTenantMap[userID] = owner
    }

    func removeFromWhitelist(userID: Int, chatID: Int) {
        mutateTenant(for: chatID) { $0.whitelistedUserIDs.remove(userID) }
        userTenantMap.removeValue(forKey: userID)
    }

    func listWhitelisted(chatID: Int) -> Set<Int> {
        tenantState(for: chatID).whitelistedUserIDs
    }

    func addAdmin(username: String, chatID: Int) {
        let u = username.lowercased()
        mutateTenant(for: chatID) { $0.adminUsernames.insert(u) }
    }

    func removeAdmin(username: String, chatID: Int) {
        let u = username.lowercased()
        mutateTenant(for: chatID) { $0.adminUsernames.remove(u) }
    }

    func listAdmins(chatID: Int) -> Set<String> {
        tenantState(for: chatID).adminUsernames
    }

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

    // MARK: - Chat context helpers

    private func roleWithCompanyMembers(chatID: Int, role: String) -> String {
        chatID == companyChatId ? role + companyMembers : role
    }

    private func ensure(chatKey: ChatKey) -> ChatContext {
        if let context = contexts[chatKey] {
            return context
        }
        let tenant = tenantState(for: chatKey.chatID)
        let role = roleWithCompanyMembers(chatID: chatKey.chatID, role: tenant.defaultRole + formatOptions)
        let context = ChatContext(
            role: role,
            history: [.init(role: "system", content: role)],
            pendingTurns: [],
            model: tenant.defaultModel,
            modelProviderRouting: nil,
            temp: 1.5,
            showStats: false,
            maxHistory: tenant.defaultHistoryLength,
            showCost: true,
            showModel: true,
            provider: .openrouter,
            suffix: defaultSuffix,
            reasoningEffort: nil,
            backupNotify: false,
            cumulativeUsage: .zero,
            chatModelPresets: [],
            chatTempPresets: [],
            chatHistoryLengthPresets: [],
            chatRolePresets: []
        )
        contexts[chatKey] = context
        return context
    }

    private func mutate(chatKey: ChatKey, _ block: (inout ChatContext) -> Void) {
        var context = ensure(chatKey: chatKey)
        block(&context)
        contexts[chatKey] = context
    }

    private func trimHistory(_ history: [ChatMessage], limit: Int) -> [ChatMessage] {
        guard let first = history.first else { return history }
        let safeLimit = max(1, limit)
        let tail = Array(history.dropFirst())
        let clipped = tail.suffix(safeLimit)
        return [first] + clipped
    }

    private func visibleHistory(for context: ChatContext) -> [ChatMessage] {
        let pendingUserMessages = context.pendingTurns.map(\.userMessage)
        return trimHistory(context.history + pendingUserMessages, limit: context.maxHistory)
    }

    private func flushResolvedTurns(_ context: inout ChatContext) {
        while let first = context.pendingTurns.first {
            switch first.state {
            case .pending:
                context.history = trimHistory(context.history, limit: context.maxHistory)
                return
            case .completed(let assistantContent):
                context.history.append(first.userMessage)
                context.history.append(.init(role: "assistant", content: assistantContent))
                context.pendingTurns.removeFirst()
            case .cancelled:
                context.pendingTurns.removeFirst()
            }
        }
        context.history = trimHistory(context.history, limit: context.maxHistory)
    }

    // MARK: - Help

    func fetchHelp(chatKey: ChatKey) -> HelpData {
        let context = ensure(chatKey: chatKey)
        return .init(
            model: context.model,
            modelProviderRouting: context.modelProviderRouting,
            role: displayRole(context.role, chatID: chatKey.chatID),
            temp: context.temp,
            maxHistory: context.maxHistory,
            showTokens: context.showStats,
            showCost: context.showCost,
            showModel: context.showModel,
            defaultRole: displayRole(defaultRole(chatID: chatKey.chatID), chatID: chatKey.chatID),
            provider: context.provider,
            reasoningEffort: context.reasoningEffort,
            testModeSuffix: context.suffix,
            backupNotify: context.backupNotify,
            cumulativeUsage: context.cumulativeUsage
        )
    }

    private func displayRole(_ role: String, chatID: Int) -> String {
        var s = role
        if !companyMembers.isEmpty, chatID == companyChatId, s.hasSuffix(companyMembers) {
            s = String(s.dropLast(companyMembers.count))
        }
        if s.hasSuffix(formatOptions) {
            s = String(s.dropLast(formatOptions.count))
        }
        return s
    }

    // MARK: - Chat context mutations

    func suffix(chatKey: ChatKey) -> Int? {
        ensure(chatKey: chatKey).suffix
    }

    func toggleTestMode(chatKey: ChatKey) -> Int? {
        let current = ensure(chatKey: chatKey).suffix
        if current == nil {
            let newSuffix = Int.random(in: 1...10)
            mutate(chatKey: chatKey) { $0.suffix = newSuffix }
            return newSuffix
        }
        mutate(chatKey: chatKey) { $0.suffix = nil }
        return nil
    }

    func toggleReasoning(chatKey: ChatKey) -> ReasoningEffort? {
        let current = ensure(chatKey: chatKey).reasoningEffort
        let next: ReasoningEffort?
        switch current {
        case nil:       next = .high
        case .high:     next = .medium
        case .medium:   next = .low
        case .low:      next = nil
        }
        mutate(chatKey: chatKey) { $0.reasoningEffort = next }
        return next
    }

    func setReasoningEffort(chatKey: ChatKey, effort: ReasoningEffort?) {
        mutate(chatKey: chatKey) { $0.reasoningEffort = effort }
    }

    func reasoningEnabled(chatKey: ChatKey) -> Bool {
        ensure(chatKey: chatKey).reasoningEffort != nil
    }

    func reasoningEffort(chatKey: ChatKey) -> ReasoningEffort? {
        ensure(chatKey: chatKey).reasoningEffort
    }

    func setMaxHistory(chatKey: ChatKey, newMax: Int) {
        mutate(chatKey: chatKey) { context in
            context.maxHistory = max(1, newMax)
            context.history = trimHistory(context.history, limit: context.maxHistory)
        }
    }

    func setRoleAndResetHistory(chatKey: ChatKey, role: String) -> String {
        let effectiveRole = roleWithCompanyMembers(chatID: chatKey.chatID, role: role)
        mutate(chatKey: chatKey) { context in
            context.role = effectiveRole
            context.history = [.init(role: "system", content: effectiveRole)]
            context.pendingTurns = []
        }
        return effectiveRole
    }

    func clearHistory(chatKey: ChatKey) {
        mutate(chatKey: chatKey) { context in
            context.history = [.init(role: "system", content: context.role)]
            context.pendingTurns = []
        }
    }

    func setTemperature(chatKey: ChatKey, value: Float) {
        mutate(chatKey: chatKey) { $0.temp = value }
    }

    func temperature(chatKey: ChatKey) -> Float {
        ensure(chatKey: chatKey).temp
    }

    func setModelAndResetHistory(chatKey: ChatKey, newModel: String, providerRouting: String? = nil) -> (old: String, new: String) {
        let old = ensure(chatKey: chatKey).model
        mutate(chatKey: chatKey) { context in
            context.model = newModel
            context.modelProviderRouting = providerRouting
            context.history = [.init(role: "system", content: context.role)]
            context.pendingTurns = []
        }
        return (old, newModel)
    }

    func toggleShowStats(chatKey: ChatKey) -> Bool {
        mutate(chatKey: chatKey) { $0.showStats.toggle() }
        return ensure(chatKey: chatKey).showStats
    }

    func toggleShowCost(chatKey: ChatKey) -> Bool {
        mutate(chatKey: chatKey) { $0.showCost.toggle() }
        return ensure(chatKey: chatKey).showCost
    }

    func toggleShowModel(chatKey: ChatKey) -> Bool {
        mutate(chatKey: chatKey) { $0.showModel.toggle() }
        return ensure(chatKey: chatKey).showModel
    }

    func toggleBackupNotify(chatKey: ChatKey) -> Bool {
        mutate(chatKey: chatKey) { $0.backupNotify.toggle() }
        return ensure(chatKey: chatKey).backupNotify
    }

    func changeProvider(chatKey: ChatKey, newProvider: ServiceProvider) -> ServiceProvider {
        let oldProvider = ensure(chatKey: chatKey).provider
        mutate(chatKey: chatKey) { $0.provider = newProvider }
        return oldProvider
    }

    func provider(chatKey: ChatKey) -> ServiceProvider {
        ensure(chatKey: chatKey).provider
    }

    func snapshotAndAppend(
        chatKey: ChatKey,
        generationID: GenerationID,
        content: UserInputContent,
        username: String?
    ) -> GenerationSnapshot {
        var context = ensure(chatKey: chatKey)
        let userMessage = ChatMessage.userContent(content, username: username)
        context.pendingTurns.append(.init(generationID: generationID, userMessage: userMessage, state: .pending))
        let messages = visibleHistory(for: context)
        contexts[chatKey] = context
        return .init(
            provider: context.provider,
            model: context.model,
            providerRouting: context.modelProviderRouting,
            temperature: context.temp,
            options: .init(
                showStats: context.showStats,
                showCost: context.showCost,
                showModel: context.showModel,
                reasoningEffort: context.reasoningEffort
            ),
            messages: messages
        )
    }

    func appendAssistant(chatKey: ChatKey, generationID: GenerationID, content: String, usage: StreamUsageSummary? = nil) {
        mutate(chatKey: chatKey) { context in
            guard let index = context.pendingTurns.firstIndex(where: { $0.generationID == generationID }) else {
                return
            }
            context.pendingTurns[index].state = .completed(content)
            flushResolvedTurns(&context)
            context.cumulativeUsage.totalTokens += usage?.totalTokens ?? 0
            context.cumulativeUsage.totalCost += usage?.cost ?? 0
            context.cumulativeUsage.generationCount += 1
        }
        accumulateTenantUsage(chatID: chatKey.chatID, usage: usage)
    }

    func cancelPendingTurn(chatKey: ChatKey, generationID: GenerationID) {
        mutate(chatKey: chatKey) { context in
            guard let index = context.pendingTurns.firstIndex(where: { $0.generationID == generationID }) else {
                return
            }
            context.pendingTurns[index].state = .cancelled
            flushResolvedTurns(&context)
        }
    }

    func accumulateUsage(chatKey: ChatKey, usage: StreamUsageSummary?) {
        mutate(chatKey: chatKey) { context in
            context.cumulativeUsage.totalTokens += usage?.totalTokens ?? 0
            context.cumulativeUsage.totalCost += usage?.cost ?? 0
            context.cumulativeUsage.generationCount += 1
        }
        accumulateTenantUsage(chatID: chatKey.chatID, usage: usage)
    }

    func resetUsage(chatKey: ChatKey) {
        mutate(chatKey: chatKey) { $0.cumulativeUsage = .zero }
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

    // MARK: - Pending input

    func setPendingInput(_ input: PendingInput, chatKey: ChatKey) {
        _pendingInputs[chatKey] = input
    }

    func consumePendingInput(chatKey: ChatKey) -> PendingInput? {
        _pendingInputs.removeValue(forKey: chatKey)
    }

    func clearPendingInput(chatKey: ChatKey) {
        _pendingInputs.removeValue(forKey: chatKey)
    }

    func hasPendingInput(chatKey: ChatKey) -> Bool {
        _pendingInputs[chatKey] != nil
    }

    // MARK: - Stars price

    func starsPrice() -> Int? { _starsPrice }

    func setStarsPrice(_ price: Int?) {
        _starsPrice = price.flatMap { $0 > 0 ? $0 : nil }
    }

    func setPendingStarsPriceInput(menuMessageID: Int, chatKey: ChatKey) {
        _pendingStarsPriceInputs[chatKey] = menuMessageID
    }

    func consumePendingStarsPriceInput(chatKey: ChatKey) -> Int? {
        _pendingStarsPriceInputs.removeValue(forKey: chatKey)
    }

    func hasPendingStarsPriceInput(chatKey: ChatKey) -> Bool {
        _pendingStarsPriceInputs[chatKey] != nil
    }

    func clearPendingStarsPriceInput(chatKey: ChatKey) {
        _pendingStarsPriceInputs.removeValue(forKey: chatKey)
    }

    // MARK: - Pending free model input

    func setPendingFreeModelInput(menuMessageID: Int, chatKey: ChatKey) {
        _pendingFreeModelInputs[chatKey] = menuMessageID
    }

    func consumePendingFreeModelInput(chatKey: ChatKey) -> Int? {
        _pendingFreeModelInputs.removeValue(forKey: chatKey)
    }

    func hasPendingFreeModelInput(chatKey: ChatKey) -> Bool {
        _pendingFreeModelInputs[chatKey] != nil
    }

    func clearPendingFreeModelInput(chatKey: ChatKey) {
        _pendingFreeModelInputs.removeValue(forKey: chatKey)
    }

    // MARK: - Free model access

    func freeModelIDs() -> [String] { _freeModelIDs }

    func setFreeModelIDs(_ ids: [String]) {
        _freeModelIDs = ids.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    @discardableResult
    func addFreeModel(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !_freeModelIDs.contains(trimmed) else { return false }
        _freeModelIDs.append(trimmed)
        return true
    }

    @discardableResult
    func removeFreeModel(_ id: String) -> Bool {
        let before = _freeModelIDs.count
        _freeModelIDs.removeAll { $0 == id }
        return _freeModelIDs.count < before
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

    func firstFreeModel() -> String? {
        effectiveFreeModelIDs()?.first
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

    // MARK: - Crypto config

    func cryptoPriceUsdCents() -> Int? { _cryptoPriceUsdCents }

    func setCryptoPriceUsdCents(_ value: Int?) {
        _cryptoPriceUsdCents = value.flatMap { $0 > 0 ? $0 : nil }
    }

    func cryptoAddress(_ chain: CryptoChain) -> String? {
        _cryptoAddresses[chain]
    }

    func cryptoAddresses() -> [CryptoChain: String] { _cryptoAddresses }

    func setCryptoAddress(_ chain: CryptoChain, address: String?) {
        let trimmed = address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            _cryptoAddresses.removeValue(forKey: chain)
        } else {
            _cryptoAddresses[chain] = trimmed
        }
    }

    func nextCryptoSlot(asset: CryptoAsset) -> Int {
        let max = asset.maxConcurrentSlots
        let current = (_cryptoSlotCounters[asset] ?? Int.random(in: 0..<max))
        let next = (current + 1) % max
        _cryptoSlotCounters[asset] = next
        return next
    }

    func upsertCryptoInvoice(_ invoice: CryptoInvoice) {
        _cryptoInvoices[invoice.id] = invoice
    }

    func cryptoInvoice(id: String) -> CryptoInvoice? {
        _cryptoInvoices[id]
    }

    func openCryptoInvoices() -> [CryptoInvoice] {
        _cryptoInvoices.values.filter { $0.status == .open || $0.status == .partial }
    }

    func openCryptoInvoices(asset: CryptoAsset) -> [CryptoInvoice] {
        _cryptoInvoices.values.filter {
            ($0.status == .open || $0.status == .partial) && $0.asset == asset
        }
    }

    func openCryptoInvoiceForUser(username: String, asset: CryptoAsset) -> CryptoInvoice? {
        let u = username.lowercased()
        return _cryptoInvoices.values.first {
            $0.username == u && $0.asset == asset && ($0.status == .open || $0.status == .partial)
        }
    }

    func cancelCryptoInvoice(id: String) {
        guard var inv = _cryptoInvoices[id] else { return }
        if inv.status == .open || inv.status == .partial {
            inv.status = .cancelled
            _cryptoInvoices[id] = inv
        }
    }

    func expireDueCryptoInvoices(now: Date = Date()) -> [CryptoInvoice] {
        var expired: [CryptoInvoice] = []
        for (id, inv) in _cryptoInvoices {
            guard inv.status == .open || inv.status == .partial else { continue }
            if now >= inv.expiresAt {
                var copy = inv
                copy.status = .expired
                _cryptoInvoices[id] = copy
                expired.append(copy)
            }
        }
        return expired
    }

    func usedSlots(asset: CryptoAsset) -> Set<Int> {
        Set(
            _cryptoInvoices.values
                .filter { ($0.status == .open || $0.status == .partial) && $0.asset == asset }
                .map { $0.slotOffset }
        )
    }

    func setPendingCryptoPriceInput(menuMessageID: Int, chatKey: ChatKey) {
        _pendingCryptoPriceInputs[chatKey] = menuMessageID
    }

    func consumePendingCryptoPriceInput(chatKey: ChatKey) -> Int? {
        _pendingCryptoPriceInputs.removeValue(forKey: chatKey)
    }

    func hasPendingCryptoPriceInput(chatKey: ChatKey) -> Bool {
        _pendingCryptoPriceInputs[chatKey] != nil
    }

    func clearPendingCryptoPriceInput(chatKey: ChatKey) {
        _pendingCryptoPriceInputs.removeValue(forKey: chatKey)
    }

    func setPendingCryptoAddressInput(menuMessageID: Int, chain: CryptoChain, chatKey: ChatKey) {
        _pendingCryptoAddressInputs[chatKey] = (menuMessageID, chain)
    }

    func consumePendingCryptoAddressInput(chatKey: ChatKey) -> (menuMessageID: Int, chain: CryptoChain)? {
        _pendingCryptoAddressInputs.removeValue(forKey: chatKey)
    }

    func hasPendingCryptoAddressInput(chatKey: ChatKey) -> Bool {
        _pendingCryptoAddressInputs[chatKey] != nil
    }

    func clearPendingCryptoAddressInput(chatKey: ChatKey) {
        _pendingCryptoAddressInputs.removeValue(forKey: chatKey)
    }

    func cryptoMatchMode() -> CryptoMatchMode { _cryptoMatchMode }

    func setCryptoMatchMode(_ mode: CryptoMatchMode) {
        _cryptoMatchMode = mode
    }

    func cryptoAddressPool(_ chain: CryptoChain) -> [String] {
        _cryptoAddressPools[chain] ?? []
    }

    func cryptoAddressPools() -> [CryptoChain: [String]] { _cryptoAddressPools }

    @discardableResult
    func addCryptoPoolAddress(_ chain: CryptoChain, address: String) -> Bool {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var pool = _cryptoAddressPools[chain] ?? []
        guard !pool.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return false }
        pool.append(trimmed)
        _cryptoAddressPools[chain] = pool
        return true
    }

    @discardableResult
    func removeCryptoPoolAddress(_ chain: CryptoChain, at index: Int) -> Bool {
        guard var pool = _cryptoAddressPools[chain], index >= 0, index < pool.count else { return false }
        pool.remove(at: index)
        if pool.isEmpty {
            _cryptoAddressPools.removeValue(forKey: chain)
        } else {
            _cryptoAddressPools[chain] = pool
        }
        return true
    }

    /// All addresses worth polling for a chain — primary delta address plus pool.
    func pollableCryptoAddresses(_ chain: CryptoChain) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        if let primary = _cryptoAddresses[chain] {
            let key = primary.lowercased()
            if !seen.contains(key) { seen.insert(key); result.append(primary) }
        }
        for addr in _cryptoAddressPools[chain] ?? [] {
            let key = addr.lowercased()
            if !seen.contains(key) { seen.insert(key); result.append(addr) }
        }
        return result
    }

    /// Addresses already allocated to open/partial invoices for given asset.
    func allocatedPoolAddresses(asset: CryptoAsset) -> Set<String> {
        Set(
            _cryptoInvoices.values
                .filter { ($0.status == .open || $0.status == .partial) && $0.asset == asset }
                .map { $0.receivingAddress.lowercased() }
        )
    }

    /// Find first pool address for the chain that's not currently held by an open invoice
    /// of any asset on that chain.
    func nextFreePoolAddress(chain: CryptoChain) -> String? {
        let pool = _cryptoAddressPools[chain] ?? []
        guard !pool.isEmpty else { return nil }
        let allocated = Set(
            _cryptoInvoices.values
                .filter { ($0.status == .open || $0.status == .partial) && $0.asset.chain == chain }
                .map { $0.receivingAddress.lowercased() }
        )
        return pool.first { !allocated.contains($0.lowercased()) }
    }

    func openInvoiceMatching(asset: CryptoAsset, address: String) -> CryptoInvoice? {
        let target = address.lowercased()
        return _cryptoInvoices.values.first {
            ($0.status == .open || $0.status == .partial)
                && $0.asset == asset
                && $0.receivingAddress.lowercased() == target
        }
    }

    func setAdminPendingInput(_ input: AdminPendingInput, chatKey: ChatKey) {
        _pendingAdminInputs[chatKey] = input
    }

    func consumeAdminPendingInput(chatKey: ChatKey) -> AdminPendingInput? {
        _pendingAdminInputs.removeValue(forKey: chatKey)
    }

    func hasAdminPendingInput(chatKey: ChatKey) -> Bool {
        _pendingAdminInputs[chatKey] != nil
    }

    func clearAdminPendingInput(chatKey: ChatKey) {
        _pendingAdminInputs.removeValue(forKey: chatKey)
    }

    func setPendingCryptoPoolAddInput(menuMessageID: Int, chain: CryptoChain, chatKey: ChatKey) {
        _pendingCryptoPoolAddInputs[chatKey] = (menuMessageID, chain)
    }

    func consumePendingCryptoPoolAddInput(chatKey: ChatKey) -> (menuMessageID: Int, chain: CryptoChain)? {
        _pendingCryptoPoolAddInputs.removeValue(forKey: chatKey)
    }

    func hasPendingCryptoPoolAddInput(chatKey: ChatKey) -> Bool {
        _pendingCryptoPoolAddInputs[chatKey] != nil
    }

    func clearPendingCryptoPoolAddInput(chatKey: ChatKey) {
        _pendingCryptoPoolAddInputs.removeValue(forKey: chatKey)
    }

    func cryptoConfigSnapshot() -> CryptoConfigSnapshot {
        var addrs: [String: String] = [:]
        for (chain, value) in _cryptoAddresses { addrs[chain.rawValue] = value }
        var counters: [String: Int] = [:]
        for (asset, value) in _cryptoSlotCounters { counters[asset.rawValue] = value }
        var pools: [String: [String]] = [:]
        for (chain, list) in _cryptoAddressPools { pools[chain.rawValue] = list }
        return CryptoConfigSnapshot(
            priceUsdCents: _cryptoPriceUsdCents,
            addresses: addrs,
            slotCounters: counters,
            invoices: Array(_cryptoInvoices.values),
            matchMode: _cryptoMatchMode.rawValue,
            addressPools: pools.isEmpty ? nil : pools
        )
    }

    func restoreCryptoConfig(_ snapshot: CryptoConfigSnapshot?) {
        _cryptoPriceUsdCents = snapshot?.priceUsdCents
        _cryptoAddresses = [:]
        for (key, value) in snapshot?.addresses ?? [:] {
            if let chain = CryptoChain(rawValue: key) {
                _cryptoAddresses[chain] = value
            }
        }
        _cryptoSlotCounters = [:]
        for (key, value) in snapshot?.slotCounters ?? [:] {
            if let asset = CryptoAsset(rawValue: key) {
                _cryptoSlotCounters[asset] = value
            }
        }
        _cryptoInvoices = [:]
        for invoice in snapshot?.invoices ?? [] {
            _cryptoInvoices[invoice.id] = invoice
        }
        _cryptoMatchMode = (snapshot?.matchMode).flatMap { CryptoMatchMode(rawValue: $0) } ?? .amountDelta
        _cryptoAddressPools = [:]
        for (key, list) in snapshot?.addressPools ?? [:] {
            if let chain = CryptoChain(rawValue: key) {
                _cryptoAddressPools[chain] = list
            }
        }
    }

    func superAdminPrivateChats() -> [ChatKey] {
        contexts.keys.filter { $0.chatID > 0 && chatOwnership[$0.chatID] == defaultOwnerUsername }.map { $0 }
    }

    func hasFullModelAccess(username: String?, userID: Int? = nil, chatID: Int? = nil) -> Bool {
        let lowered = username?.lowercased()
        let simulated: Bool = {
            guard let u = lowered else { return false }
            return superAdminUsernames.contains(u) && _simulatedRoles[u] != nil
        }()

        if !simulated, let u = lowered {
            if tenants[u] != nil { return true }
            for tenant in tenants.values where tenant.licensedUsernames.contains(u) {
                return true
            }
        }

        // Chat-level licensing: chat assigned to a tenant grants access to all members.
        if let chatID, chatOwnership[chatID] != nil {
            return true
        }
        // Per-chat whitelisted user IDs (set by tenant owner for this chat).
        if let chatID, let userID,
           tenantState(for: chatID).whitelistedUserIDs.contains(userID) {
            return true
        }
        return false
    }

    // MARK: - Per-tenant licensed users (paid access for individuals)

    @discardableResult
    func addLicensedUser(ownerUsername: String, target: String) -> Bool {
        let owner = ownerUsername.lowercased()
        let user = target.lowercased()
        guard !user.isEmpty, tenants[owner] != nil else { return false }
        var inserted = false
        mutateTenantByOwner(owner) { inserted = $0.licensedUsernames.insert(user).inserted }
        return inserted
    }

    @discardableResult
    func removeLicensedUser(ownerUsername: String, target: String) -> Bool {
        let owner = ownerUsername.lowercased()
        let user = target.lowercased()
        guard tenants[owner] != nil else { return false }
        var removed = false
        mutateTenantByOwner(owner) { removed = $0.licensedUsernames.remove(user) != nil }
        return removed
    }

    func licensedUsers(ownerUsername: String) -> [String] {
        Array(tenants[ownerUsername.lowercased()]?.licensedUsernames ?? []).sorted()
    }

    // MARK: - Tenant usage / stats

    func tenantUsage(ownerUsername: String) -> CumulativeUsage {
        tenants[ownerUsername.lowercased()]?.cumulativeUsage ?? .zero
    }

    func tenantStats() -> [TenantStatsRow] {
        tenants.values.map { tenant in
            let owner = tenant.ownerUsername
            let chats = chatOwnership.values.filter { $0 == owner }.count
            return TenantStatsRow(
                username: owner,
                usage: tenant.cumulativeUsage,
                chatCount: chats,
                licensedUserCount: tenant.licensedUsernames.count,
                isSuperAdmin: superAdminUsernames.contains(owner)
            )
        }
        .sorted { $0.username < $1.username }
    }

    private func accumulateTenantUsage(chatID: Int, usage: StreamUsageSummary?) {
        let owner = chatOwnership[chatID] ?? defaultOwnerUsername
        mutateTenantByOwner(owner) {
            $0.cumulativeUsage.totalTokens += usage?.totalTokens ?? 0
            $0.cumulativeUsage.totalCost += usage?.cost ?? 0
            $0.cumulativeUsage.generationCount += 1
        }
    }

    func model(chatKey: ChatKey) -> String {
        ensure(chatKey: chatKey).model
    }

    func setModelOnly(chatKey: ChatKey, model: String) {
        mutate(chatKey: chatKey) {
            $0.model = model
            // Provider pin belongs to the previously chosen model.
            $0.modelProviderRouting = nil
        }
    }

    // MARK: - Chat listings

    func privateChats(ownedBy owner: String? = nil) -> [(chatID: Int, threadID: Int64)] {
        contexts.keys
            .filter { $0.chatID > 0 }
            .filter { owner == nil || chatOwnership[$0.chatID] == owner }
            .map { (chatID: $0.chatID, threadID: $0.threadID) }
    }

    func groupChats(ownedBy owner: String? = nil) -> [(chatID: Int, threadID: Int64)] {
        contexts.keys
            .filter { $0.chatID < 0 }
            .filter { owner == nil || chatOwnership[$0.chatID] == owner }
            .map { (chatID: $0.chatID, threadID: $0.threadID) }
    }

    func chatsWithBackupNotify() -> [ChatKey] {
        contexts.filter { $0.value.backupNotify }.map(\.key)
    }

    func chatsUsing(model: String) -> [ChatKey] {
        contexts.filter { $0.value.model == model }.map(\.key)
    }

    func allTrackedModelIDs() -> Set<String> {
        var ids = Set<String>()
        for tenant in tenants.values {
            ids.insert(tenant.defaultModel)
            tenant.modelPresets.forEach { ids.insert($0.value) }
        }
        for ctx in contexts.values {
            ids.insert(ctx.model)
            ctx.chatModelPresets.forEach { ids.insert($0.value) }
        }
        return ids
    }

    func history(chatKey: ChatKey) -> [ChatMessage] {
        ensure(chatKey: chatKey).history
    }

    func resetChat(chatKey: ChatKey) {
        let tenant = tenantState(for: chatKey.chatID)
        let role = roleWithCompanyMembers(chatID: chatKey.chatID, role: tenant.defaultRole + formatOptions)
        contexts[chatKey] = ChatContext(
            role: role,
            history: [.init(role: "system", content: role)],
            pendingTurns: [],
            model: tenant.defaultModel,
            modelProviderRouting: nil,
            temp: 1.5,
            showStats: false,
            maxHistory: tenant.defaultHistoryLength,
            showCost: true,
            showModel: true,
            provider: .openrouter,
            suffix: defaultSuffix,
            reasoningEffort: nil,
            backupNotify: false,
            cumulativeUsage: .zero,
            chatModelPresets: [],
            chatTempPresets: [],
            chatHistoryLengthPresets: [],
            chatRolePresets: []
        )
    }

    // MARK: - Snapshot export / restore

    func exportSnapshot(telegramUpdateOffset: Int) -> BotStateSnapshot {
        var ctxSnapshots: [String: ChatContextSnapshot] = [:]
        for (chatKey, context) in contexts {
            ctxSnapshots[chatKey.snapshotKey] = ChatContextSnapshot(
                role: context.role,
                history: context.history,
                model: context.model,
                modelProvider: context.modelProviderRouting,
                temp: context.temp,
                showStats: context.showStats,
                maxHistory: context.maxHistory,
                showCost: context.showCost,
                showModel: context.showModel,
                provider: context.provider,
                suffix: context.suffix,
                reasoningEffort: context.reasoningEffort,
                backupNotify: context.backupNotify,
                cumulativeUsage: context.cumulativeUsage,
                chatModelPresets: context.chatModelPresets.isEmpty ? nil : context.chatModelPresets,
                chatTempPresets: context.chatTempPresets.isEmpty ? nil : context.chatTempPresets,
                chatHistoryLengthPresets: context.chatHistoryLengthPresets.isEmpty ? nil : context.chatHistoryLengthPresets,
                chatRolePresets: context.chatRolePresets.isEmpty ? nil : context.chatRolePresets
            )
        }

        var tenantSnapshots: [String: TenantStateSnapshot] = [:]
        for (owner, tenant) in tenants {
            tenantSnapshots[owner] = TenantStateSnapshot(
                ownerUsername: tenant.ownerUsername,
                defaultModel: tenant.defaultModel,
                defaultRole: tenant.defaultRole,
                defaultHistoryLength: tenant.defaultHistoryLength,
                modelPresets: tenant.modelPresets,
                tempPresets: tenant.tempPresets,
                historyLengthPresets: tenant.historyLengthPresets,
                rolePresets: tenant.rolePresets,
                whitelistedUserIDs: Array(tenant.whitelistedUserIDs),
                adminUsernames: Array(tenant.adminUsernames),
                licensedUsernames: Array(tenant.licensedUsernames),
                cumulativeUsage: tenant.cumulativeUsage
            )
        }

        var ownershipStrings: [String: String] = [:]
        for (chatID, owner) in chatOwnership {
            ownershipStrings[String(chatID)] = owner
        }

        let extraSupers = superAdminUsernames.subtracting([rootSuperAdminUsername])

        return BotStateSnapshot(
            contexts: ctxSnapshots,
            tenants: tenantSnapshots,
            chatOwnership: ownershipStrings,
            telegramUpdateOffset: telegramUpdateOffset,
            starsPrice: _starsPrice,
            freeModelIDs: _freeModelIDs.isEmpty ? nil : _freeModelIDs,
            crypto: cryptoConfigSnapshot(),
            superAdminUsernames: extraSupers.isEmpty ? nil : Array(extraSupers).sorted()
        )
    }

    func restoreFromSnapshot(_ snapshot: BotStateSnapshot) {
        contexts.removeAll()
        for (key, ctxSnapshot) in snapshot.contexts {
            guard let chatKey = ChatKey(snapshotKey: key) else { continue }
            contexts[chatKey] = ChatContext(
                role: ctxSnapshot.role,
                history: ctxSnapshot.history,
                pendingTurns: [],
                model: ctxSnapshot.model,
                modelProviderRouting: ctxSnapshot.modelProvider,
                temp: ctxSnapshot.temp,
                showStats: ctxSnapshot.showStats,
                maxHistory: ctxSnapshot.maxHistory,
                showCost: ctxSnapshot.showCost,
                showModel: ctxSnapshot.showModel,
                provider: ctxSnapshot.provider,
                suffix: ctxSnapshot.suffix,
                reasoningEffort: ctxSnapshot.reasoningEffort,
                backupNotify: ctxSnapshot.backupNotify,
                cumulativeUsage: ctxSnapshot.cumulativeUsage ?? .zero,
                chatModelPresets: ctxSnapshot.chatModelPresets ?? [],
                chatTempPresets: ctxSnapshot.chatTempPresets ?? [],
                chatHistoryLengthPresets: ctxSnapshot.chatHistoryLengthPresets ?? [],
                chatRolePresets: ctxSnapshot.chatRolePresets ?? []
            )
        }

        chatOwnership.removeAll()
        for (chatIDStr, owner) in snapshot.chatOwnership ?? [:] {
            if let chatID = Int(chatIDStr) {
                chatOwnership[chatID] = owner.lowercased()
            }
        }

        tenants.removeAll()
        if let tenantsSnapshot = snapshot.tenants, !tenantsSnapshot.isEmpty {
            for (owner, ts) in tenantsSnapshot {
                tenants[owner] = TenantState(
                    ownerUsername: ts.ownerUsername,
                    defaultModel: ts.defaultModel,
                    defaultRole: ts.defaultRole,
                    defaultHistoryLength: ts.defaultHistoryLength,
                    modelPresets: ts.modelPresets,
                    tempPresets: ts.tempPresets,
                    historyLengthPresets: ts.historyLengthPresets,
                    rolePresets: ts.rolePresets,
                    whitelistedUserIDs: Set(ts.whitelistedUserIDs),
                    adminUsernames: Set(ts.adminUsernames),
                    licensedUsernames: Set((ts.licensedUsernames ?? []).map { $0.lowercased() }),
                    cumulativeUsage: ts.cumulativeUsage ?? .zero
                )
            }
        } else {
            // Migrate from pre-tenant snapshot format
            tenants[defaultOwnerUsername] = TenantState(
                ownerUsername: defaultOwnerUsername,
                defaultModel: snapshot.defaultModel ?? initialDefaultModel,
                defaultRole: snapshot.defaultRole ?? initialDefaultRole,
                defaultHistoryLength: snapshot.defaultHistoryLength ?? initialDefaultHistoryLength,
                modelPresets: snapshot.modelPresets ?? [],
                tempPresets: snapshot.tempPresets ?? [],
                historyLengthPresets: snapshot.historyLengthPresets ?? [],
                rolePresets: snapshot.rolePresets ?? [],
                whitelistedUserIDs: Set(snapshot.whitelistedUserIDs ?? []),
                adminUsernames: Set(
                    (snapshot.adminUsernames ?? [])
                        .map { $0.lowercased() }
                        .filter { $0 != defaultOwnerUsername }
                ),
                licensedUsernames: [],
                cumulativeUsage: .zero
            )
        }

        // Ensure default owner tenant always exists
        if tenants[defaultOwnerUsername] == nil {
            tenants[defaultOwnerUsername] = TenantState(
                ownerUsername: defaultOwnerUsername,
                defaultModel: initialDefaultModel,
                defaultRole: initialDefaultRole,
                defaultHistoryLength: initialDefaultHistoryLength,
                modelPresets: [],
                tempPresets: [],
                historyLengthPresets: [],
                rolePresets: [],
                whitelistedUserIDs: [],
                adminUsernames: [],
                licensedUsernames: [],
                cumulativeUsage: .zero
            )
        }

        superAdminUsernames = [rootSuperAdminUsername]
        for u in snapshot.superAdminUsernames ?? [] {
            let lc = u.lowercased()
            if !lc.isEmpty { superAdminUsernames.insert(lc) }
        }

        // Rebuild reverse userID → tenant mapping from whitelist data
        userTenantMap.removeAll()
        for (owner, tenant) in tenants {
            for userID in tenant.whitelistedUserIDs {
                userTenantMap[userID] = owner
            }
        }

        _starsPrice = snapshot.starsPrice
        _freeModelIDs = snapshot.freeModelIDs ?? []
        restoreCryptoConfig(snapshot.crypto)
    }
}
