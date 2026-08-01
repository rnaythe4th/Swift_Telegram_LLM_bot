import Foundation

enum CryptoPaymentError: LocalizedError {
    case priceNotSet
    case addressNotSet(CryptoChain)
    case poolExhausted(CryptoChain)
    case slotsExhausted(CryptoAsset)
    case rateUnavailable(String)
    case unknownInvoice
    case invoiceExpired

    var errorDescription: String? {
        switch self {
        case .priceNotSet: return "Оплата криптой пока не настроена — выберите другой способ."
        case .addressNotSet(let chain): return "Оплата через \(chain.displayName) пока недоступна — выберите другую сеть."
        case .poolExhausted(let chain): return "Все адреса \(chain.displayName) сейчас заняты. Попробуйте через несколько минут или выберите другую сеть."
        case .slotsExhausted(let asset): return "Все счета в \(asset.symbol) сейчас заняты. Попробуйте через несколько минут или выберите другую монету."
        case .rateUnavailable(let symbol): return "Не удалось узнать текущий курс \(symbol). Попробуйте ещё раз или выберите другую монету."
        case .unknownInvoice: return "Счёт не найден — создайте новый: /buy"
        case .invoiceExpired: return "Срок счёта истёк — создайте новый: /buy"
        }
    }
}

enum CryptoApplyResult: Sendable {
    case fullyPaid(CryptoInvoice)
    case partial(invoice: CryptoInvoice, addedAtomic: Int64, remainingAtomic: Int64)
    case alreadyCredited
    case unmatched
}

