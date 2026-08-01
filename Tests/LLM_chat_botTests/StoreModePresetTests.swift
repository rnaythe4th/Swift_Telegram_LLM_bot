import XCTest
@testable import LLM_chat_bot

/// Reference modes decide two things that cost money: which models a free
/// chat may run, and what a paying one gets that a free one does not.
final class StoreModePresetTests: XCTestCase {

    private func freeMode(id: String = "free", model: String? = "cheap/model") -> ModePreset {
        ModePreset(id: id, title: "⚡ Быстрый", subtitle: "быстро", model: model,
                   temp: 1.0, maxHistory: 20, tier: .free)
    }

    private func paidMode(id: String = "smart") -> ModePreset {
        ModePreset(id: id, title: "🧠 Умный", subtitle: "умно", model: "expensive/model",
                   temp: 0.5, maxHistory: 30, reasoning: .high, tier: .premium)
    }

    private func makeStore(modes: [ModePreset], defaultID: String?) async -> ChatContextStore {
        let store = Fixtures.makeStore()
        await store.setModeConfig(ModePresetConfig(enabled: true, modes: modes, defaultModeID: defaultID))
        return store
    }

    // MARK: - What the free tier may run

    /// The whole point of a 🆓 mode: whatever the owner put behind it is
    /// allowed without a subscription, even when the model itself is paid.
    func testFreeModeModelIsAllowedWithoutAccess() async {
        let store = await makeStore(modes: [freeMode(), paidMode()], defaultID: "free")
        await store.updateOpenRouterFreeModelIDs(["vendor/zero"])

        let allowed = await store.allowedFreeModelIDs()
        XCTAssertEqual(allowed?.contains("cheap/model"), true, "the 🆓 mode's model is free to use")
        XCTAssertEqual(allowed?.contains("vendor/zero"), true, "zero-cost models stay allowed")
        XCTAssertEqual(allowed?.contains("expensive/model"), false, "a ⭐ mode grants nothing")
    }

    /// An unknown catalogue must not turn into "everything is free" — that is
    /// the failure mode that spends the owner's money silently.
    func testUnknownCatalogueStaysUnknownWithoutFreeModes() async {
        let store = await makeStore(modes: [paidMode()], defaultID: nil)
        let allowed = await store.allowedFreeModelIDs()
        XCTAssertNil(allowed, "no zero-cost catalogue and no 🆓 mode = assume paid")
    }

    /// The fallback a capped chat lands on is the owner's choice, not whatever
    /// `Set.first` returns today.
    func testFallbackPrefersTheWorkingFreeMode() async {
        let store = await makeStore(modes: [paidMode(), freeMode(model: "owner/pick")], defaultID: "free")
        await store.setFreeModelIDs(["pinned/one"])
        await store.updateOpenRouterFreeModelIDs(["a/zero"])

        let fallback = await store.fallbackFreeModel()
        XCTAssertEqual(fallback, "owner/pick")
    }

    /// A 🆓 mode set to "auto" resolves through the catalogue instead of
    /// pinning a model that may stop being free.
    func testAutoModelResolvesToFallback() async {
        let store = await makeStore(modes: [freeMode(model: nil)], defaultID: "free")
        await store.setFreeModelIDs(["pinned/backup"])

        let mode = await store.mode(id: "free")!
        let resolved = await store.resolveModeModel(mode)
        XCTAssertEqual(resolved, "pinned/backup")
    }

    // MARK: - Applying a mode

    func testApplyingAModeWritesTheWholeBundle() async {
        let store = await makeStore(modes: [paidMode()], defaultID: nil)
        let key = ChatKey(chatID: 42, threadID: 0)

        let applied = await store.applyMode(chatKey: key, modeID: "smart")
        XCTAssertNotNil(applied)

        let help = await store.fetchHelp(chatKey: key)
        XCTAssertEqual(help.model, "expensive/model")
        XCTAssertEqual(help.temp, 0.5)
        XCTAssertEqual(help.maxHistory, 30)
        XCTAssertEqual(help.reasoningEffort, .high)
        let active = await store.activeMode(chatKey: key)
        XCTAssertEqual(active?.id, "smart")
    }

    /// A mode whose model cannot be resolved must fail whole rather than write
    /// half of itself: a chat left with the new temperature and the old model
    /// is neither the mode the user picked nor the one they had.
    func testUnresolvableModeAppliesNothing() async {
        let store = await makeStore(modes: [freeMode(model: nil)], defaultID: "free")
        let key = ChatKey(chatID: 7, threadID: 0)
        let before = await store.fetchHelp(chatKey: key)

        let applied = await store.applyMode(chatKey: key, modeID: "free")
        XCTAssertNil(applied, "no free model anywhere, so the mode has nothing to run on")

        let after = await store.fetchHelp(chatKey: key)
        XCTAssertEqual(after.model, before.model)
        XCTAssertEqual(after.maxHistory, before.maxHistory)
    }

