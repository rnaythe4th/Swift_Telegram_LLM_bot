import Foundation

/// Why a catalogue reading was refused. Its own error rather than an empty
/// result, so a caller cannot mistake "the upstream said nothing" for "the
/// upstream said there is nothing".
enum ModelCatalogueError: Error, CustomStringConvertible {
    case empty

    var description: String {
        switch self {
        case .empty: return "OpenRouter returned an empty model catalogue"
        }
    }
}

/// One reading of the OpenRouter catalogue, as a value that has already been
/// judged.
///
/// Pure on purpose. "An empty catalogue is an outage, not the news that every
/// free model became paid" is a product rule with money behind it, and a rule
/// that can only be exercised by pointing the bot at openrouter.ai is a rule
/// nobody checks. Believing an empty reading would empty
/// `openRouterFreeModelIDs`, and then every free-tier chat starts spending its
/// daily premium allowance on a model that costs nothing — while being told the
/// model "стала платной".
struct ModelCatalogueReading: Sendable {
    let freeModelIDs: Set<String>
    let prices: [String: ModelPriceInfo]

    init(_ response: OpenRouterModelsResponse) throws {
        guard !response.data.isEmpty else { throw ModelCatalogueError.empty }
        freeModelIDs = Set(response.data.filter(\.isFree).map(\.id))
        prices = response.data.reduce(into: [:]) { dict, model in
            guard let p = model.pricing,
                  let input = Double(p.prompt),
                  let output = Double(p.completion) else { return }
            dict[model.id] = ModelPriceInfo(inputPerToken: input, outputPerToken: output)
        }
    }

    /// Models somebody is actually using that were free in the previous reading
    /// and are not any more. Sorted, because the notifications that follow are
    /// side effects and an arbitrary `Set` order makes them unreproducible.
    func modelsThatBecamePaid(previouslyFree: Set<String>, tracked: Set<String>) -> [String] {
        previouslyFree.subtracting(freeModelIDs).intersection(tracked).sorted()
    }
}

