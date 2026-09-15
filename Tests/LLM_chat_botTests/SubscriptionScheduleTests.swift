import XCTest
@testable import LLM_chat_bot

/// `dueNotice` is the whole reminder/winback cadence as a pure decision: which
/// wave is owed right now, given what already went out this cycle.
final class SubscriptionScheduleTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private var config: SubscriptionReminderConfig { .default }

    private func notice(
        endsIn days: Double,
        sent: Set<String> = [],
        config: SubscriptionReminderConfig? = nil
    ) -> SubscriptionNotice? {
        (config ?? self.config).dueNotice(
            paidUntil: now.addingTimeInterval(Fixtures.days(days)),
            alreadySent: sent,
            now: now
        )
    }

    func testNothingIsDueLongBeforeExpiry() {
        XCTAssertNil(notice(endsIn: 10))
    }

    func testWidestWaveFiresFirst() {
        XCTAssertEqual(notice(endsIn: 2.5), .expiring(daysBefore: 3))
    }

    /// "Завтра" beats "за три дня": the nearest reached wave wins, so a missed
    /// wave is skipped rather than sent late.
    func testNearestWaveWinsOverWiderOne() {
        XCTAssertEqual(notice(endsIn: 0.5), .expiring(daysBefore: 1))
    }

    func testAWaveIsNotRepeatedInTheSameCycle() {
        XCTAssertNil(notice(endsIn: 0.5, sent: ["expiring1"]))
    }

    /// A cycle reminded by the old single-wave build carries the legacy key;
    /// upgrading must not resend the widest wave to it.
    func testLegacyKeyCountsAsTheWidestWaveHavingBeenSent() {
        XCTAssertNil(notice(endsIn: 2.5, sent: [SubscriptionNotice.legacyExpiringKey]))
        // Narrower waves still fire — they never went out.
        XCTAssertEqual(
            notice(endsIn: 0.5, sent: [SubscriptionNotice.legacyExpiringKey]),
            .expiring(daysBefore: 1)
        )
    }

    func testWinbackWavesFireAfterExpiry() {
        XCTAssertEqual(notice(endsIn: -1.2), .winback(dayOffset: 1))
        XCTAssertEqual(notice(endsIn: -7.5), .winback(dayOffset: 7))
    }

    /// Downtime must not replay an old wave: past its catch-up window a wave is
    /// gone for good.
    func testWinbackWaveExpiresWithItsCatchUpWindow() {
        XCTAssertNil(notice(endsIn: -5))       // between wave 1 (window closed) and wave 7
        XCTAssertNil(notice(endsIn: -60))      // long gone
    }

    func testDisabledScheduleSendsNothing() {
        var off = config
        off.enabled = false
        XCTAssertNil(notice(endsIn: 0.5, config: off))
        XCTAssertNil(notice(endsIn: -1.2, config: off))
    }

    func testEmptyExpiryWavesMeanNoPreExpiryReminder() {
        var noWaves = config
        noWaves.expiryReminderDays = []
        XCTAssertNil(notice(endsIn: 0.1, config: noWaves))
        XCTAssertEqual(noWaves.daysBeforeExpiry, 0)
    }

    func testNoticeKeysAreStableAndDistinct() {
        XCTAssertEqual(SubscriptionNotice.expiring(daysBefore: 3).key, "expiring3")
        XCTAssertEqual(SubscriptionNotice.winback(dayOffset: 7).key, "winback7")
        XCTAssertTrue(SubscriptionNotice.winback(dayOffset: 1).isWinback)
        XCTAssertFalse(SubscriptionNotice.expiring(daysBefore: 1).isWinback)
    }
}

final class SubscriptionReminderConfigTests: XCTestCase {

