import XCTest
@testable import LLM_chat_bot

/// Presets («заготовки»): the one piece of state a plain user can grow, and the
/// one addressed from a keyboard that may describe an older list than the one
/// the tap lands in.
final class StorePresetTests: XCTestCase {

    private let group = ChatKey(chatID: -4_100, threadID: 0)

    private func fill(_ store: ChatContextStore, count: Int) async {
        for i in 0..<count {
            _ = await store.addPreset(
                category: .model,
                display: "M\(i)",
                value: "vendor/model-\(i)",
                chatID: group.chatID
            )
        }
    }

    // MARK: - Bounds

    /// A list that grows without a ceiling is a page that stops being sendable
    /// and a `jsonb` row that keeps getting bigger. The refusal has to be
    /// visible, or the value somebody typed disappears without a word.
    func testAGlobalPresetListStopsAtItsCeiling() async {
        let store = Fixtures.makeStore()
        await fill(store, count: PresetList.maxCount)

        let outcome = await store.addPreset(
            category: .model,
            display: "one more",
            value: "vendor/extra",
            chatID: group.chatID
        )

        XCTAssertEqual(outcome, .full)
        let presets = await store.modelPresets(chatID: group.chatID)
        XCTAssertEqual(presets.count, PresetList.maxCount)
        XCTAssertFalse(presets.contains { $0.value == "vendor/extra" })
    }

    /// Anyone in a group may add per-chat presets, so this list is bounded for
    /// the same reason and by the same number.
    func testAChatPresetListStopsAtItsCeiling() async {
        let store = Fixtures.makeStore()
        for i in 0..<PresetList.maxCount {
            _ = await store.addChatPreset(category: .role, chatKey: group, display: "R\(i)", value: "role \(i)")
        }

        let outcome = await store.addChatPreset(category: .role, chatKey: group, display: "R+", value: "role extra")

        XCTAssertEqual(outcome, .full)
        let presets = await store.chatPresets(category: .role, chatKey: group)
        XCTAssertEqual(presets.count, PresetList.maxCount)
    }

    func testOversizedPresetTextIsClampedByTheDomain() async {
        let store = Fixtures.makeStore()
        let outcome = await store.addPreset(
            category: .role,
            display: String(repeating: "и", count: 500),
            value: String(repeating: "я", count: 5_000),
            chatID: group.chatID
        )

        guard case .added(let preset) = outcome else { return XCTFail("expected the preset to be stored") }
        XCTAssertEqual(preset.display.count, Preset.maxDisplayLength)
        XCTAssertEqual(preset.value.count, Preset.maxValueLength)
    }

    func testAPresetWithNothingInItIsNotStored() async {
        let store = Fixtures.makeStore()
        let outcome = await store.addPreset(category: .temp, display: "   ", value: "0.3", chatID: group.chatID)

        XCTAssertEqual(outcome, .full, "nothing was stored, so there is nothing to report as added")
        let presets = await store.tempPresets(chatID: group.chatID)
        XCTAssertTrue(presets.isEmpty)
    }

    // MARK: - Identity

    /// The regression: a keyboard drawn before somebody else edited the list
    /// still names the preset it showed. Addressed by position, «❌» next to the
    /// third preset deletes whatever slid into that slot.
    func testDeletingAPresetFromAStaleKeyboardHitsTheNamedOne() async {
        let store = Fixtures.makeStore()
        await fill(store, count: 3)
        let drawn = await store.modelPresets(chatID: group.chatID)
        let doomed = drawn[2]

        // Another admin removes the first one while this page is open.
        let removedFirst = await store.removePreset(category: .model, id: drawn[0].id, chatID: group.chatID)
        XCTAssertTrue(removedFirst)

        let removedDoomed = await store.removePreset(category: .model, id: doomed.id, chatID: group.chatID)
        XCTAssertTrue(removedDoomed)
        let left = await store.modelPresets(chatID: group.chatID)
        XCTAssertEqual(left.map(\.value), [drawn[1].value], "only the untouched preset is left")
    }