    /// Hand-editing a setting the mode owns means the chat is no longer in it —
    /// otherwise the page keeps claiming a mode the settings no longer match.
    func testManualEditDropsTheActiveMode() async {
        let store = await makeStore(modes: [paidMode()], defaultID: nil)
        let key = ChatKey(chatID: 42, threadID: 0)
        await store.applyMode(chatKey: key, modeID: "smart")

        await store.setTemperature(chatKey: key, value: 1.9)
        let active = await store.activeMode(chatKey: key)
        XCTAssertNil(active)
    }

    /// Re-picking the mode a chat is already in must not cost it the
    /// conversation: the model has not changed, so there is nothing to reset.
    func testRepickingTheSameModeKeepsHistory() async {
        let store = await makeStore(modes: [paidMode()], defaultID: nil)
        let key = ChatKey(chatID: 42, threadID: 0)
        await store.applyMode(chatKey: key, modeID: "smart")
        let generation = GenerationID()
        _ = await store.snapshotAndAppend(
            chatKey: key,
            generationID: generation,
            content: UserInputContent(text: "привет"),
            username: nil
        )
        _ = await store.appendAssistant(chatKey: key, generationID: generation, content: "ответ")

        let before = await store.history(chatKey: key).count
        XCTAssertEqual(before, 3)
        await store.applyMode(chatKey: key, modeID: "smart")
        let after = await store.history(chatKey: key).count
        XCTAssertEqual(after, before)
    }

    // MARK: - Editing the set

    /// Editing the wording of a mode must not reset what it has earned: the tap
    /// counter is the only signal for whether the list is right.
    func testEditingAModeKeepsItsTapCount() async {
        let store = await makeStore(modes: [paidMode()], defaultID: nil)
        await store.noteModeTap(id: "smart")
        await store.noteModeTap(id: "smart")

        var edited = await store.mode(id: "smart")!
        edited.title = "🧠 Умнейший"
        await store.upsertMode(edited)

        let stored = await store.mode(id: "smart")
        XCTAssertEqual(stored?.title, "🧠 Умнейший")
        XCTAssertEqual(stored?.taps, 2)
    }

    func testRemovingTheWorkingModeClearsTheDefault() async {
        let store = await makeStore(modes: [freeMode(), paidMode()], defaultID: "free")
        await store.removeMode(id: "free")

        let config = await store.modeConfig()
        XCTAssertNil(config.defaultModeID)
        // Something still has to be the working mode, or "↺ Рабочий режим"
        // would have nowhere to go.
        XCTAssertEqual(config.defaultMode?.id, "smart")
    }

    func testNormalizationClampsOutOfRangeValues() async {
        let wild = ModePreset(id: "x", title: "T", subtitle: "S", model: "  m/1  ",
                              temp: 9.0, maxHistory: 900, tier: .free)
        let config = ModePresetConfig(enabled: true, modes: [wild], defaultModeID: "x").normalized
        XCTAssertEqual(config.modes.first?.temp, ModePresetConfig.tempRange.upperBound)
        XCTAssertEqual(config.modes.first?.maxHistory, ModePresetConfig.historyRange.upperBound)
        XCTAssertEqual(config.modes.first?.model, "m/1")
    }

    /// A tier written by a newer build must read as `premium`. Guessing `free`
    /// here would hand the owner's most expensive model to everyone for as long
    /// as the row is misread.
    func testUnknownTierDecodesAsPremium() throws {
        let json = """
        {"id":"x","title":"T","subtitle":"S","temp":1.0,"maxHistory":20,"tier":"enterprise"}
        """.data(using: .utf8)!
        let mode = try JSONDecoder().decode(ModePreset.self, from: json)
        XCTAssertEqual(mode.tier, .premium)
    }

    /// One unreadable field must not take the whole set down with it — the
    /// alternative is a bot that silently forgets every mode it had.
    func testMissingOptionalFieldsStillDecode() throws {
        let json = """
        {"enabled":true,"modes":[{"id":"a","title":"A"}]}
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(ModePresetConfig.self, from: json)
        XCTAssertEqual(config.modes.count, 1)
        XCTAssertEqual(config.modes.first?.maxHistory, 20)
        XCTAssertEqual(config.modes.first?.tier, .premium)
    }

    // MARK: - Persistence

    func testModeConfigSurvivesAFlushAndRestore() async {
        let store = await makeStore(modes: [freeMode(), paidMode()], defaultID: "free")
        let batch = await store.drainDirtyBatch()
        guard batch.configs.contains(where: { $0.name == .modes }) else {
            return XCTFail("mode config was not queued for persistence")
        }
        let saved = await store.modeConfig()

        let fresh = Fixtures.makeStore()
        var configs = ConfigDocuments()
        configs.set(Config.modes, saved)
        await fresh.restore(from: PersistedBotState(configs: configs))

        let restored = await fresh.modeConfig()
        XCTAssertEqual(restored.modes.map(\.id), ["free", "smart"])
        XCTAssertEqual(restored.defaultModeID, "free")
    }
}
