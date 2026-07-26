import XCTest
@testable import LLM_chat_bot

/// Ads: the two throttles and the self-promo that fills an empty slot.
final class StoreAdsTests: XCTestCase {

    private func makeCampaign(id: String = "c1", everyN: Int = 2, pause: Int = 0) -> AdCampaign {
        AdCampaign(
            id: id,
            text: "реклама",
            buttonText: nil,
            buttonURL: nil,
            enabled: true,
            everyNReplies: everyN,
            minIntervalSeconds: pause,
            totalImpressionsTarget: nil,
            impressionsUsed: 0,
            startAt: Date().addingTimeInterval(-60),
            endAt: nil,
            createdAt: Date()
        )
    }

    func testCampaignIsShownEveryNthReply() async {
        let store = Fixtures.makeStore()
        var promo = SelfPromoConfig.default
        promo.enabled = false
        await store.setSelfPromoConfig(promo)
        await store.upsertAdCampaign(makeCampaign(everyN: 3))
        let chat = ChatKey(chatID: -1, threadID: 0)

        let shown = await [store.nextAdToShow(chatKey: chat), store.nextAdToShow(chatKey: chat), store.nextAdToShow(chatKey: chat)]
        XCTAssertNil(shown[0])
        XCTAssertNil(shown[1])
        XCTAssertEqual(shown[2]?.id, "c1")
    }

    func testMinimumIntervalHoldsTheSlot() async {
        let store = Fixtures.makeStore()
        var promo = SelfPromoConfig.default
        promo.enabled = false
        await store.setSelfPromoConfig(promo)
        await store.upsertAdCampaign(makeCampaign(everyN: 1, pause: 3600))
        let chat = ChatKey(chatID: -2, threadID: 0)

        let first = await store.nextAdToShow(chatKey: chat)
        let second = await store.nextAdToShow(chatKey: chat)
        XCTAssertNotNil(first)
        XCTAssertNil(second, "the pause between impressions must hold")
    }

    func testDisabledCampaignIsNeverShown() async {
        let store = Fixtures.makeStore()
        var promo = SelfPromoConfig.default
        promo.enabled = false
        await store.setSelfPromoConfig(promo)
        var campaign = makeCampaign(everyN: 1)
        campaign.enabled = false
        await store.upsertAdCampaign(campaign)

        let shown = await store.nextAdToShow(chatKey: ChatKey(chatID: -3, threadID: 0))
        XCTAssertNil(shown)
    }

    func testLeastShownCampaignWinsTheRotation() async {
        let store = Fixtures.makeStore()
        await store.upsertAdCampaign(makeCampaign(id: "a", everyN: 1))
        await store.upsertAdCampaign(makeCampaign(id: "b", everyN: 1))
        let chat = ChatKey(chatID: -4, threadID: 0)

        let first = await store.nextAdToShow(chatKey: chat)
        let second = await store.nextAdToShow(chatKey: chat)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first?.id, second?.id, "rotation must be fair between running campaigns")
    }

    /// With no paid campaign running the built-in offer sells premium itself.
    func testSelfPromoFillsAnEmptySlotAndCountsImpressions() async {
        let store = Fixtures.makeStore()
        var promo = SelfPromoConfig.default
        promo.everyNReplies = 1
        promo.minIntervalSeconds = 0
        await store.setSelfPromoConfig(promo)

        let shown = await store.nextAdToShow(chatKey: ChatKey(chatID: -5, threadID: 0))
        XCTAssertEqual(shown?.text, SelfPromoConfig.defaultText)
        let config = await store.selfPromoConfig()
        XCTAssertEqual(config.impressions, 1)
    }

    /// A running paid campaign owns the slot even on a turn its throttle skips.
    func testPaidCampaignIsNotUndercutByTheSelfPromo() async {
        let store = Fixtures.makeStore()
        var promo = SelfPromoConfig.default
        promo.everyNReplies = 1
        promo.minIntervalSeconds = 0
        await store.setSelfPromoConfig(promo)
        await store.upsertAdCampaign(makeCampaign(everyN: 10))

        let shown = await store.nextAdToShow(chatKey: ChatKey(chatID: -6, threadID: 0))
        XCTAssertNil(shown)
    }

    func testSelfPromoStatsCanBeReset() async {
        let store = Fixtures.makeStore()
        var promo = SelfPromoConfig.default
        promo.everyNReplies = 1
        await store.setSelfPromoConfig(promo)
        _ = await store.nextAdToShow(chatKey: ChatKey(chatID: -7, threadID: 0))
        await store.resetSelfPromoStats()
        let config = await store.selfPromoConfig()
        XCTAssertEqual(config.impressions, 0)
    }

    func testConfigIsNormalizedOnSet() async {
        let store = Fixtures.makeStore()
        var wild = SelfPromoConfig.default
        wild.everyNReplies = 9_000
        wild.text = String(repeating: "x", count: 2_000)
        await store.setSelfPromoConfig(wild)

        let stored = await store.selfPromoConfig()
        XCTAssertEqual(stored.everyNReplies, SelfPromoConfig.repliesRange.upperBound)
        XCTAssertLessThanOrEqual(stored.text.count, SelfPromoConfig.maxTextLength + 1)
    }
}