actor ModelPriceMonitor {
    private let network: NetworkClient
    private let apiKey: String
    private let state: ChatContextStore
    private let telegram: TelegramGatewayPort
    private let logger: LoggerPort

    private static let checkIntervalNanos: UInt64 = 5 * 60 * 1_000_000_000
    /// A model that flips free → paid → free (OpenRouter does exactly this with
    /// `:free` variants) must not re-broadcast to every chat using it every
    /// five minutes. Access follows the catalogue immediately; only the talking
    /// about it is rationed.
    private static let noticeCooldown: TimeInterval = 24 * 3600
    /// A catalogue fetch is a megabyte of JSON. On-demand refreshes are driven
    /// by whatever model id a person just typed, so a model that is simply not
    /// on OpenRouter (a DeepSeek id, a typo) would otherwise re-fetch the whole
    /// catalogue on every attempt.
    private static let onDemandCooldown: TimeInterval = 60

    private var paidNotices = AnnouncementThrottle<String>(interval: ModelPriceMonitor.noticeCooldown)
    private var onDemandFetches = AnnouncementThrottle<String>(interval: ModelPriceMonitor.onDemandCooldown)

    init(
        network: NetworkClient,
        apiKey: String,
        state: ChatContextStore,
        telegram: TelegramGatewayPort,
        logger: LoggerPort
    ) {
        self.network = network
        self.apiKey = apiKey
        self.state = state
        self.telegram = telegram
        self.logger = logger
    }

    func fetchCurrentFreeModels() async throws -> [OpenRouterModelInfo] {
        let response = try await fetchOpenRouterModels()
        return response.data.filter { $0.isFree }
    }

    func performInitialFetch() async {
        await checkPriceChanges()
    }

    func run() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: Self.checkIntervalNanos)
            guard !Task.isCancelled else { return }
            await checkPriceChanges()
        }
    }

    func refreshPricesIfNeeded(for modelID: String) async {
        if await state.openRouterModelPrice(for: modelID) != nil { return }
        guard onDemandFetches.claim(modelID) else { return }
        do {
            let reading = try ModelCatalogueReading(try await fetchOpenRouterModels())
            await state.updateOpenRouterModelPrices(reading.prices)
            await state.updateOpenRouterFreeModelIDs(reading.freeModelIDs)
        } catch {
            logger.error("ModelPriceMonitor: on-demand price fetch failed: \(error)")
        }
    }

    private func checkPriceChanges() async {
        do {
            let reading = try ModelCatalogueReading(try await fetchOpenRouterModels())
            await state.updateOpenRouterModelPrices(reading.prices)

            let previousFreeSet = await state.openRouterFreeModelIDs()

            // First run: just seed the cache, no notifications
            guard let previousFreeSet else {
                await state.updateOpenRouterFreeModelIDs(reading.freeModelIDs)
                logger.info("ModelPriceMonitor: initial cache seeded, \(reading.freeModelIDs.count) free models on OpenRouter")
                return
            }

            let becamePaid = reading.modelsThatBecamePaid(
                previouslyFree: previousFreeSet,
                tracked: await state.allTrackedModelIDs()
            )
            let pinnedModels = Set(await state.freeModelIDs())

            for modelID in becamePaid {
                // The access change below is unconditional; the announcement is
                // what the cooldown holds back.
                guard paidNotices.claim(modelID) else {
                    logger.info("ModelPriceMonitor: \(modelID) became paid again within the notice cooldown, staying quiet")
                    continue
                }
                if pinnedModels.contains(modelID) {
                    await announcePinnedModelBecamePaid(modelID)
                } else {
                    await announceModelBecamePaid(modelID)
                }
            }

            if reading.freeModelIDs != previousFreeSet {
                await state.updateOpenRouterFreeModelIDs(reading.freeModelIDs)
            }
        } catch {
            // The previously known free set stays in place: a stale answer to
            // "is this model free" is survivable, a wrong one is not.
            logger.error("ModelPriceMonitor: price check failed: \(error)")
        }
    }

    /// Pinned by the super-admin — access does not change, so only they hear
    /// about it.
    private func announcePinnedModelBecamePaid(_ modelID: String) async {
        logger.info("ModelPriceMonitor: \(modelID) became paid on OpenRouter (pinned by superadmin, notifying superadmin)")
        let name = MessageText.escaped(modelID)
        for chatKey in await state.superAdminPrivateChats() {
            await notify(
                chatKey,
                text: "ℹ️ <b>Модель стала платной на OpenRouter</b>\n\n<code>\(name)</code> теперь требует оплату, но вы закрепили её в бесплатном списке — она остаётся доступной.\n\nЕсли это нежелательно: <code>/tenant freemodels remove \(name)</code>"
            )
        }
    }

    /// Not pinned — the catalogue update restricts access by itself, so the
    /// chats running it are told what changed for them.
    private func announceModelBecamePaid(_ modelID: String) async {
        let affectedChats = await state.chatsUsing(model: modelID)
        logger.info("ModelPriceMonitor: \(modelID) became paid on OpenRouter, notifying \(affectedChats.count) active chats")
        let name = MessageText.escaped(modelID)
        for chatKey in affectedChats {
            await notify(
                chatKey,
                text: "⚠️ <b>Модель стала платной</b>\n\n<code>\(name)</code> теперь требует оплату на OpenRouter.\n\nЕсли у чата есть премиум или баланс — ничего не меняется, ответы идут на ней. Без них она доступна в пределах дневной порции умных ответов, а когда порция закончится, бот переключится на бесплатную модель."
            )
        }
    }

    private func notify(_ chatKey: ChatKey, text: String) async {
        _ = try? await telegram.sendMessage(.init(
            chatID: chatKey.chatID,
            threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
            replyTo: nil,
            text: text,
            replyMarkup: nil
        ))
    }

    private func fetchOpenRouterModels() async throws -> OpenRouterModelsResponse {
        let spec = HTTPRequestSpec(
            url: "https://openrouter.ai/api/v1/models",
            method: .get,
            headers: ["Authorization": "Bearer \(apiKey)"],
            timeoutSeconds: 30
        )
        return try await network.send(spec, as: OpenRouterModelsResponse.self)
    }
}