actor CryptoPaymentService {
    private let state: ChatContextStore
    private let network: NetworkClient
    private let logger: LoggerPort
    private let telegram: TelegramGatewayPort
    /// Payments are written through immediately, never on the 2s debounce: the
    /// chain has already moved the money, so a SIGTERM in that window would
    /// leave a paid invoice with no subscription and no credited tx hash.
    private let persistence: PersistenceCoordinator?
    /// What a completed payment buys, shared with every other payment method
    /// (§17) — activation, wallet, funnel, referral bonus, traffic attribution
    /// and the write-through flush.
    private let fulfillment: PaymentFulfillmentService

    private var tonUsdRate: Double? = nil
    private var tonRateFetchedAt: Date? = nil
    private static let rateTTLSeconds: TimeInterval = 300
    private static let invoiceExpirySeconds: TimeInterval = 30 * 60

    init(
        state: ChatContextStore,
        network: NetworkClient,
        telegram: TelegramGatewayPort,
        logger: LoggerPort,
        fulfillment: PaymentFulfillmentService,
        persistence: PersistenceCoordinator? = nil
    ) {
        self.state = state
        self.network = network
        self.telegram = telegram
        self.logger = logger
        self.fulfillment = fulfillment
        self.persistence = persistence
    }

    // MARK: - Configuration helpers

    func availableAssets() async -> [CryptoAsset] {
        let mode = await state.cryptoMatchMode()
        switch mode {
        case .amountDelta:
            let addrs = await state.cryptoAddresses()
            return CryptoAsset.allCases.filter { addrs[$0.chain] != nil }
        case .uniqueAddress:
            let pools = await state.cryptoAddressPools()
            return CryptoAsset.allCases.filter { !(pools[$0.chain]?.isEmpty ?? true) }
        }
    }

    // MARK: - Invoice creation

    func createOrRefreshInvoice(
        invoker: UserKey,
        userChatID: ChatID,
        asset: CryptoAsset,
        purpose: CryptoInvoicePurpose = .subscription
    ) async throws -> CryptoInvoice {
        // Subscription uses the admin-set crypto price; a credit pack is priced
        // at its own USD face value.
        let priceCents: Int
        switch purpose {
        case .subscription:
            // Winback offers discount the subscription price (roadmap step 8);
            // credit packs always cost their face value.
            guard let sub = await state.subscriptionPricing(key: invoker).cryptoCents else {
                throw CryptoPaymentError.priceNotSet
            }
            priceCents = sub
        case .credit(let cents):
            priceCents = cents
        }

        // Invoices are filed under the payer's storage key, so a rename
        // between opening and paying still credits the right wallet.
        let normalizedUser = await state.resolved(invoker)

        // Note (amountDelta mode): slot allocation keeps every open invoice's
        // amount unique across all purposes, so a payment attributes to one
        // invoice. Distinct pack prices sit far outside the slot-step range of
        // the subscription price, so purposes don't alias in practice.
        if let existing = await state.openCryptoInvoiceForUser(key: normalizedUser, asset: asset, purpose: purpose),
           existing.expiresAt > Date() {
            return existing
        }

        let rateMicro = try await atomicPerUsdCentMicro(asset: asset)
        let baseAmount = (Int64(priceCents) * rateMicro) / 1_000_000

        let mode = await state.cryptoMatchMode()
        let receivingAddress: String
        let exactAmount: Int64
        let slot: Int

        switch mode {
        case .amountDelta:
            guard let address = await state.cryptoAddress(asset.chain) else {
                throw CryptoPaymentError.addressNotSet(asset.chain)
            }
            receivingAddress = address

            let usedSlots = await state.usedSlots(asset: asset)
            var picked: Int? = nil
            var attempts = 0
            let maxSlots = asset.maxConcurrentSlots
            while attempts < maxSlots {
                let candidate = await state.nextCryptoSlot(asset: asset)
                if !usedSlots.contains(candidate) {
                    picked = candidate
                    break
                }
                attempts += 1
            }
            // Falling back to slot 0 here would hand two open invoices the same
            // exact amount, and the exact-match branch would credit whichever
            // was created first — one person's money closing another person's
            // invoice, with nothing in the logs. Refuse instead.
            guard let freeSlot = picked else {
                throw CryptoPaymentError.slotsExhausted(asset)
            }
            slot = freeSlot
            exactAmount = baseAmount + Int64(slot) * asset.atomicSlotStep

        case .uniqueAddress:
            guard let address = await state.nextFreePoolAddress(chain: asset.chain) else {
                throw CryptoPaymentError.poolExhausted(asset.chain)
            }
            receivingAddress = address
            exactAmount = baseAmount
            slot = 0
        }

        let now = Date()
        let invoice = CryptoInvoice(
            id: UUID().uuidString,
            ownerKey: normalizedUser,
            userChatID: userChatID,
            asset: asset,
            receivingAddress: receivingAddress,
            exactAmountAtomic: exactAmount,
            accumulatedAtomic: 0,
            quotedPriceUsdCents: priceCents,
            rateAtomicPerUsdCentMicro: rateMicro,
            createdAt: now,
            expiresAt: now.addingTimeInterval(Self.invoiceExpirySeconds),
            status: .open,
            linkedSenders: [],
            creditedTxHashes: [],
            slotOffset: slot,
            purpose: purpose
        )

        await state.upsertCryptoInvoice(invoice)
        return invoice
    }

    func cancelInvoice(id: String) async {
        await state.cancelCryptoInvoice(id: id)
    }

    func sweepExpired() async {
        let expired = await state.expireDueCryptoInvoices()
        for inv in expired {
            await notifyExpired(inv)
        }
    }

    // MARK: - Rate handling

    private func atomicPerUsdCentMicro(asset: CryptoAsset) async throws -> Int64 {
        switch asset {
        case .usdtBsc, .usdtEth, .usdtTrx, .usdtTon:
            // 1 USDT = 100 cents = 1_000_000 atomic; per cent = 10_000; * 1_000_000 micro = 10_000_000_000
            return 10_000_000_000
        case .tonNative:
            let rate = try await fetchTonUsdRate()
            // atomicPerCent = 10_000_000 / rate; * 1_000_000 micro
            let micro = 10_000_000_000_000.0 / rate
            return Int64(micro.rounded())
        }
    }

    private func fetchTonUsdRate() async throws -> Double {
        if let r = tonUsdRate, let t = tonRateFetchedAt, Date().timeIntervalSince(t) < Self.rateTTLSeconds {
            return r
        }
        let spec = HTTPRequestSpec(
            url: "https://api.coingecko.com/api/v3/simple/price?ids=the-open-network&vs_currencies=usd",
            method: .get,
            timeoutSeconds: 15
        )
        struct CoinGeckoResp: Decodable {
            struct Entry: Decodable { let usd: Double }
            let theOpenNetwork: Entry
            enum CodingKeys: String, CodingKey { case theOpenNetwork = "the-open-network" }
        }
        do {
            let resp = try await network.send(spec, as: CoinGeckoResp.self)
            tonUsdRate = resp.theOpenNetwork.usd
            tonRateFetchedAt = Date()
            return resp.theOpenNetwork.usd
        } catch {
            logger.error("CoinGecko TON rate fetch failed: \(error)")
            if let r = tonUsdRate { return r }
            throw CryptoPaymentError.rateUnavailable("TON")
        }
    }

    // MARK: - Incoming transfer matching

    func applyIncomingTransfer(
        asset: CryptoAsset,
        amountAtomic: Int64,
        fromAddress: String?,
        recipientAddress: String,
        txHash: String,
        timestamp: Date
    ) async -> CryptoApplyResult {
        await sweepExpired()

        let openInvoices = await state.openCryptoInvoices(asset: asset)
        if openInvoices.contains(where: { $0.creditedTxHashes.contains(txHash) }) {
            return .alreadyCredited
        }

        let mode = await state.cryptoMatchMode()

        if mode == .uniqueAddress {
            // Address-keyed match: only invoices on this exact address apply.
            let recipKey = recipientAddress.lowercased()
            let candidates = openInvoices
                .filter { $0.receivingAddress.lowercased() == recipKey }
                .sorted { $0.createdAt < $1.createdAt }
            guard let invoice = candidates.first else {
                logger.info("crypto: orphan unique-addr transfer \(asset.rawValue) addr=\(recipientAddress) tx=\(txHash)")
                return .unmatched
            }
            return await applyMatch(
                invoice: invoice,
                addedAtomic: amountAtomic,
                fromAddress: fromAddress,
                txHash: txHash,
                isExact: amountAtomic >= invoice.exactAmountAtomic
            )
        }

        // amountDelta mode

        // 1) Exact match against what an invoice is still owed.
        //
        // Against `remainingAtomic`, not `exactAmountAtomic`, and across
        // `.partial` as well as `.open`: the invoice tells the payer «осталось
        // доплатить X», so a transfer of exactly X is the least ambiguous
        // signal there is. Matching only untouched invoices meant a single
        // stray unit landing on someone's invoice flipped it to `.partial` and
        // their real, exact-amount payment then matched nothing at all.
        if let exact = openInvoices
            .filter({ $0.remainingAtomic == amountAtomic })
            .sorted(by: { $0.createdAt < $1.createdAt })
            .first {
            return await applyMatch(
                invoice: exact,
                addedAtomic: amountAtomic,
                fromAddress: fromAddress,
                txHash: txHash,
                isExact: true
            )
        }

        // 2) Sender-linked invoice (continuation of partial payment)
        if let from = fromAddress {
            if let linked = openInvoices
                .filter({ $0.linkedSenders.contains(from.lowercased()) })
                .sorted(by: { $0.createdAt < $1.createdAt })
                .first {
                return await applyMatch(
                    invoice: linked,
                    addedAtomic: amountAtomic,
                    fromAddress: fromAddress,
                    txHash: txHash,
                    isExact: false
                )
            }
        }

        // 3) Adopt an unlinked invoice — but only for a payment large enough to
        // be a genuine attempt at it.
        //
        // Adopting *any* amount let one dust transfer attach an arbitrary
        // sender to a stranger's invoice and park it in `.partial`; from there
        // every further transfer from that address (step 2) went to the
        // stranger's invoice too. Requiring at least half the outstanding
        // amount prices the attack above the subscription it targets, and the
        // closest invoice wins rather than the oldest, so a real underpayment
        // still lands where the payer meant it to.
        let adoptable = openInvoices.filter {
            $0.linkedSenders.isEmpty
                && amountAtomic <= $0.remainingAtomic
                && amountAtomic >= Self.minimumAdoptableShare(of: $0.remainingAtomic)
        }
        if let candidate = adoptable.min(by: {
            let lhs = $0.remainingAtomic - amountAtomic
            let rhs = $1.remainingAtomic - amountAtomic
            return lhs == rhs ? $0.createdAt < $1.createdAt : lhs < rhs
        }) {
            return await applyMatch(
                invoice: candidate,
                addedAtomic: amountAtomic,
                fromAddress: fromAddress,
                txHash: txHash,
                isExact: false
            )
        }

        // Money arrived and nothing was credited for it — the operator has to be
        // able to find this without going looking, so it is not an info line.
        logger.warning("crypto: orphan transfer \(asset.rawValue) amount=\(amountAtomic) from=\(fromAddress ?? "?") tx=\(txHash)")
        return .unmatched
    }

    /// Smallest transfer that may claim an invoice it is not linked to. Half of
    /// what the invoice is still owed: enough headroom for network fees eaten
    /// off a real payment, far too expensive to spray at strangers' invoices.
    private static func minimumAdoptableShare(of remainingAtomic: Int64) -> Int64 {
        max(1, remainingAtomic / 2)
    }

    private func applyMatch(
        invoice: CryptoInvoice,
        addedAtomic: Int64,
        fromAddress: String?,
        txHash: String,
        isExact: Bool
    ) async -> CryptoApplyResult {
        var copy = invoice
        copy.accumulatedAtomic += addedAtomic
        copy.creditedTxHashes.append(txHash)
        if let from = fromAddress?.lowercased(),
           !copy.linkedSenders.contains(from) {
            copy.linkedSenders.append(from)
        }

        if copy.accumulatedAtomic >= copy.exactAmountAtomic {
            copy.status = .paid
            await state.upsertCryptoInvoice(copy)
            // Everything a payment buys happens in one place, so this path
            // cannot drift from the Telegram and hosted-checkout ones: the
            // chain has already moved the money, and `fulfil` flushes before
            // returning (CLAUDE.md §7, §17).
            let outcome = await fulfillment.fulfil(PaymentReceipt(
                payerKey: copy.ownerKey,
                // Invoices are filed under a `UserKey`; a pending record (a
                // person the bot has only been told about) carries no userID,
                // and referral/traffic attribution then has nothing to look up.
                payerUserID: copy.ownerKey.userID,
                chatID: copy.userChatID,
                purpose: copy.resolvedPurpose,
                idempotencyKey: "crypto:\(txHash)",
                method: .crypto
            ))
            switch outcome {
            case .duplicate, .failed:
                // Nothing was applied and nothing was claimed: the poller sees
                // this transfer again on its next pass and tries once more.
                break
            case .subscription(let activation, let claim):
                await notifyFullPayment(copy, activation: activation, claim: claim)
            case .credit(let cents, let wallet):
                await notifyCreditPayment(copy, cents: cents, balance: wallet.balance)
            }
            return .fullyPaid(copy)
        } else {
            copy.status = .partial
            await state.upsertCryptoInvoice(copy)
            // A partial payment is received money too: losing the accumulator
            // means asking the payer for the full amount a second time.
            await persistence?.flushNow()
            let remaining = copy.exactAmountAtomic - copy.accumulatedAtomic
            await notifyPartialPayment(copy, addedAtomic: addedAtomic, remainingAtomic: remaining)
            return .partial(invoice: copy, addedAtomic: addedAtomic, remainingAtomic: remaining)
        }
    }

    // MARK: - Notifications

    private func notifyFullPayment(
        _ invoice: CryptoInvoice,
        activation: SubscriptionActivation,
        claim: ChatContextStore.ChatClaimOutcome
    ) async {
        // The invoice carries the payer's storage key; the notice names them.
        let payerLabel = await state.displayLabel(forKey: invoice.ownerKey)
        let amount = CryptoAmountFormatter.format(atomic: invoice.exactAmountAtomic, decimals: invoice.asset.decimals)
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy"
        let isGroup = invoice.userChatID.isGroup
        let subscriptionLine: String
        // The group is still paid for by someone else — say so instead of
        // crediting the payer with access they did not open here.
        if case .keptSponsor(let sponsor) = claim {
            let text = """
            ✅ <b>Оплата получена!</b>

            Принято: <b>\(amount) \(invoice.asset.symbol)</b> (\(invoice.asset.displayLabel))

            \(payerLabel), премиум-доступ активирован для вас — в личке с ботом и в ваших чатах.
            Здесь премиум уже открыл \(sponsor) — этот чат остаётся за ним.
            """
            _ = try? await telegram.sendMessage(.init(
                chatID: invoice.userChatID,
                threadID: nil,
                replyTo: nil,
                text: text,
                replyMarkup: nil
            ))
            logger.info("crypto: invoice \(invoice.id) paid by \(payerLabel); chat \(invoice.userChatID) kept by sponsor \(sponsor)")
            return
        }
        switch activation {
        case .started(let until):
            subscriptionLine = isGroup
                ? "🎉 \(payerLabel) открыл премиум-доступ для этого чата — теперь всем доступны умные модели без рекламы."
                : "Добро пожаловать, \(payerLabel)! Премиум-доступ активирован, подписка до <b>\(formatter.string(from: until))</b>."
        case .extended(let until):
            subscriptionLine = isGroup
                ? "🎉 \(payerLabel) продлил премиум-доступ для этого чата."
                : "Подписка \(payerLabel) продлена до <b>\(formatter.string(from: until))</b>."
        case .alreadyUnlimited:
            subscriptionLine = "У \(payerLabel) бессрочный доступ."
        }
        let text = """
        ✅ <b>Оплата получена!</b>

        Принято: <b>\(amount) \(invoice.asset.symbol)</b> (\(invoice.asset.displayLabel))

        \(subscriptionLine)
        Используйте /menu для настройки или просто начните общение.
        """
        _ = try? await telegram.sendMessage(.init(
            chatID: invoice.userChatID,
            threadID: nil,
            replyTo: nil,
            text: text,
            replyMarkup: nil
        ))
        logger.info("crypto: invoice \(invoice.id) fully paid by \(invoice.ownerKey) [\(invoice.asset.rawValue)]")
    }

    private func notifyCreditPayment(_ invoice: CryptoInvoice, cents: Int, balance: Money) async {
        let amount = CryptoAmountFormatter.format(atomic: invoice.exactAmountAtomic, decimals: invoice.asset.decimals)
        let text = """
        ✅ <b>Баланс пополнен на \(CreditPack.label(cents: cents))!</b>

        Принято: <b>\(amount) \(invoice.asset.symbol)</b> (\(invoice.asset.displayLabel))
        Текущий баланс: <b>\(balance.formatted(fractionDigits: 2))</b>

        Теперь вам доступны любые модели: с баланса списывается стоимость каждого ответа, обычно доли цента. Сколько списалось и сколько осталось — видно под самим ответом (включите показ: /show_cost).
        """
        _ = try? await telegram.sendMessage(.init(
            chatID: invoice.userChatID,
            threadID: nil,
            replyTo: nil,
            text: text,
            replyMarkup: nil
        ))
        logger.info("crypto: credit invoice \(invoice.id) fully paid by \(invoice.ownerKey) +\(cents)c [\(invoice.asset.rawValue)]")
    }

    private func notifyPartialPayment(_ invoice: CryptoInvoice, addedAtomic: Int64, remainingAtomic: Int64) async {
        let added = CryptoAmountFormatter.format(atomic: addedAtomic, decimals: invoice.asset.decimals)
        let remaining = CryptoAmountFormatter.format(atomic: remainingAtomic, decimals: invoice.asset.decimals)
        let total = CryptoAmountFormatter.format(atomic: invoice.exactAmountAtomic, decimals: invoice.asset.decimals)
        let text = """
        ⚠️ <b>Оплата частичная</b>

        Зачислено: <b>\(added) \(invoice.asset.symbol)</b>
        Ожидалось: <b>\(total) \(invoice.asset.symbol)</b>
        Осталось доплатить: <b>\(remaining) \(invoice.asset.symbol)</b>

        Отправьте недостающую сумму на тот же адрес:
        <code>\(invoice.receivingAddress)</code>
        """
        _ = try? await telegram.sendMessage(.init(
            chatID: invoice.userChatID,
            threadID: nil,
            replyTo: nil,
            text: text,
            replyMarkup: nil
        ))
    }

    private func notifyExpired(_ invoice: CryptoInvoice) async {
        guard invoice.accumulatedAtomic > 0 else { return }
        let received = CryptoAmountFormatter.format(atomic: invoice.accumulatedAtomic, decimals: invoice.asset.decimals)
        let expected = CryptoAmountFormatter.format(atomic: invoice.exactAmountAtomic, decimals: invoice.asset.decimals)
        let text = """
        ⌛ <b>Счёт истёк</b>

        Получено: <b>\(received) \(invoice.asset.symbol)</b>
        Ожидалось: <b>\(expected) \(invoice.asset.symbol)</b>

        Создайте новый счёт командой /buy или обратитесь к администратору для решения вопроса с зачислением.
        """
        _ = try? await telegram.sendMessage(.init(
            chatID: invoice.userChatID,
            threadID: nil,
            replyTo: nil,
            text: text,
            replyMarkup: nil
        ))
    }
}
