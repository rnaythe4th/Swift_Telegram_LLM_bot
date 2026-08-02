import XCTest
@testable import LLM_chat_bot

// What happens to a crypto transfer once it lands, with the real service, the
// real invoice bookkeeping and the shared fulfilment routine. Only the Bot API
// and the blockchain reader are absent — the transfer is handed in directly,
// exactly as the monitor hands one in.
//
// The rule under test is the one the chain gives us no second chance at:
// a blockchain does not redeliver. If a transfer that arrived is not credited,
// the *only* recovery is the next poll finding it again — which means neither
// the invoice nor the scan cursor may move past a settlement that failed.

final class CryptoSettlementTests: XCTestCase {
    private var telegram: FakeTelegram!
    private var gateway: TelegramHTTPGateway!
    private var store: ChatContextStore!

    private let payerID: UserID = 9_100
    private let address = "UQtest_receiving_address"

    override func setUp() async throws {
        telegram = FakeTelegram()
        let baseURL = try await telegram.start()
        gateway = TelegramHTTPGateway(
            network: NetworkClient(),
            botToken: "test-token",
            apiBase: baseURL,
            rateLimiter: nil,
            metrics: nil
        )
        store = Fixtures.makeStore()
        await store.setCryptoPriceUsdCents(500)
        await store.setCryptoAddress(.ton, address: address)
    }

    override func tearDown() async throws {
        await telegram.stop()
        telegram = nil
        gateway = nil
        store = nil
    }

    private func makeService(ledger: LedgerPort) -> CryptoPaymentService {
        CryptoPaymentService(
            state: store,
            network: NetworkClient(),
            telegram: gateway,
            logger: SilentLogger(),
            fulfillment: PaymentFulfillmentService(
                state: store,
                telegram: gateway,
                ledger: ledger,
                persistence: nil,
                metrics: RuntimeMetrics(),
                logger: SilentLogger()
            ),
            persistence: nil
        )
    }

    /// One open invoice for exactly 5 USDT-on-TON, filed under the payer.
    @discardableResult
    private func openInvoice(amountAtomic: Int64 = 5_000_000) async -> CryptoInvoice {
        let now = Date()
        let invoice = CryptoInvoice(
            id: "inv-1",
            ownerKey: store.userKey(userID: payerID),
            userChatID: payerID.privateChat,
            asset: .usdtTon,
            receivingAddress: address,
            exactAmountAtomic: amountAtomic,
            accumulatedAtomic: 0,
            quotedPriceUsdCents: 500,
            rateAtomicPerUsdCentMicro: 10_000_000_000,
            createdAt: now,
            expiresAt: now.addingTimeInterval(1_800),
            status: .open,
            linkedSenders: [],
            creditedTxHashes: [],
            slotOffset: 0,
            purpose: .subscription
        )
        await store.upsertCryptoInvoice(invoice)
        return invoice
    }

    private func deliver(
        _ service: CryptoPaymentService,
        amountAtomic: Int64 = 5_000_000,
        txHash: String = "0xdeadbeef"
    ) async -> CryptoApplyResult {
        await service.applyIncomingTransfer(
            asset: .usdtTon,
            amountAtomic: amountAtomic,
            fromAddress: "UQsender",
            recipientAddress: address,
            txHash: txHash,
            timestamp: Date()
        )
    }

    // MARK: - Tests

    func testAnExactTransferPaysTheInvoiceAndOpensPremium() async {
        await openInvoice()

        let result = await deliver(makeService(ledger: InMemoryLedger()))
        guard case .fullyPaid = result else {
            return XCTFail("an exact transfer must settle the invoice, got \(result)")
        }
        let subscription = await store.tenantSubscription(ownerKey: store.userKey(userID: payerID))
        XCTAssertTrue(subscription.isActive)
        let settled = await store.cryptoInvoice(id: "inv-1")
        XCTAssertEqual(settled?.status, .paid)
    }

    /// The database refusing the write must leave the invoice open. Closing it
    /// first — which is what this used to do — meant the next poll matched only
    /// open invoices, found none, and the transfer bought nothing forever: the
    /// chain has no redelivery to fall back on.
    func testASettlementTheDatabaseRefusesLeavesTheInvoiceOpen() async {
        await openInvoice()

        let result = await deliver(makeService(ledger: RefusingLedger()))
        guard case .deferred = result else {
            return XCTFail("a refused settlement must be deferred, got \(result)")
        }
        let invoice = await store.cryptoInvoice(id: "inv-1")
        XCTAssertEqual(invoice?.status, .open, "the invoice has to stay payable")
        XCTAssertTrue(invoice?.creditedTxHashes.isEmpty == true, "nothing was credited, so nothing may be marked credited")
        let subscription = await store.tenantSubscription(ownerKey: store.userKey(userID: payerID))
        XCTAssertFalse(subscription.isActive, "nothing was committed, so nothing may be granted")

        // The next poll sees the same transfer and settles it once.
        let retry = await deliver(makeService(ledger: InMemoryLedger()))
        guard case .fullyPaid = retry else {
            return XCTFail("the retry must settle the invoice, got \(retry)")
        }
        let granted = await store.tenantSubscription(ownerKey: store.userKey(userID: payerID))
        XCTAssertTrue(granted.isActive)
        let report = await store.funnelReport()
        XCTAssertEqual(report.counters[FunnelEvent.paid.rawValue], 1, "the payment must count once")
    }

