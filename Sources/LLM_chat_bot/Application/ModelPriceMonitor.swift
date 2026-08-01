import Foundation

actor ModelPriceMonitor {
    private let network: NetworkClient
    private let apiKey: String
    private let state: ChatContextStore
    private let telegram: TelegramGatewayPort
    private let logger: LoggerPort

    private static let checkIntervalNanos: UInt64 = 5 * 60 * 1_000_000_000

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
        do {
            let response = try await fetchOpenRouterModels()
            await state.updateOpenRouterModelPrices(buildPriceMap(from: response))
            await state.updateOpenRouterFreeModelIDs(Set(response.data.filter { $0.isFree }.map { $0.id }))
        } catch {
            logger.error("ModelPriceMonitor: on-demand price fetch failed: \(error)")
        }
    }

    private func buildPriceMap(from response: OpenRouterModelsResponse) -> [String: ModelPriceInfo] {
        response.data.reduce(into: [:]) { dict, model in
            guard let p = model.pricing,
                  let input = Double(p.prompt),
                  let output = Double(p.completion) else { return }
            dict[model.id] = ModelPriceInfo(inputPerToken: input, outputPerToken: output)
        }
    }

    private func checkPriceChanges() async {
        do {
            let response = try await fetchOpenRouterModels()
            await state.updateOpenRouterModelPrices(buildPriceMap(from: response))
            let newFreeSet = Set(response.data.filter { $0.isFree }.map { $0.id })

            let previousFreeSet = await state.openRouterFreeModelIDs()

            // First run: just seed the cache, no notifications
            guard let previousFreeSet else {
                await state.updateOpenRouterFreeModelIDs(newFreeSet)
                logger.info("ModelPriceMonitor: initial cache seeded, \(newFreeSet.count) free models on OpenRouter")
                return
            }

            let allTracked = await state.allTrackedModelIDs()
            let pinnedModels = Set(await state.freeModelIDs())

            // Models tracked in our system that were free last cycle and are now paid
            let becamePaid = previousFreeSet.subtracting(newFreeSet).intersection(allTracked)

            for modelID in becamePaid {
                if pinnedModels.contains(modelID) {
                    // Superadmin explicitly pinned — notify superadmin only, don't touch access
                    logger.info("ModelPriceMonitor: \(modelID) became paid on OpenRouter (pinned by superadmin, notifying superadmin)")
                    let superAdminChats = await state.superAdminPrivateChats()
                    for chatKey in superAdminChats {
                        _ = try? await telegram.sendMessage(.init(
                            chatID: chatKey.chatID,
                            threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                            replyTo: nil,
                            text: "ℹ️ <b>Модель стала платной на OpenRouter</b>\n\n<code>\(modelID)</code> теперь требует оплату, но вы закрепили её в бесплатном списке — она остаётся доступной.\n\nЕсли это нежелательно: <code>/tenant freemodels remove \(modelID)</code>",
                            replyMarkup: nil
                        ))
                    }
                } else {
                    // Not pinned — OpenRouter cache update restricts access automatically; notify active chats
                    let affectedChats = await state.chatsUsing(model: modelID)
                    logger.info("ModelPriceMonitor: \(modelID) became paid on OpenRouter, notifying \(affectedChats.count) active chats")
                    for chatKey in affectedChats {
                        _ = try? await telegram.sendMessage(.init(
                            chatID: chatKey.chatID,
                            threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                            replyTo: nil,
                            text: "⚠️ <b>Модель стала платной</b>\n\n<code>\(modelID)</code> теперь требует оплату на OpenRouter.\n\nЕсли у чата есть премиум или баланс — ничего не меняется, ответы идут на ней. Без них она доступна в пределах дневной порции умных ответов, а когда порция закончится, бот переключится на бесплатную модель.",
                            replyMarkup: nil
                        ))
                    }
                }
            }

            if newFreeSet != previousFreeSet {
                await state.updateOpenRouterFreeModelIDs(newFreeSet)
            }
        } catch {
            logger.error("ModelPriceMonitor: price check failed: \(error)")
        }
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
