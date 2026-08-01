import XCTest
@testable import LLM_chat_bot

/// The connection string is the one piece of production configuration nobody
/// can test by reading it, and getting it subtly wrong (transaction pooler,
/// no TLS) breaks guarantees silently rather than loudly.
final class DatabaseEndpointTests: XCTestCase {

    func testParsesAFullConnectionString() throws {
        let endpoint = try XCTUnwrap(DatabaseEndpoint(
            urlString: "postgres://bot:p%40ss@db.example.com:5432/botdb?sslmode=require"
        ))
        XCTAssertEqual(endpoint.host, "db.example.com")
        XCTAssertEqual(endpoint.port, 5432)
        XCTAssertEqual(endpoint.username, "bot")
        XCTAssertEqual(endpoint.password, "p@ss", "a percent-encoded password must be decoded")
        XCTAssertEqual(endpoint.database, "botdb")
        XCTAssertTrue(endpoint.requiresTLS)
        XCTAssertFalse(endpoint.verifiesCertificate, "`require` encrypts; it does not verify")
    }

    /// TLS is what you get unless it is switched off on purpose — forgetting a
    /// query parameter must not silently send the password in the clear.
    func testTLSIsTheDefaultAndOnlyDisableTurnsItOff() throws {
        let bare = try XCTUnwrap(DatabaseEndpoint(urlString: "postgres://bot:p@host/db"))
        XCTAssertTrue(bare.requiresTLS)

        let off = try XCTUnwrap(DatabaseEndpoint(urlString: "postgres://bot:p@host/db?sslmode=disable"))
        XCTAssertFalse(off.requiresTLS)

        let verified = try XCTUnwrap(DatabaseEndpoint(urlString: "postgres://bot:p@host/db?sslmode=verify-full"))
        XCTAssertTrue(verified.verifiesCertificate)
    }

    /// The transaction pooler answers `pg_try_advisory_lock` with `true` and
    /// then drops the lock with the connection. Spotting the port is the only
    /// warning anyone gets before the single-writer guarantee quietly stops
    /// holding (§3.1).
    func testTheTransactionPoolerPortIsRecognised() throws {
        let session = try XCTUnwrap(DatabaseEndpoint(urlString: "postgres://u:p@pooler.example.com:5432/db"))
        XCTAssertFalse(session.looksLikeTransactionPooler)

        let transaction = try XCTUnwrap(DatabaseEndpoint(urlString: "postgres://u:p@pooler.example.com:6543/db"))
        XCTAssertTrue(transaction.looksLikeTransactionPooler)
    }

    /// Half a connection string is not a connection string: the bot runs
    /// memory-only rather than starting with something that cannot work.
    func testUnusableURLsAreRejected() {
        XCTAssertNil(DatabaseEndpoint(urlString: ""))
        XCTAssertNil(DatabaseEndpoint(urlString: "https://example.com/db"))
        XCTAssertNil(DatabaseEndpoint(urlString: "postgres:///db"), "no host")
        XCTAssertNil(DatabaseEndpoint(urlString: "postgres://host/db"), "no user")
    }

    /// The password must never reach a log line.
    func testDisplayNameCarriesNoSecret() throws {
        let endpoint = try XCTUnwrap(DatabaseEndpoint(urlString: "postgres://bot:hunter2@host:5432/db"))
        XCTAssertFalse(endpoint.displayName.contains("hunter2"))
        XCTAssertEqual(endpoint.displayName, "host:5432/db")
    }
}

/// Selling from state that will not survive the process is the one failure
/// where refusing is strictly better than succeeding (§4.3).
final class StateDurabilityTests: XCTestCase {

    func testOnlyDurableStateMaySell() {
        XCTAssertTrue(StateDurability.durable.acceptsPayments)
        XCTAssertFalse(StateDurability.volatile(reason: "no database").acceptsPayments)
        XCTAssertFalse(StateDurability.readOnly(reason: "another writer").acceptsPayments)
    }