    /// The same for editing, where the damage is silent: the wrong preset is
    /// overwritten and nothing says so.
    func testEditingAPresetFromAStaleKeyboardHitsTheNamedOne() async {
        let store = Fixtures.makeStore()
        await fill(store, count: 3)
        let drawn = await store.modelPresets(chatID: group.chatID)
        let target = drawn[2]

        let removedFirst = await store.removePreset(category: .model, id: drawn[0].id, chatID: group.chatID)
        XCTAssertTrue(removedFirst)
        let edited = await store.editPreset(
            category: .model,
            id: target.id,
            display: "renamed",
            value: "vendor/renamed",
            chatID: group.chatID
        )
        XCTAssertTrue(edited)

        let left = await store.modelPresets(chatID: group.chatID)
        XCTAssertEqual(left.map(\.value), [drawn[1].value, "vendor/renamed"])
        XCTAssertEqual(left.last?.id, target.id, "an edit keeps the id, so the page's other buttons still work")
    }

    func testEditingAPresetThatIsGoneReportsFailureInsteadOfWritingSomewhere() async {
        let store = Fixtures.makeStore()
        await fill(store, count: 2)
        let drawn = await store.modelPresets(chatID: group.chatID)
        let removedFirst = await store.removePreset(category: .model, id: drawn[0].id, chatID: group.chatID)
        XCTAssertTrue(removedFirst)

        let edited = await store.editPreset(
            category: .model,
            id: drawn[0].id,
            display: "ghost",
            value: "vendor/ghost",
            chatID: group.chatID
        )

        XCTAssertFalse(edited)
        let left = await store.modelPresets(chatID: group.chatID)
        XCTAssertEqual(left.map(\.value), [drawn[1].value])
    }

    func testEveryPresetInAListGetsItsOwnID() async {
        let store = Fixtures.makeStore()
        await fill(store, count: PresetList.maxCount)
        let ids = await store.modelPresets(chatID: group.chatID).map(\.id)

        XCTAssertEqual(Set(ids).count, ids.count)
        // An id must never be readable as a position — `presetTarget` still
        // accepts buttons from an older build, which carried one.
        XCTAssertTrue(ids.allSatisfy { Int($0) == nil })
    }

    // MARK: - Stored rows

    /// Rows written before presets had ids still decode, and come back with
    /// ids: the id is what every button in the menu is addressed by.
    func testPresetsStoredWithoutIDsAreGivenThemOnLoad() throws {
        let json = Data("""
        [{"display":"Gemini","value":"google/gemini"},{"display":"DeepSeek","value":"deepseek/chat"}]
        """.utf8)

        let list = try JSONDecoder().decode(PresetList.self, from: json)

        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list.map(\.value), ["google/gemini", "deepseek/chat"])
        XCTAssertTrue(list.allSatisfy { !$0.id.isEmpty })
        XCTAssertEqual(Set(list.map(\.id)).count, 2)
    }

    /// A hand-written row cannot hand the menu two presets that answer to the
    /// same button, nor more presets than a page can carry.
    func testAStoredListIsNormalisedOnLoad() throws {
        let duplicated = (0..<(PresetList.maxCount + 5))
            .map { #"{"id":"same","display":"M\#($0)","value":"vendor/m\#($0)"}"# }
            .joined(separator: ",")
        let list = try JSONDecoder().decode(PresetList.self, from: Data("[\(duplicated)]".utf8))

        XCTAssertEqual(list.count, PresetList.maxCount)
        XCTAssertEqual(Set(list.map(\.id)).count, PresetList.maxCount)
    }

    func testAPresetSurvivesAnEncodeDecodeRoundTrip() throws {
        let original = PresetList([
            Preset(display: "DeepSeek V4", value: "deepseek/deepseek-v4-pro", provider: "deepseek")
        ])
        let restored = try JSONDecoder().decode(PresetList.self, from: JSONEncoder().encode(original))

        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.first?.provider, "deepseek")
    }

    // MARK: - Escaping

    /// A preset name is arbitrary text somebody typed, and in a group anybody
    /// can type it. Left raw it renders as markup inside a message the bot
    /// signs its own name to.
    func testPresetTextIsEscapedBeforeItBecomesMarkup() {
        let preset = Preset(display: #"<a href="http://evil">Поддержка</a>"#, value: "a & b <tag>")

        XCTAssertFalse(preset.escapedDisplay.contains("<"))
        XCTAssertFalse(preset.escapedDisplay.contains(">"))
        XCTAssertEqual(preset.escapedValue, "a &amp; b &lt;tag&gt;")
        XCTAssertEqual(preset.value, "a & b <tag>", "the stored value stays exactly what it is")
    }
}