    /// A partial payment is received money: it stays on the invoice so the
    /// payer is asked for the difference, not for the whole amount again.
    /// (Above half the outstanding amount — below that a transfer may not claim
    /// an invoice it is not linked to, or one dust payment parks a stranger's
    /// invoice in `.partial`.)
    func testAPartialTransferAccumulatesRatherThanResetting() async {
        await openInvoice()

        let result = await deliver(makeService(ledger: InMemoryLedger()), amountAtomic: 3_000_000, txHash: "0xpart")
        guard case .partial(_, _, let remaining) = result else {
            return XCTFail("an underpayment must be recorded as partial, got \(result)")
        }
        XCTAssertEqual(remaining, 2_000_000)
        let held = await store.cryptoInvoice(id: "inv-1")
        XCTAssertEqual(held?.accumulatedAtomic, 3_000_000)
    }

    /// Dust must not be able to claim somebody else's invoice: adopting it
    /// would park it in `.partial` and attach the sender, and every later
    /// transfer from that address would follow it there.
    func testDustCannotClaimAnUnlinkedInvoice() async {
        await openInvoice()

        let result = await deliver(makeService(ledger: InMemoryLedger()), amountAtomic: 1, txHash: "0xdust")
        guard case .unmatched = result else {
            return XCTFail("a dust transfer must not claim an invoice, got \(result)")
        }
        let untouched = await store.cryptoInvoice(id: "inv-1")
        XCTAssertEqual(untouched?.status, .open)
        XCTAssertEqual(untouched?.accumulatedAtomic, 0)
    }

    // MARK: - Keeping the invoice table bounded

    private func invoice(_ id: String, status: CryptoInvoiceStatus, createdAt: Date) -> CryptoInvoice {
        CryptoInvoice(
            id: id,
            ownerKey: store.userKey(userID: payerID),
            userChatID: payerID.privateChat,
            asset: .usdtTon,
            receivingAddress: address,
            exactAmountAtomic: 5_000_000,
            accumulatedAtomic: 0,
            quotedPriceUsdCents: 500,
            rateAtomicPerUsdCentMicro: 10_000_000_000,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(1_800),
            status: status,
            linkedSenders: [],
            creditedTxHashes: [],
            slotOffset: 0,
            purpose: .subscription
        )
    }

    /// Every abandoned purchase leaves an invoice, and an invoice is not free
    /// to keep: it is a `bot_crypto_invoice` row read back whole at restore and
    /// a member of the collection the monitor scans every thirty seconds. So
    /// settled ones are dropped once the table outgrows its budget — and open
    /// ones never are, because those are transfers the chain will not redeliver.
    func testSettledInvoicesArePrunedAndInflightOnesAreNot() async {
        let base = Date().addingTimeInterval(-100_000)
        let budget = ChatContextStore.maxStoredCryptoInvoices

        await store.upsertCryptoInvoice(invoice("open-oldest", status: .open, createdAt: base))
        await store.upsertCryptoInvoice(invoice("partial-oldest", status: .partial, createdAt: base))
        for index in 0..<(budget + 50) {
            await store.upsertCryptoInvoice(
                invoice("settled-\(index)", status: .paid, createdAt: base.addingTimeInterval(Double(index)))
            )
        }

        let held = await store.openCryptoInvoices().count
        XCTAssertEqual(held, 2, "money in flight is never pruned")
        let openOldest = await store.cryptoInvoice(id: "open-oldest")
        XCTAssertNotNil(openOldest)
        let partialOldest = await store.cryptoInvoice(id: "partial-oldest")
        XCTAssertNotNil(partialOldest)

        // The newest settled invoice survives; the oldest ones are gone.
        let newestSettled = await store.cryptoInvoice(id: "settled-\(budget + 49)")
        XCTAssertNotNil(newestSettled)
        let oldestSettled = await store.cryptoInvoice(id: "settled-0")
        XCTAssertNil(oldestSettled, "the table must not grow for ever")
    }

    /// Settling an invoice is itself a write, and a write is what triggers the
    /// prune. The invoice being written must survive it — the caller is still
    /// holding it, and for crypto the caller may still need to leave the door
    /// open (`.deferred`).
    func testSettlingAnOldInvoiceDoesNotDeleteItMidWrite() async {
        let base = Date().addingTimeInterval(-100_000)
        let budget = ChatContextStore.maxStoredCryptoInvoices

        var oldest = invoice("oldest", status: .open, createdAt: base)
        await store.upsertCryptoInvoice(oldest)
        for index in 0..<(budget + 50) {
            await store.upsertCryptoInvoice(
                invoice("settled-\(index)", status: .paid, createdAt: base.addingTimeInterval(Double(index + 1)))
            )
        }

        oldest.status = .paid
        await store.upsertCryptoInvoice(oldest)

        let stillThere = await store.cryptoInvoice(id: "oldest")
        XCTAssertNotNil(stillThere)
    }

