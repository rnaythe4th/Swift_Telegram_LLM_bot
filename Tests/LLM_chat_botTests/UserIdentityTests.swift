import XCTest
@testable import LLM_chat_bot

/// `UserKey` is what every wallet, licence and subscription is filed under, and
/// it is also written into database filters and HTML — so its shape is a
/// security property, not a formatting detail.
final class UserKeyTests: XCTestCase {

    func testIdentifiedKeyShape() {
        XCTAssertEqual(UserKey.identified(42), UserKey.identified(42))
        XCTAssertTrue(UserKey.identified(42).isIdentified)
        XCTAssertFalse(UserKey.pending("alice")!.isIdentified)
        XCTAssertEqual(UserKey.identified(42).userID, 42)
        XCTAssertNil(UserKey.pending("alice")!.userID)
        XCTAssertEqual(UserKey.identified(42).storageValue, "#42")
    }

    /// `#-1` and `#1` must not both parse — a key has exactly one spelling.
    func testSignedDigitsAreNotAKey() {
        XCTAssertNil(UserKey(storageValue: "#+1").userID)
        XCTAssertNil(UserKey(storageValue: "#-1").userID)
        XCTAssertNil(UserKey(storageValue: "#").userID)
    }

    /// A key never prints itself into a message: interpolating one is a bug,
    /// and the description says so instead of looking like a label.
    func testKeyDoesNotRenderAsALabel() {
        XCTAssertEqual("\(UserKey.identified(42))", "UserKey(#42)")
    }

    func testPendingKeyNormalizesHandles() {
        XCTAssertEqual(UserKey.pending("@Alice")?.storageValue, "alice")
        XCTAssertEqual(UserKey.pending("  BOB ")?.storageValue, "bob")
        XCTAssertNil(UserKey.pending(nil))
        XCTAssertNil(UserKey.pending(""))
        XCTAssertNil(UserKey.pending("@"))
    }

    /// A typed argument must not be able to forge an identified key or smuggle
    /// punctuation into a PostgREST filter.
    func testPendingKeyRejectsAnythingNotUsernameShaped() {
        XCTAssertNil(UserKey.pending("#12345"))
        XCTAssertNil(UserKey.pending("a&b"))
        XCTAssertNil(UserKey.pending("dro p"))
        XCTAssertNil(UserKey.pending(String(repeating: "a", count: 33)))
    }

    func testSanitizedFallbackKeepsOnlyUsernameCharacters() {
        XCTAssertEqual(UserKey.sanitizedPendingFallback("A&b#c d_1").storageValue, "abcd_1")
        XCTAssertEqual(UserKey.sanitizedPendingFallback(String(repeating: "x", count: 40)).storageValue.count, 32)
    }
}

final class UserIdentityTests: XCTestCase {

    func testDisplayLabelPrefersUsernameThenNameThenID() {
        let withName = UserIdentity(userID: 1, username: "alice", firstName: "Alice", seenAt: Date(), firstSeenAt: nil)
        XCTAssertEqual(withName.displayLabel, "@alice")

        let nameOnly = UserIdentity(userID: 2, username: nil, firstName: "Боб", seenAt: Date(), firstSeenAt: nil)
        XCTAssertEqual(nameOnly.displayLabel, "Боб")

        let bare = UserIdentity(userID: 3, username: nil, firstName: nil, seenAt: Date(), firstSeenAt: nil)
        XCTAssertEqual(bare.displayLabel, "id 3")
    }

    /// A display name is arbitrary user text pasted into a message the bot signs
    /// its own name to — escaping lives here, at the source of the label.
    func testNameIsEscapedAtTheSource() {
        let hostile = UserIdentity(
            userID: 4,
            username: nil,
            firstName: "<a href=\"https://evil.test\">Поддержка</a>",
            seenAt: Date(),
            firstSeenAt: nil
        )
        XCTAssertFalse(hostile.displayLabel.contains("<a"))
        XCTAssertTrue(hostile.displayLabel.contains("&lt;"))
    }

    func testNewlinesAndControlCharactersCannotForgeExtraLines() {
        let forged = UserIdentity.sanitizeName("@alice\n@bob · суперадмин")
        XCTAssertNotNil(forged)
        XCTAssertFalse(forged!.contains("\n"))
    }

    func testLongNameIsClipped() {
        let clipped = UserIdentity.sanitizeName(String(repeating: "я", count: 200))
        XCTAssertEqual(clipped?.count, UserIdentity.maxNameLength + 1)  // + ellipsis
        XCTAssertTrue(clipped?.hasSuffix("…") == true)
    }

    func testBlankNameIsNil() {
        XCTAssertNil(UserIdentity.sanitizeName("   "))
        XCTAssertNil(UserIdentity.sanitizeName(nil))
    }
}

final class UserDirectoryTests: XCTestCase {