/// The free-model catalogue decides who pays for a turn, so "unknown" has to
/// mean "paid" — never "free for everyone".
final class StoreFreeModelTests: XCTestCase {

    func testUnknownCatalogueTreatsEverythingAsPaid() async {
        let store = Fixtures.makeStore()
        let effective = await store.effectiveFreeModelIDs()
        XCTAssertNil(effective, "no pins and no catalogue yet")
        // `isFreeModel` answers optimistically only because the gate above it
        // treats a nil set as "charge for it".
        let firstFree = await store.firstFreeModel()
        XCTAssertNil(firstFree)
    }

    func testPinnedAndCatalogueModelsAreUnioned() async {
        let store = Fixtures.makeStore()
        await store.setFreeModelIDs(["pinned/one"])
        await store.updateOpenRouterFreeModelIDs(["vendor/free"])

        let effective = await store.effectiveFreeModelIDs()
        XCTAssertEqual(effective, ["pinned/one", "vendor/free"])
        let isFree = await store.isFreeModel("vendor/free")
        XCTAssertTrue(isFree)
        let isPaid = await store.isFreeModel("vendor/paid")
        XCTAssertFalse(isPaid)
    }

    /// `Set.first` is arbitrary: the fallback model must not change between
    /// runs, or answer quality swings for no visible reason.
    func testFallbackModelIsDeterministic() async {
        let store = Fixtures.makeStore()
        await store.updateOpenRouterFreeModelIDs(["z/model", "a/model", "m/model"])
        let first = await store.firstFreeModel()
        XCTAssertEqual(first, "a/model")

        await store.setFreeModelIDs(["chosen/backup"])
        let pinned = await store.firstFreeModel()
        XCTAssertEqual(pinned, "chosen/backup", "a super-admin pin wins over the catalogue")
    }

    func testBlankPinsAreIgnored() async {
        let store = Fixtures.makeStore()
        await store.setFreeModelIDs(["  ", "real/model"])
        let ids = await store.freeModelIDs()
        XCTAssertEqual(ids, ["real/model"])
        let added = await store.addFreeModel("real/model")
        XCTAssertFalse(added, "duplicates are refused")
    }
}

/// Onboarding examples: the buttons in the greeting, all super-admin editable.
final class StoreOnboardingTests: XCTestCase {

    /// Personal and shared chats ask for different things, so the default set
    /// is split by room — but every room gets something.
    func testDefaultsAreSplitByRoom() async {
        let store = Fixtures.makeStore()
        let config = await store.onboardingConfig()
        XCTAssertTrue(config.enabled)
        XCTAssertFalse(config.examples.isEmpty)

        let inPrivate = config.activeExamples(inGroup: false)
        let inGroup = config.activeExamples(inGroup: true)
        XCTAssertFalse(inPrivate.isEmpty)
        XCTAssertFalse(inGroup.isEmpty)
        XCTAssertTrue(inPrivate.allSatisfy { $0.placement != .groupsOnly })
        XCTAssertTrue(inGroup.allSatisfy { $0.placement != .privateOnly })
    }