    func testNormalizationClampsEverythingOutOfRange() {
        let wild = SubscriptionReminderConfig(
            enabled: true,
            expiryReminderDays: [0, 3, 3, 99, 1, 2, 5],
            winbackDays: [0, 1, 400, 7],
            winbackDiscountPercent: 500,
            winbackOfferHours: 0,
            sweepIntervalMinutes: 1,
            notifyChats: true,
            walletWinbackDays: 9_000
        ).normalized

        XCTAssertEqual(wild.expiryReminderDays.count, SubscriptionReminderConfig.maxExpiryWaves)
        XCTAssertEqual(wild.expiryReminderDays, [5, 3, 2])   // widest first, deduplicated
        XCTAssertEqual(wild.winbackDays, [1, 7])
        XCTAssertEqual(wild.winbackDiscountPercent, SubscriptionReminderConfig.discountRange.upperBound)
        XCTAssertEqual(wild.winbackOfferHours, SubscriptionReminderConfig.offerHoursRange.lowerBound)
        XCTAssertEqual(wild.sweepIntervalMinutes, SubscriptionReminderConfig.sweepIntervalRange.lowerBound)
        XCTAssertEqual(wild.walletWinbackDays, SubscriptionReminderConfig.walletWinbackRange.upperBound)
    }

    func testDecodingAppliesNormalization() throws {
        let json = """
        {"enabled":true,"expiryReminderDays":[3,1,99],"winbackDays":[1],"winbackDiscountPercent":30,
         "winbackOfferHours":48,"sweepIntervalMinutes":60,"notifyChats":true,"walletWinbackDays":7}
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(SubscriptionReminderConfig.self, from: json)
        XCTAssertEqual(config.expiryReminderDays, [3, 1])
    }

    /// A row written by the single-wave build still decodes into a working
    /// schedule instead of resetting to the defaults.
    func testLegacySingleValueRowBecomesOneWave() throws {
        let json = #"{"enabled":true,"daysBeforeExpiry":5,"winbackDays":[2]}"#.data(using: .utf8)!
        let config = try JSONDecoder().decode(SubscriptionReminderConfig.self, from: json)
        XCTAssertEqual(config.expiryReminderDays, [5])
        XCTAssertEqual(config.winbackDays, [2])
        XCTAssertEqual(config.walletWinbackDays, SubscriptionReminderConfig.default.walletWinbackDays)
    }

    /// Rolling the binary back must not wipe the schedule, so the legacy field
    /// is written alongside the list.
    func testEncodingKeepsTheLegacyField() throws {
        let data = try JSONEncoder().encode(SubscriptionReminderConfig.default)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(object["daysBeforeExpiry"] as? Int, 3)
    }

    func testMissingFieldsFallBackToDefaults() throws {
        let config = try JSONDecoder().decode(SubscriptionReminderConfig.self, from: "{}".data(using: .utf8)!)
        XCTAssertEqual(config, SubscriptionReminderConfig.default)
    }
}

final class SubscriptionDiscountTests: XCTestCase {

    func testActiveOnlyWhileItLasts() {
        let now = Date()
        let live = SubscriptionDiscount(percent: 30, expiresAt: now.addingTimeInterval(3600))
        XCTAssertTrue(live.isActive(now: now))

        let dead = SubscriptionDiscount(percent: 30, expiresAt: now.addingTimeInterval(-1))
        XCTAssertFalse(dead.isActive(now: now))
        // Grace covers an invoice opened moments before it ran out.
        XCTAssertTrue(dead.isActive(now: now, grace: 3600))
    }

    func testZeroPercentIsNeverActive() {
        let none = SubscriptionDiscount(percent: 0, expiresAt: Date().addingTimeInterval(3600))
        XCTAssertFalse(none.isActive())
    }

    func testApplyRoundsAndNeverReachesZero() {
        let thirty = SubscriptionDiscount(percent: 30, expiresAt: Date())
        XCTAssertEqual(thirty.apply(to: 1000), 700)
        XCTAssertEqual(thirty.apply(to: 199), 139)      // 139.3 → 139
        XCTAssertEqual(SubscriptionDiscount(percent: 99, expiresAt: Date()).apply(to: 1), 1)
        XCTAssertEqual(thirty.apply(to: 0), 0)
    }
}
