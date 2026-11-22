import Foundation

enum DeepSeekWebAdmissionRetry: Error {
    case persistence
}

actor DeepSeekWebQueue {
    private struct ActiveRequest {
        let key: ChatKey
        let operationID: UUID
        let request: DeepSeekWebWorkerRequest
        var stopRequested = false
    }

    private let store: ChatContextStore
    private let persistence: PersistenceCoordinator?
    private let gateway: any DeepSeekWebGateway
    private let telegram: any TelegramGatewayPort
    private let flags: RuntimeFlags
    private let logger: any LoggerPort
    private let alerter: OwnerAlerter
    private let metrics: RuntimeMetrics
    private let quotaPause: TimeInterval
    private let remoteUnitLimit: Int
    private var runner: Task<Void, Never>?
    private var activeRequest: ActiveRequest?
    private var inAdmission = 0
    private var deliveries: [ChatKey: Task<TelegramMessage, Error>] = [:]

    private let queueLimit = 16
    private let perChatLimit = 3
    private let queueLifetime: TimeInterval = 180

    init(
        store: ChatContextStore, persistence: PersistenceCoordinator?, gateway: any DeepSeekWebGateway,
        telegram: any TelegramGatewayPort, flags: RuntimeFlags, logger: any LoggerPort,
        alerter: OwnerAlerter, metrics: RuntimeMetrics, quotaPause: Int, remoteUnitLimit: Int
    ) {
        self.store = store
        self.persistence = persistence
        self.gateway = gateway
        self.telegram = telegram
        self.flags = flags
        self.logger = logger
        self.alerter = alerter
        self.metrics = metrics
        self.quotaPause = TimeInterval(quotaPause)
        self.remoteUnitLimit = remoteUnitLimit
    }

    private var canRun: Bool {
        flags.durability.value == .durable && !flags.draining.value
    }

    func hasSeen(updateID: Int) async throws -> Bool {
        guard canRun, let persistence else { return false }
        do {
            let seen = try await persistence.webUpdateSeen(Int64(updateID))
            if seen { start() }
            return seen
        } catch {
            throw DeepSeekWebAdmissionRetry.persistence
        }
    }

    @discardableResult
    func admit(question: String, origin: GenerationOrigin, chatKey: ChatKey) async throws -> Bool {
        guard canRun, let persistence, let updateID = origin.updateID else {
            await notify(Self.message(.unavailable), chatKey, origin.telegramThreadID)
            return false
        }
        guard await store.webAllowed(chatKey: chatKey) else {
            await notify("Попросите администратора включить DeepSeek Web в этом чате через /provider deepseek-web.", chatKey, origin.telegramThreadID)
            return false
        }
        // Count admission calls while awaiting actor and database work.
        inAdmission += 1
        defer { inAdmission -= 1 }
        let items = await store.webOperations()
        guard items.count + inAdmission <= queueLimit,
              items.lazy.filter({ $0.0 == chatKey }).count < perChatLimit else {
            await notify("⏳ Очередь DeepSeek Web заполнена. Попробуйте позже.", chatKey, origin.telegramThreadID)
            return false
        }

        do {
            // Synchronize the account before capturing transcript and role if
            // the worker is up. The runner repeats this check before any send.
            if let health = try? await gateway.health() {
                let account = try await syncAccount(health, with: persistence)
                await store.webResetForAccount(chatKey: chatKey, accountEpoch: account.epoch)
            }
            guard canRun else { throw DeepSeekWebAdmissionRetry.persistence }
            guard let operation = await store.webCandidate(
                chatKey: chatKey, operationID: UUID(), updateID: Int64(updateID),
                question: question, messageID: origin.askedMessageID ?? 0,
                telegramThreadID: origin.telegramThreadID, reply: origin.repliedTo,
                replyToMessageID: origin.replyToMessageID, asker: origin.userKey
            ) else { return false }
            let inserted = try await persistence.webAdmit(chatKey: chatKey, operation: operation)
            start()
            return inserted
        } catch {
            throw DeepSeekWebAdmissionRetry.persistence
        }
    }

    func start() {
        guard canRun, runner == nil else { return }
        runner = Task { await drain() }
    }

    func stop() async {
        runner?.cancel()
        await runner?.value
    }

    func cancel(generationID: GenerationID, chatKey: ChatKey) async -> Bool {
        guard let activeRequest, activeRequest.key == chatKey, activeRequest.operationID == generationID.raw,
              !activeRequest.stopRequested else { return false }
        self.activeRequest?.stopRequested = true
        _ = try? await gateway.perform(.cancel, activeRequest.request)
        return true
    }

    func waitForDelivery(chatKey: ChatKey) async {
        _ = try? await deliveries[chatKey]?.value
    }

    private func drain() async {
        defer { runner = nil }
        guard let persistence else { return }
        while canRun, !Task.isCancelled {
            guard let (key, operation) = await store.webOperations().first else {
                // A successful admission may have happened while awaiting the
                // snapshot. It calls start after it commits.
                if inAdmission == 0 { return }
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            do {
                try await process(key, operation, persistence: persistence)
            } catch DeepSeekWebPersistenceError.superseded {
                continue
            } catch {
                if !canRun || Task.isCancelled { return }
                logger.warning("DeepSeek Web checkpoint failed for operation \(operation.id)")
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func syncAccount(
        _ health: DeepSeekWebWorkerHealth, with persistence: PersistenceCoordinator
    ) async throws -> DeepSeekWebAccount {
        try await persistence.webAccount(workerMarker: health.accountMarker)
    }

    private func process(
        _ key: ChatKey, _ operation: DeepSeekWebOperation, persistence: PersistenceCoordinator
    ) async throws {
        let workerHealth = try? await gateway.health()
        let account: DeepSeekWebAccount
        if let workerHealth {
            account = try await syncAccount(workerHealth, with: persistence)
        } else {
            account = try await persistence.webAccount()
        }
        guard let state = await store.webState(chatKey: key),
              state.contextEpoch == operation.contextEpoch, canRun else { return }
        if let epoch = state.accountEpoch, epoch != account.epoch {
            await store.webResetForAccount(chatKey: key, accountEpoch: account.epoch)
            if let newState = await store.webState(chatKey: key) {
                try await persistence.webCheckpoint(chatKey: key, contextEpoch: newState.contextEpoch)
            }
            return
        }

        switch operation.stage {
        case .confirmed, .delivering:
            // Recheck the account marker before publishing a response after a
            // restart. An unavailable worker leaves the confirmed result saved.
            guard workerHealth?.status == .ready else { throw DeepSeekWebPersistenceError.unavailable }
            try await persistence.webCheckpoint(chatKey: key, contextEpoch: operation.contextEpoch)
            try await deliver(operation, key: key, persistence: persistence)
        case .sending:
            guard let workerHealth, workerHealth.status == .ready else {
                throw DeepSeekWebPersistenceError.unavailable
            }
            let request = request(for: operation, account: account)
            let result = try await reconcile(request, candidateRemoteChatID: operation.candidateRemoteChatID)
            try await consume(result, key, operation, account: account, persistence: persistence)
        case .queued:
            guard Date().timeIntervalSince(operation.createdAt) <= queueLifetime else {
                try await fail("⏳ Время ожидания DeepSeek Web истекло. Отправьте вопрос ещё раз.", key, operation, persistence: persistence)
                return
            }
            if let until = account.quotaUntil, until > Date() {
                try await fail(Self.message(.quota), key, operation, persistence: persistence)
                return
            }
            if let until = account.busyUntil, until > Date() {
                try await fail(Self.message(.busy), key, operation, persistence: persistence)
                return
            }
            guard let workerHealth, workerHealth.status == .ready else {
                let status = workerHealth?.status ?? .unavailable
                if status == .loginRequired { await alerter.report(.deepSeekWebLogin, active: true) }
                try await fail(Self.message(status), key, operation, persistence: persistence)
                return
            }
            await alerter.report(.deepSeekWebLogin, active: false)
            if state.hasUncertainDelivery, await store.mutateWeb(chatKey: key, contextEpoch: operation.contextEpoch, {
                $0.hasUncertainDelivery = false
            }) {
                try await persistence.webCheckpoint(chatKey: key, contextEpoch: operation.contextEpoch)
                await notify("Доставку предыдущего ответа DeepSeek Web не удалось подтвердить.", key, operation.telegramThreadID)
            }
            try await startTurn(key, operation, account: account, persistence: persistence)
        }
    }

    private func startTurn(
        _ key: ChatKey, _ queued: DeepSeekWebOperation, account: DeepSeekWebAccount,
        persistence: PersistenceCoordinator
    ) async throws {
        guard let state = await store.webState(chatKey: key), state.contextEpoch == queued.contextEpoch else { return }
        if let remoteID = state.remoteChatID,
           !(await store.webBindingAvailable(chatKey: key, accountEpoch: account.epoch, remoteChatID: remoteID)) {
            try await fail(Self.message(.uncertain), key, queued, rotate: true, persistence: persistence)
            return
        }
        let typing = Task { [telegram] in
            while !Task.isCancelled {
                try? await telegram.sendChatAction(chatID: key.chatID, threadID: queued.telegramThreadID, action: "typing")
                try? await Task.sleep(for: .seconds(4))
            }
        }
        defer { typing.cancel() }
        var context = state
        if context.remoteUnits >= remoteUnitLimit { context.rotate() }
        var prepared = try await prepare(queued, state: context, account: account)
        if prepared.1.status == .chatUnavailable, context.remoteChatID != nil, !prepared.1.accepted {
            context.rotate()
            prepared = try await prepare(queued, state: context, account: account)
        }

        let (operation, status) = prepared
        guard status.status == .prepared else {
            try await consume(status, key, operation, account: account, persistence: persistence)
            return
        }
        let request = request(for: operation, account: account)
        do {
            guard canRun, await store.mutateWeb(chatKey: key, contextEpoch: queued.contextEpoch, { state in
                if state.remoteChatID != operation.remoteChatID { state.rotate() }
                state.accountEpoch = account.epoch
                if let index = state.operations.firstIndex(where: { $0.id == operation.id }) {
                    state.operations[index] = operation
                }
            }) else { throw DeepSeekWebPersistenceError.superseded }
            try await persistence.webCheckpoint(chatKey: key, contextEpoch: operation.contextEpoch)
            guard canRun, await isCurrent(key, operation) else { throw DeepSeekWebPersistenceError.superseded }
        } catch {
            _ = try? await gateway.perform(.cancel, request)
            throw error
        }

        activeRequest = ActiveRequest(key: key, operationID: operation.id, request: request)
        let control = Task { [telegram] () -> Int? in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return nil }
            let action = BotCallbackAction.stop(GenerationID(raw: operation.id)).rawData
            let markup = InlineKeyboardMarkup(inline_keyboard: [[.init(text: "⏹ Остановить", callback_data: action)]])
            return try? await telegram.sendMessage(.init(
                chatID: key.chatID, threadID: operation.telegramThreadID, replyTo: operation.replyToMessageID,
                text: "💭 DeepSeek Web отвечает…", replyMarkup: markup
            )).message_id
        }
        defer {
            activeRequest = nil
            control.cancel()
            Task { [telegram] in
                if let messageID = await control.value {
                    try? await telegram.deleteMessage(chatID: key.chatID, messageID: messageID)
                }
            }
        }

        let observer = Task { [self, gateway] in
            var savedCandidate: String?
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                guard canRun, await isCurrent(key, operation) else {
                    _ = try? await gateway.perform(.cancel, request)
                    return
                }
                if operation.remoteChatID == nil, savedCandidate == nil,
                   let response = try? await gateway.perform(.status, request),
                   response.accepted, let candidate = response.remoteChatID,
                   !Task.isCancelled,
                   await store.mutateWeb(chatKey: key, contextEpoch: operation.contextEpoch, { state in
                       guard let index = state.operations.firstIndex(where: { $0.id == operation.id }),
                             state.operations[index].stage == .sending else { return }
                       state.operations[index].candidateRemoteChatID = candidate
                   }) {
                    do {
                        try await persistence.webCheckpoint(chatKey: key, contextEpoch: operation.contextEpoch)
                        savedCandidate = candidate
                    } catch {
                        if Task.isCancelled { return }
                    }
                }
            }
        }
        defer { observer.cancel() }
        await metrics.increment(MetricName.generationsStarted)
        let outcome: DeepSeekWebWorkerResponse
        do {
            outcome = try await withTaskCancellationHandler {
                try await gateway.perform(.send, request)
            } onCancel: { [gateway] in
                Task.detached { _ = try? await gateway.perform(.cancel, request) }
            }
        } catch {
            guard canRun, await isCurrent(key, operation), !Task.isCancelled else { return }
            let candidate = await store.webState(chatKey: key)?.operations.first(where: { $0.id == operation.id })?.candidateRemoteChatID
            outcome = try await reconcile(request, candidateRemoteChatID: candidate)
        }
        observer.cancel()
        await observer.value
        guard canRun, await isCurrent(key, operation), !Task.isCancelled else { return }
        if activeRequest?.stopRequested == true {
            try await fail(Self.message(.cancelled), key, operation,
                           rotate: outcome.accepted || outcome.mayHaveSent == true, persistence: persistence)
            return
        }
        // Once the worker has settled, the control button cannot cancel delivery.
        activeRequest = nil
        let result: DeepSeekWebWorkerResponse
        if outcome.status == .uncertain || outcome.status == .inProgress {
            result = try await reconcile(request, candidateRemoteChatID: outcome.remoteChatID)
        } else {
            result = outcome
        }
        if result.status == .completed {
            let health = try await gateway.health()
            guard health.status == .ready, health.accountMarker == account.workerMarker else {
                throw DeepSeekWebPersistenceError.unavailable
            }
        }
        try await consume(result, key, operation, account: account, persistence: persistence)
    }

    private func prepare(
        _ queued: DeepSeekWebOperation, state: DeepSeekWebChatState,
        account: DeepSeekWebAccount
    ) async throws -> (DeepSeekWebOperation, DeepSeekWebWorkerResponse) {
        var operation = queued
        operation.workerOperationID = UUID()
        guard let prompt = DeepSeekWebPrompt.build(operation: queued, state: state) else {
            return (operation, .init(version: 1, operationID: operation.id, status: .inputTooLong,
                                     accepted: false, remoteChatID: nil, remoteTail: nil, text: nil, retryAfterSeconds: nil))
        }
        operation.prompt = prompt.text
        operation.remoteChatID = state.remoteChatID
        operation.remoteTail = state.remoteTail
        operation.plannedListeningThrough = prompt.listeningThrough
        operation.sentListeningSequences = prompt.sentListeningSequences
        operation.usedListening = state.usesListening || prompt.usedListening
        operation.stage = .sending

        let request = request(for: operation, account: account)
        let result: DeepSeekWebWorkerResponse
        do {
            result = try await gateway.perform(.prepare, request)
        } catch {
            _ = try? await gateway.perform(.cancel, request)
            return (operation, .init(version: 1, operationID: operation.id, status: .unavailable,
                                     accepted: false, remoteChatID: nil, remoteTail: nil, text: nil, retryAfterSeconds: nil))
        }
        return (operation, result)
    }

    private func request(for operation: DeepSeekWebOperation, account: DeepSeekWebAccount) -> DeepSeekWebWorkerRequest {
        .init(operationID: operation.workerOperationID ?? operation.id, accountEpoch: account.epoch,
              accountMarker: account.workerMarker, remoteChatID: operation.remoteChatID,
              remoteTail: operation.remoteTail, prompt: operation.prompt)
    }

    private func reconcile(
        _ request: DeepSeekWebWorkerRequest, candidateRemoteChatID: String?
    ) async throws -> DeepSeekWebWorkerResponse {
        let status = try await gateway.perform(.status, request)
        if status.status == .inProgress || status.status == .busy || status.status == .maintenance {
            throw DeepSeekWebPersistenceError.unavailable
        }
        if status.status == .completed { return status }
        if status.status == .prepared {
            _ = try await gateway.perform(.cancel, request)
        }
        var recovery = request
        recovery.candidateRemoteChatID = candidateRemoteChatID ?? status.remoteChatID
        let result = try await gateway.perform(.reconcile, recovery)
        if result.status == .inProgress || result.status == .maintenance {
            throw DeepSeekWebPersistenceError.unavailable
        }
        return result
    }

    private func consume(
        _ result: DeepSeekWebWorkerResponse, _ key: ChatKey, _ operation: DeepSeekWebOperation,
        account: DeepSeekWebAccount, persistence: PersistenceCoordinator
    ) async throws {
        guard canRun, await isCurrent(key, operation) else { return }
        logger.info("DeepSeek Web operation \(operation.id) ended with \(result.status.rawValue)")
        if result.status == .completed, result.accepted, let remoteID = result.remoteChatID,
           let tail = result.remoteTail, let text = result.text, !text.isEmpty {
            guard !remoteID.isEmpty, !tail.isEmpty,
                  operation.remoteChatID == nil || operation.remoteChatID == remoteID else {
                try await fail(Self.message(.uncertain), key, operation, rotate: true, persistence: persistence)
                return
            }
            guard await store.webBindingAvailable(chatKey: key, accountEpoch: account.epoch, remoteChatID: remoteID) else {
                try await fail(Self.message(.uncertain), key, operation, rotate: true, persistence: persistence)
                return
            }

            var confirmed = operation
            confirmed.stage = .confirmed
            confirmed.response = text
            confirmed.remoteChatID = remoteID
            confirmed.remoteTail = tail
            let saved = confirmed
            guard await store.mutateWeb(chatKey: key, contextEpoch: operation.contextEpoch, { state in
                state.accountEpoch = account.epoch
                state.remoteChatID = remoteID
                state.remoteTail = tail
                state.remoteUnits += (operation.prompt?.utf16.count ?? 0) + text.utf16.count
                state.listeningThrough = max(state.listeningThrough, operation.plannedListeningThrough ?? 0)
                state.sentListeningSequences = Array((state.sentListeningSequences + operation.sentListeningSequences).suffix(900))
                state.usesListening = operation.usedListening
                state.rememberNativeMessages([operation.messageID])
                if let index = state.operations.firstIndex(where: { $0.id == operation.id }) {
                    state.operations[index] = saved
                }
            }) else { return }
            try await persistence.webCheckpoint(chatKey: key, contextEpoch: operation.contextEpoch)
            try await deliver(confirmed, key: key, persistence: persistence)
            return
        }

        if result.status == .quota || result.status == .busy {
            var updated = account
            if result.status == .quota {
                let seconds = result.retryAfterSeconds.map { min(86_400, max(1, $0)) }
                updated.quotaUntil = Date().addingTimeInterval(seconds.map(TimeInterval.init) ?? quotaPause)
            } else {
                updated.busyUntil = Date().addingTimeInterval(30)
            }
            try await persistence.saveWebAccount(updated)
        }
        if result.status == .loginRequired { await alerter.report(.deepSeekWebLogin, active: true) }
        let rotate = result.accepted || result.mayHaveSent == true || result.status == .uncertain || result.status == .chatUnavailable
            || result.status == .completed
        try await fail(Self.message(result.status), key, operation, rotate: rotate, persistence: persistence)
    }

    private func deliver(
        _ operation: DeepSeekWebOperation, key: ChatKey, persistence: PersistenceCoordinator
    ) async throws {
        guard let response = operation.response, canRun, await isCurrent(key, operation) else { return }
        if operation.deliveryInFlight == true {
            try await fail("Не удалось подтвердить доставку ответа DeepSeek Web.", key, operation,
                           persistence: persistence, uncertainDelivery: true)
            return
        }

        let parts = Self.parts(response)
        var ids = operation.deliveryMessageIDs
        for part in parts.dropFirst(ids.count) {
            let priorIDs = ids
            guard canRun, await isCurrent(key, operation) else { return }
            try await updateDelivery(key, operation, ids: priorIDs, inFlight: true, persistence: persistence)
            guard canRun, await isCurrent(key, operation) else { return }
            let message: TelegramMessage
            do {
                let request = SendMessageRequest(
                    chatID: key.chatID, threadID: operation.telegramThreadID,
                    replyTo: ids.last ?? operation.replyToMessageID,
                    text: part, replyMarkup: nil, isPlainText: true
                )
                let pending = Task { [telegram] in try await telegram.sendMessage(request) }
                deliveries[key] = pending
                defer { deliveries[key] = nil }
                message = try await pending.value
            } catch {
                try await fail("Не удалось доставить весь ответ DeepSeek Web.", key, operation,
                               persistence: persistence, uncertainDelivery: true)
                return
            }
            ids.append(message.message_id)
            try await updateDelivery(key, operation, ids: ids, inFlight: false, persistence: persistence)
        }
        guard canRun, await store.finishWebDelivery(chatKey: key, contextEpoch: operation.contextEpoch,
                                                   operationID: operation.id) else { return }
        try await persistence.webCheckpoint(chatKey: key, contextEpoch: operation.contextEpoch)
        let covered = await store.hasSubscriptionCoverage(
            key: operation.requesterID.map(UserKey.identified), userID: operation.requesterID, chatID: key.chatID
        )
        if !covered, canRun, await store.webState(chatKey: key)?.contextEpoch == operation.contextEpoch {
            await GenerationCoordinator.serveAd(state: store, telegram: telegram, chatKey: key, isPrivate: !key.chatID.isGroup)
        }
    }

    private func updateDelivery(
        _ key: ChatKey, _ operation: DeepSeekWebOperation, ids: [Int], inFlight: Bool,
        persistence: PersistenceCoordinator
    ) async throws {
        guard await store.mutateWeb(chatKey: key, contextEpoch: operation.contextEpoch, { state in
            guard let index = state.operations.firstIndex(where: { $0.id == operation.id }) else { return }
            state.operations[index].stage = .delivering
            state.operations[index].deliveryInFlight = inFlight
            state.operations[index].deliveryMessageIDs = ids
        }) else { throw DeepSeekWebPersistenceError.superseded }
        try await persistence.webCheckpoint(chatKey: key, contextEpoch: operation.contextEpoch)
    }

    private func fail(
        _ text: String, _ key: ChatKey, _ operation: DeepSeekWebOperation, rotate: Bool = false,
        persistence: PersistenceCoordinator, uncertainDelivery: Bool = false
    ) async throws {
        guard canRun, await store.mutateWeb(chatKey: key, contextEpoch: operation.contextEpoch, { state in
            if rotate { state.rotate() }
            if uncertainDelivery { state.hasUncertainDelivery = true }
            state.operations.removeAll { $0.id == operation.id }
        }) else { return }
        try await persistence.webCheckpoint(chatKey: key, contextEpoch: operation.contextEpoch)
        await notify(text, key, operation.telegramThreadID, replyTo: operation.replyToMessageID)
    }

    private func isCurrent(_ key: ChatKey, _ operation: DeepSeekWebOperation) async -> Bool {
        guard let state = await store.webState(chatKey: key), state.contextEpoch == operation.contextEpoch else { return false }
        return state.operations.contains { $0.id == operation.id }
    }

    private func notify(_ text: String, _ key: ChatKey, _ thread: Int64?, replyTo: Int? = nil) async {
        _ = try? await telegram.sendMessage(.init(
            chatID: key.chatID, threadID: thread, replyTo: replyTo, text: text, replyMarkup: nil
        ))
    }

    static func parts(_ raw: String) -> [String] {
        var parts: [String] = []
        var part = ""
        var units = 0
        for scalar in raw.unicodeScalars {
            let width = scalar.value > 0xFFFF ? 2 : 1
            if units + width > MessageSplitter.telegramMaxChars {
                parts.append(part)
                part = ""
                units = 0
            }
            part.unicodeScalars.append(scalar)
            units += width
        }
        if !part.isEmpty { parts.append(part) }
        return parts
    }

    static func message(_ status: DeepSeekWebWorkerStatus) -> String {
        switch status {
        case .quota: return "DeepSeek Web исчерпал лимит запросов. Попробуйте позже."
        case .busy: return "DeepSeek Web временно перегружен. Попробуйте чуть позже."
        case .loginRequired: return "DeepSeek Web просит войти в аккаунт. Сообщите администратору бота."
        case .maintenance: return "DeepSeek Web на обслуживании. Попробуйте позже."
        case .moderated: return "DeepSeek Web отклонил запрос по правилам сервиса."
        case .inputTooLong: return "Сообщение для DeepSeek Web слишком длинное. Сократите вопрос или роль."
        case .uncertain: return "DeepSeek Web не подтвердил результат отправки. Отправьте вопрос ещё раз."
        case .chatUnavailable: return "Диалог DeepSeek Web недоступен. Отправьте вопрос ещё раз."
        case .cancelled: return "⏹ Запрос DeepSeek Web остановлен."
        default: return "DeepSeek Web временно недоступен. Попробуйте позже."
        }
    }
}