    /// A replica that is not the writer must not answer at all — its state
    /// belongs to another process. A bot with no database still answers; it
    /// just sells nothing.
    func testOnlyTheNonWriterStopsAnsweringUpdates() {
        XCTAssertTrue(StateDurability.durable.acceptsUpdates)
        XCTAssertTrue(StateDurability.volatile(reason: "no database").acceptsUpdates)
        XCTAssertFalse(StateDurability.readOnly(reason: "another writer").acceptsUpdates)
    }

    func testDegradedIsAnythingThatCannotSell() {
        XCTAssertFalse(StateDurability.durable.isDegraded)
        XCTAssertTrue(StateDurability.volatile(reason: "x").isDegraded)
        XCTAssertTrue(StateDurability.readOnly(reason: "x").isDegraded)
    }
}

/// Money is integral so that decisions taken on its boundary are decidable.
final class MoneyTests: XCTestCase {

    func testCentsAndUsdAgree() {
        XCTAssertEqual(Money.cents(100), .usd(1))
        XCTAssertEqual(Money.cents(1).nanoValue, 10_000_000)
        XCTAssertEqual(Money.usd(0.0000173).nanoValue, 17_300)
    }

    /// The failure `Double` made possible: a thousand deductions leaving a
    /// balance that is negative for one comparison and zero for the next.
    func testRepeatedDeductionsLandExactlyOnZero() {
        let step = Money.usd(0.0000173)
        var balance = Money.zero
        for _ in 0..<1000 { balance += step }
        for _ in 0..<1000 { balance -= step }
        XCTAssertEqual(balance, .zero)
        XCTAssertFalse(balance.isPositive)
    }

    /// Order must not change a total, or "spent" can never be reconciled
    /// against "charged".
    func testAdditionIsOrderIndependent() {
        let amounts: [Money] = [.usd(0.1), .usd(0.2), .usd(0.0000001), .cents(7), .usd(3.33)]
        let forward = amounts.reduce(Money.zero, +)
        let backward = amounts.reversed().reduce(Money.zero, +)
        XCTAssertEqual(forward, backward)
    }

    /// Markup rounds towards zero — in the customer's favour. Rounding the
    /// other way is itself a sum of money over a million turns.
    func testMarkupRoundsInTheCustomersFavour() {
        XCTAssertEqual(Money.usd(1).multiplied(byPercent: 30), .usd(1.3))
        XCTAssertEqual(Money.nanos(3).multiplied(byPercent: 30), .nanos(3))
        XCTAssertEqual(Money.zero.multiplied(byPercent: 500), .zero)
    }

    /// A provider sending nonsense must not take the process down with it.
    func testNonFiniteProviderCostIsWorthNothing() {
        XCTAssertEqual(Money.usd(.nan), .zero)
        XCTAssertEqual(Money.usd(.infinity), .zero)
        XCTAssertEqual(Money.usd(-.infinity), .zero)
    }

    /// Saturating rather than trapping: an overflow in the payment path would
    /// take the process down mid-payment.
    func testArithmeticSaturatesInsteadOfTrapping() {
        let huge = Money.nanos(.max)
        XCTAssertEqual(huge + huge, huge)
        XCTAssertEqual(huge.multiplied(byPercent: 500), huge)
    }

    func testClampAndFormatting() {
        XCTAssertEqual((Money.cents(1) - Money.cents(5)).clampedToZero, .zero)
        XCTAssertEqual(Money.usd(1.5).formatted(fractionDigits: 2), "$1.50")
        XCTAssertEqual(Money.usd(-1.5).formattedAmount(fractionDigits: 2), "1.50")
        XCTAssertEqual(Money.cents(250).wholeCents, 250)
    }

    /// The amount survives storage as an integer, not as a printed decimal.
    func testCodableRoundTripIsExact() throws {
        let amount = Money.usd(0.0000173)
        let data = try JSONEncoder().encode(amount)
        XCTAssertEqual(String(data: data, encoding: .utf8), "17300")
        XCTAssertEqual(try JSONDecoder().decode(Money.self, from: data), amount)
    }
}