    // MARK: - The deadline belongs to the payer, not to the poller

    /// A transfer sent inside the window but *seen* after it. Between the two
    /// sit the chain's confirmation delay and up to a full poll interval, and
    /// the invoice counts «Срок: N мин» down in front of the payer — so paying
    /// in the last minute is the normal case. Expiring by the clock threw that
    /// money away, and a blockchain has no redelivery to recover it with.
    func testAPaymentSentBeforeExpiryIsCreditedEvenWhenSeenAfterIt() async {
        var late = invoice("inv-late", status: .open, createdAt: Date().addingTimeInterval(-1_900))
        late.expiresAt = Date().addingTimeInterval(-100)
        await store.upsertCryptoInvoice(late)

        let result = await makeService(ledger: InMemoryLedger()).applyIncomingTransfer(
            asset: .usdtTon,
            amountAtomic: 5_000_000,
            fromAddress: "UQsender",
            recipientAddress: address,
            txHash: "0xlate",
            timestamp: Date().addingTimeInterval(-200)
        )

        guard case .fullyPaid = result else {
            return XCTFail("money sent inside the window must still be credited, got \(result)")
        }
        let subscription = await store.tenantSubscription(ownerKey: store.userKey(userID: payerID))
        XCTAssertTrue(subscription.isActive)
    }

    /// The other half of the same rule: money that left *after* the deadline
    /// does not settle an invoice the sweep has not got to yet.
    func testAPaymentSentAfterExpiryIsNotCredited() async {
        var late = invoice("inv-late", status: .open, createdAt: Date().addingTimeInterval(-1_900))
        late.expiresAt = Date().addingTimeInterval(-100)
        await store.upsertCryptoInvoice(late)

        let result = await makeService(ledger: InMemoryLedger()).applyIncomingTransfer(
            asset: .usdtTon,
            amountAtomic: 5_000_000,
            fromAddress: "UQsender",
            recipientAddress: address,
            txHash: "0xtoolate",
            timestamp: Date()
        )

        guard case .unmatched = result else {
            return XCTFail("a transfer sent after the deadline must not settle the invoice, got \(result)")
        }
    }

    /// A tx hash is credited once, and the invoice it paid is closed by then —
    /// so «have I seen this hash» has to be asked of every invoice, not only of
    /// those still awaiting funds. Asking the open ones meant a hash re-offered
    /// by the explorer (same-second boundary, a re-scan) looked brand new and
    /// settled somebody else's invoice with money that was already spent.
    func testACreditedTransferCannotSettleASecondInvoice() async {
        await openInvoice()
        let first = await deliver(makeService(ledger: InMemoryLedger()), txHash: "0xonce")
        guard case .fullyPaid = first else {
            return XCTFail("premise: the first invoice is paid, got \(first)")
        }

        // Someone else's invoice, same asset, same outstanding amount.
        var other = invoice("inv-2", status: .open, createdAt: Date())
        other.ownerKey = store.userKey(userID: 9_101)
        await store.upsertCryptoInvoice(other)

        let again = await deliver(makeService(ledger: InMemoryLedger()), txHash: "0xonce")
        guard case .alreadyCredited = again else {
            return XCTFail("a hash already credited must be recognised, got \(again)")
        }
        let untouched = await store.cryptoInvoice(id: "inv-2")
        XCTAssertEqual(untouched?.status, .open, "nobody else's invoice may be closed by it")
    }

    // MARK: - A rate that is not a rate

    /// The TON quote comes from a third party and is used as a divisor whose
    /// result is narrowed to `Int64`. Zero gives infinity, and narrowing
    /// infinity **traps** — one broken response would take the process down
    /// every time somebody tapped «TON».
    func testAnImplausibleTonRateIsRefusedRatherThanConverted() {
        XCTAssertNil(CryptoPaymentService.tonAtomicPerUsdCentMicro(rate: 0))
        XCTAssertNil(CryptoPaymentService.tonAtomicPerUsdCentMicro(rate: -3))
        XCTAssertNil(CryptoPaymentService.tonAtomicPerUsdCentMicro(rate: .nan))
        XCTAssertNil(CryptoPaymentService.tonAtomicPerUsdCentMicro(rate: .infinity))
        XCTAssertNil(CryptoPaymentService.tonAtomicPerUsdCentMicro(rate: 1e-30))

        // A real quote still converts: at $2.50/TON one cent is 0.004 TON, i.e.
        // 4 000 000 nanoTON — carried here scaled by 10⁶.
        let micro = CryptoPaymentService.tonAtomicPerUsdCentMicro(rate: 2.5)
        XCTAssertEqual(micro, 4_000_000 * 1_000_000)
    }
}