    func testAddEditAndTapKeepTheSameID() async {
        let store = Fixtures.makeStore()
        await store.resetOnboardingExamplesToDefaults()
        guard let added = await store.addOnboardingExample(label: "Тест", prompt: "Расскажи анекдот") else {
            return XCTFail("example not added")
        }
        _ = await store.recordOnboardingTap(id: added.id)
        _ = await store.updateOnboardingExample(id: added.id, label: "Тест 2", prompt: "Другой запрос")

        let stored = await store.onboardingConfig().example(id: added.id)
        XCTAssertEqual(stored?.label, "Тест 2")
        XCTAssertEqual(stored?.taps, 1, "editing the text must not reset the counter")
    }

    func testPlacementCyclesAndFiltersTheRoom() async {
        let store = Fixtures.makeStore()
        await store.resetOnboardingExamplesToDefaults()
        guard let example = await store.onboardingConfig().examples.first else {
            return XCTFail("no default examples")
        }
        let next = await store.cycleOnboardingExamplePlacement(id: example.id)
        XCTAssertEqual(next, example.placement.next)

        var config = await store.onboardingConfig()
        let shownInGroup = config.activeExamples(inGroup: true).contains { $0.id == example.id }
        let shownInPrivate = config.activeExamples(inGroup: false).contains { $0.id == example.id }
        XCTAssertEqual(shownInGroup, next?.matches(isGroup: true))
        XCTAssertEqual(shownInPrivate, next?.matches(isGroup: false))

        // Three taps of the button bring it back to where it started.
        _ = await store.cycleOnboardingExamplePlacement(id: example.id)
        _ = await store.cycleOnboardingExamplePlacement(id: example.id)
        config = await store.onboardingConfig()
        XCTAssertEqual(config.example(id: example.id)?.placement, example.placement)
    }

    func testDisabledExampleDisappearsFromBothRooms() async {
        let store = Fixtures.makeStore()
        await store.resetOnboardingExamplesToDefaults()
        guard let example = await store.onboardingConfig().examples.first else {
            return XCTFail("no default examples")
        }
        let enabled = await store.toggleOnboardingExample(id: example.id)
        XCTAssertEqual(enabled, false)

        let config = await store.onboardingConfig()
        XCTAssertFalse(config.activeExamples(inGroup: false).contains { $0.id == example.id })
        XCTAssertFalse(config.activeExamples(inGroup: true).contains { $0.id == example.id })
    }

    func testExampleCountIsCapped() async {
        let store = Fixtures.makeStore()
        await store.setOnboardingConfig(OnboardingConfig(enabled: true, showInGroups: true, examples: []))
        for index in 0..<(OnboardingConfig.maxExamples + 3) {
            _ = await store.addOnboardingExample(label: "L\(index)", prompt: "P\(index)")
        }
        let config = await store.onboardingConfig()
        XCTAssertEqual(config.examples.count, OnboardingConfig.maxExamples)
    }

    func testTapStatsCanBeResetWithoutLosingExamples() async {
        let store = Fixtures.makeStore()
        await store.resetOnboardingExamplesToDefaults()
        guard let example = await store.onboardingConfig().examples.first else {
            return XCTFail("no default examples")
        }
        _ = await store.recordOnboardingTap(id: example.id)
        await store.resetOnboardingTapStats()

        let config = await store.onboardingConfig()
        XCTAssertFalse(config.examples.isEmpty)
        XCTAssertEqual(config.examples.reduce(0) { $0 + $1.taps }, 0)
    }

    /// A build that does not know a placement value must not drop the whole
    /// config — and with it every text and counter.
    func testUnknownPlacementDecodesAsEverywhere() throws {
        let json = """
        {"id":"x1","label":"L","prompt":"P","enabled":true,"placement":"future_value","taps":3}
        """.data(using: .utf8)!
        let example = try JSONDecoder().decode(OnboardingExample.self, from: json)
        XCTAssertEqual(example.placement, .everywhere)
        XCTAssertEqual(example.taps, 3)
    }
}