    func testRecordingANewPersonReportsTheChange() {
        var directory = UserDirectory.empty
        let first = directory.record(userID: 7, username: "alice", firstName: "Alice")
        XCTAssertTrue(first.changed)
        XCTAssertTrue(first.seenAtAdvanced)
        XCTAssertNil(first.previousUsername)
        XCTAssertEqual(directory.userID(forUsername: "@alice"), 7)
    }

    func testRenameFreesTheOldHandleAndReportsIt() {
        var directory = UserDirectory.empty
        directory.record(userID: 7, username: "alice", firstName: nil)
        let renamed = directory.record(userID: 7, username: "alice2", firstName: nil)
        XCTAssertEqual(renamed.previousUsername, "alice")
        XCTAssertNil(directory.userID(forUsername: "alice"))
        XCTAssertEqual(directory.userID(forUsername: "alice2"), 7)
    }

    /// Telegram handles are unique at any instant: a live sighting proves the
    /// previous holder let the name go.
    func testHandleTakenOverByAnotherPersonPointsAtTheNewOne() {
        var directory = UserDirectory.empty
        directory.record(userID: 7, username: "alice", firstName: nil)
        directory.record(userID: 8, username: "alice", firstName: nil)
        XCTAssertEqual(directory.userID(forUsername: "alice"), 8)
        XCTAssertNil(directory.identity(userID: 7)?.username)
    }

    /// The directory is one JSON row; writing it on every message is not an
    /// option, so `seenAt` only counts as advanced past the throttle.
    func testSeenAtIsThrottled() {
        var directory = UserDirectory.empty
        let start = Date()
        directory.record(userID: 7, username: "alice", firstName: nil, now: start)
        let soon = directory.record(userID: 7, username: "alice", firstName: nil, now: start.addingTimeInterval(60))
        XCTAssertFalse(soon.seenAtAdvanced)
        // In-memory `seenAt` moves on every sighting, so the throttle is measured
        // from the last one, not from the first.
        let later = directory.record(
            userID: 7, username: "alice", firstName: nil,
            now: start.addingTimeInterval(60 + UserDirectory.seenAtPersistInterval + 1)
        )
        XCTAssertTrue(later.seenAtAdvanced)
    }

    func testDisplayLabelForKeyNeverLeaksTheKeyItself() {
        var directory = UserDirectory.empty
        directory.record(userID: 7, username: "alice", firstName: nil)
        XCTAssertEqual(directory.displayLabel(forKey: UserKey.identified(7)), "@alice")
        XCTAssertEqual(directory.displayLabel(forKey: UserKey.identified(404)), "id 404")
        XCTAssertEqual(directory.displayLabel(forKey: UserKey.pending("pendinguser")!), "@pendinguser")
    }

    func testPruneKeepsPeopleWhoHoldState() {
        var directory = UserDirectory.empty
        let base = Date(timeIntervalSince1970: 1_000_000)
        for id in 1...(UserDirectory.maxIdentities + 10) {
            directory.record(userID: id, username: nil, firstName: nil, now: base.addingTimeInterval(Double(id)))
        }
        // Oldest entries are the first candidates; protect one of them.
        directory.prune(protectedKeys: [UserKey.identified(1)])
        XCTAssertNotNil(directory.identity(userID: 1))
        XCTAssertEqual(directory.identities.count, UserDirectory.maxIdentities)
    }

    func testRetentionCountsOnlyPeopleOldEnoughToHaveReturned() {
        var directory = UserDirectory.empty
        let now = Date()
        // Arrived two days ago, came back yesterday → in the D1 cohort, retained.
        directory.record(userID: 1, username: nil, firstName: nil, now: now.addingTimeInterval(-Fixtures.days(2)))
        directory.record(userID: 1, username: nil, firstName: nil, now: now.addingTimeInterval(-Fixtures.days(0.5)))
        // Arrived an hour ago → too new to be in any cohort.
        directory.record(userID: 2, username: nil, firstName: nil, now: now.addingTimeInterval(-3600))

        let snapshot = directory.retention(now: now)
        XCTAssertEqual(snapshot.cohortD1, 1)
        XCTAssertEqual(snapshot.returnedD1, 1)
        XCTAssertEqual(snapshot.cohortD7, 0)
    }

    func testCodableRoundTripRebuildsTheUsernameIndex() throws {
        var directory = UserDirectory.empty
        directory.record(userID: 7, username: "alice", firstName: "Alice")
        directory.rootKey = UserKey.identified(7)

        let data = try JSONEncoder().encode(directory)
        let restored = try JSONDecoder().decode(UserDirectory.self, from: data)

        XCTAssertEqual(restored.rootKey, UserKey.identified(7))
        XCTAssertEqual(restored.userID(forUsername: "alice"), 7)
        XCTAssertEqual(restored.displayLabel(forKey: UserKey.identified(7)), "@alice")
    }
}
