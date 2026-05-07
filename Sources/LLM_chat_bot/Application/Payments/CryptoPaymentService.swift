import Foundation

enum CryptoPaymentError: LocalizedError {
    case priceNotSet
    case addressNotSet(CryptoChain)
    case poolExhausted(CryptoChain)
    case rateUnavailable(String)
    case unknownInvoice
    case invoiceExpired

    var errorDescription: String? {
        switch self {
        case .priceNotSet: return "Цена в USDT не настроена."
        case .addressNotSet(let chain): return "Адрес для \(chain.displayName) не настроен."
        case .poolExhausted(let chain): return "Все адреса \(chain.displayName) заняты. Попробуйте позже или выберите другую сеть."
        case .rateUnavailable(let symbol): return "Не удалось получить курс для \(symbol)."
        case .unknownInvoice: return "Счёт не найден."
        case .invoiceExpired: return "Счёт истёк."
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

    private var tonUsdRate: Double? = nil
    private var tonRateFetchedAt: Date? = nil
    private static let rateTTLSeconds: TimeInterval = 300
    private static let invoiceExpirySeconds: TimeInterval = 30 * 60

    init(state: ChatContextStore, network: NetworkClient, telegram: TelegramGatewayPort, logger: LoggerPort) {
        self.state = state
        self.network = network
        self.telegram = telegram
        self.logger = logger
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

    func createOrRefreshInvoice(username: String, userChatID: Int, asset: CryptoAsset) async throws -> CryptoInvoice {
        guard let priceCents = await state.cryptoPriceUsdCents() else {
            throw CryptoPaymentError.priceNotSet
        }

        let normalizedUser = username.lowercased()

        if let existing = await state.openCryptoInvoiceForUser(username: normalizedUser, asset: asset),
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
            var picked: Int = 0
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
            slot = picked
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
            username: normalizedUser,
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
            slotOffset: slot
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

        // 1) Exact amount match against an open invoice
        if let exact = openInvoices
            .filter({ $0.status == .open && $0.exactAmountAtomic == amountAtomic })
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

        // 3) Adopt oldest unlinked open invoice if amount within reasonable bounds
        if let candidate = openInvoices
            .filter({ $0.status == .open && $0.linkedSenders.isEmpty && amountAtomic <= $0.exactAmountAtomic })
            .sorted(by: { $0.createdAt < $1.createdAt })
            .first {
            return await applyMatch(
                invoice: candidate,
                addedAtomic: amountAtomic,
                fromAddress: fromAddress,
                txHash: txHash,
                isExact: false
            )
        }

        logger.info("crypto: orphan transfer \(asset.rawValue) amount=\(amountAtomic) tx=\(txHash)")
        return .unmatched
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
            await state.registerTenant(username: copy.username)
            await notifyFullPayment(copy)
            return .fullyPaid(copy)
        } else {
            copy.status = .partial
            await state.upsertCryptoInvoice(copy)
            let remaining = copy.exactAmountAtomic - copy.accumulatedAtomic
            await notifyPartialPayment(copy, addedAtomic: addedAtomic, remainingAtomic: remaining)
            return .partial(invoice: copy, addedAtomic: addedAtomic, remainingAtomic: remaining)
        }
    }

    // MARK: - Notifications

    private func notifyFullPayment(_ invoice: CryptoInvoice) async {
        let amount = CryptoAmountFormatter.format(atomic: invoice.exactAmountAtomic, decimals: invoice.asset.decimals)
        let text = """
        ✅ <b>Оплата получена!</b>

        Принято: <b>\(amount) \(invoice.asset.symbol)</b> (\(invoice.asset.displayLabel))

        Добро пожаловать, @\(invoice.username)! Ваша персональная копия бота активирована.
        Используйте /menu для настройки или просто начните общение.
        """
        _ = try? await telegram.sendMessage(.init(
            chatID: invoice.userChatID,
            threadID: nil,
            replyTo: nil,
            text: text,
            replyMarkup: nil
        ))
        logger.info("crypto: invoice \(invoice.id) fully paid by @\(invoice.username) [\(invoice.asset.rawValue)]")
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
