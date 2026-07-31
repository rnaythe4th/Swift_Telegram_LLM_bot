import XCTest
@testable import LLM_chat_bot

/// Address comparison is a money decision: anyone can mint a token for the
/// price of gas, so "close enough" here means a free subscription.
final class TonAddressTests: XCTestCase {

    // Same account, both spellings TON indexers use.
    private let raw = "0:b113a994b5024a16719f69139328eb759596c38a25f59028b146fecdc3621dfe"
    private let friendly = "EQCxE6mUtQJKFnGfaROTKOt1lZbDiiX1kCixRv7Nw2Id_sDs"

    func testBothSpellingsNormalizeToTheSameAccount() {
        XCTAssertEqual(TonAddress.normalized(raw), raw)
        XCTAssertEqual(TonAddress.normalized(friendly), raw)
        XCTAssertTrue(TonAddress.equal(raw, friendly))
        XCTAssertTrue(TonAddress.equal(friendly, raw))
    }

    func testDifferentAccountsNeverMatch() {
        let other = "0:" + String(repeating: "a", count: 64)
        XCTAssertFalse(TonAddress.equal(raw, other))
    }

    /// The heuristic this replaced ("one has a colon, the other starts with eq")
    /// let any jetton through as USDT.
    func testShapeAloneIsNotAMatch() {
        XCTAssertFalse(TonAddress.equal(raw, "EQ_not_an_address"))
        XCTAssertFalse(TonAddress.equal("0:zzzz", "EQCxE6mUtQJKFnGfaROTKOt1lZbDiiX1kCixRv7Nw2Id_sDs"))
    }

    func testUndecodableInputsFallBackToAnExactComparison() {
        XCTAssertTrue(TonAddress.equal("garbage", "GARBAGE"))
        XCTAssertFalse(TonAddress.equal("garbage", "other"))
    }

    func testMalformedRawAddressesAreRefused() {
        XCTAssertNil(TonAddress.normalized("0:abc"))                       // too short
        XCTAssertNil(TonAddress.normalized("x:" + String(repeating: "a", count: 64)))
        XCTAssertNil(TonAddress.normalized(""))
    }
}

final class CryptoAmountTests: XCTestCase {

    func testAtomicAmountsAreFormattedWithoutTrailingZeros() {
        XCTAssertEqual(CryptoAmountFormatter.format(atomic: 1_500_000, decimals: 6), "1.5")
        XCTAssertEqual(CryptoAmountFormatter.format(atomic: 1_000_000, decimals: 6), "1")
        XCTAssertEqual(CryptoAmountFormatter.format(atomic: 1, decimals: 6), "0.000001")
        XCTAssertEqual(CryptoAmountFormatter.format(atomic: 0, decimals: 9), "0")
    }

    func testAssetDecimalsMatchTheirChains() {
        XCTAssertEqual(CryptoAsset.tonNative.decimals, 9)
        XCTAssertEqual(CryptoAsset.usdtTon.decimals, 6)
        XCTAssertEqual(CryptoAsset.usdtBsc.chain, .bsc)
        XCTAssertEqual(CryptoAsset.usdtTrx.chain, .tron)
    }

    /// An invoice says "X left to pay", and X is what an incoming transfer is
    /// matched against.
    func testRemainingAmountDrivesMatching() {
        var invoice = CryptoInvoice(
            id: "i1",
            username: "#1",
            userChatID: 1,
            asset: .usdtTon,
            receivingAddress: "addr",
            exactAmountAtomic: 1_000_000,
            accumulatedAtomic: 0,
            quotedPriceUsdCents: 100,
            rateAtomicPerUsdCentMicro: 10_000,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(3600),
            status: .open,
            linkedSenders: [],
            creditedTxHashes: [],
            slotOffset: 0
        )
        XCTAssertEqual(invoice.remainingAtomic, 1_000_000)

        invoice.accumulatedAtomic = 400_000
        invoice.status = CryptoInvoiceStatus.partial
        XCTAssertEqual(invoice.remainingAtomic, 600_000)

        invoice.accumulatedAtomic = 1_200_000
        XCTAssertEqual(invoice.remainingAtomic, 0, "an overpayment never goes negative")
    }

    /// Invoices written before credit packs existed must keep working.
    func testLegacyInvoiceIsASubscription() throws {
        let json = """
        {"id":"i1","username":"#1","userChatID":1,"asset":"usdt_ton","receivingAddress":"a",
         "exactAmountAtomic":1000000,"accumulatedAtomic":0,"quotedPriceUsdCents":100,
         "rateAtomicPerUsdCentMicro":10000,"slotOffset":0,"status":"open","linkedSenders":[],
         "createdAt":0,"expiresAt":1,"creditedTxHashes":[]}
        """.data(using: .utf8)!
        let invoice = try JSONDecoder().decode(CryptoInvoice.self, from: json)
        XCTAssertEqual(invoice.resolvedPurpose, .subscription)
    }
}

final class CreditPackTests: XCTestCase {

    func testOnlyTheOfferedPacksAreAccepted() {
        for cents in CreditPack.centsOptions {
            XCTAssertTrue(CreditPack.isValid(cents: cents))
        }
        XCTAssertFalse(CreditPack.isValid(cents: 1))
        XCTAssertFalse(CreditPack.isValid(cents: 0))
        XCTAssertFalse(CreditPack.isValid(cents: -500))
    }

    func testLabelsAreWholeDollarsWhereTheyCanBe() {
        XCTAssertEqual(CreditPack.label(cents: 200), "$2")
        XCTAssertEqual(CreditPack.label(cents: 250), "$2.50")
    }
}

final class FiatCurrencyTests: XCTestCase {

    func testMinorUnitsAreFormattedWithTheirSymbol() {
        XCTAssertTrue(FiatCurrency.rub.format(minorUnits: 49900).contains("₽"))
        XCTAssertTrue(FiatCurrency.usd.format(minorUnits: 500).contains("$"))
        XCTAssertTrue(FiatCurrency.eur.format(minorUnits: 500).contains("€"))
    }

    /// Telegram rejects an amount below the provider minimum, so a discount is
    /// never allowed to push a card price under it.
    func testEveryCurrencyDeclaresAMinimum() {
        for currency in FiatCurrency.allCases {
            XCTAssertGreaterThan(currency.minMinorUnits, 0, "\(currency.rawValue)")
        }
    }
}
