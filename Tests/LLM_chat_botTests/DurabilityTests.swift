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
/// The public origin is glued to a path at three call sites, so it may not
/// carry a trailing slash. Worth a test because of how quietly it fails: a
/// pasted `https://host/` gives `setWebhook` the URL `https://host//telegram/
/// webhook`, which the router does not match — the deploy looks healthy and the
/// bot never receives another update.
final class PublicOriginTests: XCTestCase {

    func testATrailingSlashIsStrippedBeforeAPathIsAppended() {
        XCTAssertEqual(AppConfig.normalizedOrigin("https://bot.example.com/"), "https://bot.example.com")
        XCTAssertEqual(AppConfig.normalizedOrigin("https://bot.example.com///"), "https://bot.example.com")
        XCTAssertEqual(AppConfig.normalizedOrigin("  https://bot.example.com  "), "https://bot.example.com")
        XCTAssertEqual(AppConfig.normalizedOrigin("https://bot.example.com"), "https://bot.example.com")
    }

    func testTheWebhookURLItProducesIsTheOneTheRouterServes() {
        let origin = AppConfig.normalizedOrigin("https://bot.example.com/")
        XCTAssertEqual(origin + WebhookEndpoint.path, "https://bot.example.com/telegram/webhook")
    }

    /// Telegram accepts `A-Z a-z 0-9 _ -` and nothing else in `secret_token`.
    /// A secret it rejects fails `setWebhook`, the bot falls back to long
    /// polling and keeps working — which is exactly why the misconfiguration
    /// has to be caught at boot instead of found later.
    func testAWebhookSecretTelegramWouldRejectIsRejectedAtBoot() {
        XCTAssertTrue(AppConfig.isValidWebhookSecret("Abc_123-xyz"))
        XCTAssertTrue(AppConfig.isValidWebhookSecret(UUID().uuidString + UUID().uuidString))
        XCTAssertFalse(AppConfig.isValidWebhookSecret("has space"))
        XCTAssertFalse(AppConfig.isValidWebhookSecret("секрет"))
        XCTAssertFalse(AppConfig.isValidWebhookSecret("colon:separated"))
        XCTAssertFalse(AppConfig.isValidWebhookSecret(""))
        XCTAssertFalse(AppConfig.isValidWebhookSecret(String(repeating: "a", count: 257)))
    }
}

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

    /// The `Double` bridge saturates at the ceiling too. `Double(Int64.max)`
    /// rounds up to 2^63, so an inclusive upper bound admits exactly the value
    /// `Int64.init` traps on — and this call sits on the path of a super-admin
    /// typing an amount and of a provider reporting a cost.
    func testProviderCostAtTheInt64CeilingSaturatesInsteadOfTrapping() {
        // 2^63 nanodollars exactly: the boundary case, not an approximation.
        XCTAssertEqual(Money.usd(9_223_372_036.854775808), Money.nanos(.max))
        XCTAssertEqual(Money.usd(1e30), Money.nanos(.max))
        XCTAssertEqual(Money.usd(-9_223_372_036.854775808), Money.nanos(.min))
        XCTAssertEqual(Money.usd(-1e30), Money.nanos(.min))
        // And the largest amount that still fits comes back exact.
        XCTAssertEqual(Money.usd(9_223_372_036.0).nanoValue, 9_223_372_036_000_000_000)
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

/// Payment credentials live in the database because the owner configures them
/// from inside the bot — which means a dump, a backup or a leaked read-only
/// credential would otherwise hand over the card token and the checkout's
/// signing words (§5.6).
final class SecretBoxTests: XCTestCase {

    override func tearDown() {
        // The key is process-wide; leaving one behind would change how the
        // other suites encode their fixtures.
        SecretBox.configure(base64Key: nil)
    }

    private static let key = Data(repeating: 7, count: 32).base64EncodedString()

    func testARoundTripReturnsTheSameValue() {
        XCTAssertTrue(SecretBox.configure(base64Key: Self.key))
        let sealed = SecretBox.seal("provider:LIVE:token")
        XCTAssertNotEqual(sealed, "provider:LIVE:token", "the stored form must not be the value")
        XCTAssertFalse(sealed.contains("LIVE"))
        XCTAssertEqual(SecretBox.open(sealed), "provider:LIVE:token")
    }

    /// Every sealing is fresh, so two identical secrets do not produce two
    /// identical rows — otherwise a dump reveals which merchants share a word.
    func testSealingIsNotDeterministic() {
        SecretBox.configure(base64Key: Self.key)
        XCTAssertNotEqual(SecretBox.seal("same"), SecretBox.seal("same"))
    }

    /// Encryption is opt-in: a bot that has never had a key must keep working,
    /// and the values it already stored must stay readable.
    func testWithoutAKeyValuesPassThroughUnchanged() {
        SecretBox.configure(base64Key: nil)
        XCTAssertEqual(SecretBox.seal("plain"), "plain")
        XCTAssertEqual(SecretBox.open("plain"), "plain")
    }

    /// A value written before the key existed is still readable after it is
    /// introduced — otherwise turning encryption on locks the owner out of
    /// their own merchant settings.
    func testPlaintextWrittenBeforeTheKeyStaysReadable() {
        SecretBox.configure(base64Key: Self.key)
        XCTAssertEqual(SecretBox.open("written-before-the-key"), "written-before-the-key")
    }

    /// The wrong key must read as "not configured", never as garbage that gets
    /// signed into a request the vendor then rejects for reasons nobody can see.
    func testAWrongKeyYieldsNothingRatherThanNoise() {
        SecretBox.configure(base64Key: Self.key)
        let sealed = SecretBox.seal("secret-word")

        SecretBox.configure(base64Key: Data(repeating: 9, count: 32).base64EncodedString())
        XCTAssertEqual(SecretBox.open(sealed), "")
        XCTAssertTrue(SecretBox.isUnreadable(sealed))
    }

    /// A key that cannot be used is a configuration error, not something to
    /// shrug off and store secrets in the clear.
    func testAMalformedKeyIsRejected() {
        XCTAssertFalse(SecretBox.configure(base64Key: "not-base64!!"))
        XCTAssertFalse(SecretBox.configure(base64Key: Data(repeating: 1, count: 16).base64EncodedString()))
        XCTAssertTrue(SecretBox.configure(base64Key: nil), "no key at all is a supported mode")
    }

    /// The whole point: what reaches the row is ciphertext, and what comes back
    /// out of it is the credential.
    func testCheckoutCredentialsAreEncryptedInTheStoredRow() throws {
        SecretBox.configure(base64Key: Self.key)
        var config = ExternalPaymentConfig.default
        config.merchantID = "7012"
        config.secretWord = "word-one"
        config.callbackSecret = "word-two"

        let json = try XCTUnwrap(String(data: try JSONEncoder().encode(config), encoding: .utf8))
        XCTAssertFalse(json.contains("word-one"), "the signing word must not be in the row")
        XCTAssertFalse(json.contains("word-two"))
        XCTAssertTrue(json.contains("7012"), "the merchant id is not a secret")

        let decoded = try JSONDecoder().decode(ExternalPaymentConfig.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.secretWord, "word-one")
        XCTAssertEqual(decoded.callbackSecret, "word-two")
        XCTAssertEqual(decoded.merchantID, "7012")
    }

    /// The rule the whole `SealedSecret` type exists for: a deploy that comes
    /// up without the key — a rollback, a fresh environment, a rotated value —
    /// must not be able to overwrite credentials it cannot read.
    ///
    /// The old code decoded the secret to "" and wrote that "" back on the next
    /// save, so one settings edit under the wrong key destroyed the merchant's
    /// signing words for good: bringing the key back recovered nothing, and
    /// nothing said so, because an unreadable secret already reads as "not
    /// configured".
    func testASecretSealedUnderAnotherKeySurvivesBeingRewritten() throws {
        SecretBox.configure(base64Key: Self.key)
        var config = ExternalPaymentConfig.default
        config.merchantID = "7012"
        config.secretWord = "word-one"
        config.callbackSecret = "word-two"
        let original = try JSONEncoder().encode(config)

        // A process that boots with a different key: the words read as absent…
        let otherKey = Data(repeating: 9, count: 32).base64EncodedString()
        SecretBox.configure(base64Key: otherKey)
        var reopened = try JSONDecoder().decode(ExternalPaymentConfig.self, from: original)
        XCTAssertNil(reopened.secretWord?.value, "a word we cannot open must read as not configured")
        XCTAssertNil(reopened.credentials, "and the checkout must refuse to sign anything")
        XCTAssertTrue(reopened.secretsAreUnreadable, "…but the page must be able to say why")

        // …and that process saves the row for an unrelated reason.
        reopened.priceMinorUnits = 59_900
        let rewritten = try JSONEncoder().encode(reopened.normalized)

        // The key comes back. So do the credentials.
        SecretBox.configure(base64Key: Self.key)
        let recovered = try JSONDecoder().decode(ExternalPaymentConfig.self, from: rewritten)
        XCTAssertEqual(recovered.secretWord?.value, "word-one")
        XCTAssertEqual(recovered.callbackSecret?.value, "word-two")
        XCTAssertEqual(recovered.priceMinorUnits, 59_900, "the edit that triggered the save still applied")
        XCTAssertNotNil(recovered.credentials)
    }

    /// Same rule for the card token, which travels a different code path (its
    /// own `Codable`) to the same row.
    func testTheCardTokenSurvivesARewriteUnderAnotherKey() throws {
        SecretBox.configure(base64Key: Self.key)
        var config = CardPaymentConfig.empty
        config.providerToken = "390540012:LIVE:secret"
        let original = try JSONEncoder().encode(config)

        SecretBox.configure(base64Key: Data(repeating: 3, count: 32).base64EncodedString())
        var reopened = try JSONDecoder().decode(CardPaymentConfig.self, from: original)
        XCTAssertNil(reopened.token)
        XCTAssertFalse(reopened.isEnabled, "no token means no card sales, whatever the price says")
        XCTAssertTrue(reopened.tokenIsUnreadable)
        reopened.priceMinorUnits = 49_900
        let rewritten = try JSONEncoder().encode(reopened)

        SecretBox.configure(base64Key: Self.key)
        XCTAssertEqual(
            try JSONDecoder().decode(CardPaymentConfig.self, from: rewritten).token,
            "390540012:LIVE:secret"
        )
    }

    /// A secret that comes back out of storage has to be redactable before
    /// anything can quote it: a transport error prints the request it failed
    /// on, and for the checkout that request carries the signing word. Only the
    /// *typing* path used to register it, so every restart left the running
    /// process with an unregistered secret.
    func testDecodingASecretRegistersItForRedaction() throws {
        SecretBox.configure(base64Key: Self.key)
        var config = ExternalPaymentConfig.default
        config.callbackSecret = "callback-word-from-storage"
        let row = try JSONEncoder().encode(config)

        _ = try JSONDecoder().decode(ExternalPaymentConfig.self, from: row)

        XCTAssertFalse(
            SecretRedactor.shared.redact("POST /pay?sign=callback-word-from-storage")
                .contains("callback-word-from-storage")
        )
    }

    func testCardTokenIsEncryptedInTheStoredRow() throws {
        SecretBox.configure(base64Key: Self.key)
        let config = CardPaymentConfig(
            providerToken: "390540012:LIVE:secret",
            currency: .rub,
            priceMinorUnits: 49_900,
            usdRateMinorUnits: 9_500
        )
        let json = try XCTUnwrap(String(data: try JSONEncoder().encode(config), encoding: .utf8))
        XCTAssertFalse(json.contains("390540012:LIVE:secret"))

        let decoded = try JSONDecoder().decode(CardPaymentConfig.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.providerToken, "390540012:LIVE:secret")
        XCTAssertEqual(decoded.priceMinorUnits, 49_900)
        XCTAssertEqual(decoded.usdRateMinorUnits, 9_500)
    }
}

/// `/metrics` is the only window into a running bot, and a scraper reads it
/// with no human to notice a malformed line (§6.2).
final class PrometheusReportTests: XCTestCase {

    /// Campaign tags reach label values, and a super-admin picks those. An
    /// unescaped quote would end the label and turn the rest into syntax.
    func testLabelValuesAreEscaped() {
        XCTAssertEqual(BotOrchestrator.escapeLabelForTests(#"open"purchase"#), #"open\"purchase"#)
        XCTAssertEqual(BotOrchestrator.escapeLabelForTests(#"back\slash"#), #"back\\slash"#)
        XCTAssertEqual(BotOrchestrator.escapeLabelForTests("two\nlines"), "two lines")
        XCTAssertEqual(BotOrchestrator.escapeLabelForTests("plain"), "plain")
    }
}
