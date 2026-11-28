import Foundation

enum DeepSeekWebAdmissionRetry: Error {
    case persistence
}

actor DeepSeekWebQueue {
    private struct ActiveRequest {
        let key: ChatKey
        let operationID: UUID
        var request: DeepSeekWebWorkerRequest?
        var attachmentDownload: Task<DeepSeekWebAttachmentBatch, Error>?
        var stopRequested = false
    }

    private struct PreviewPart {
        let messageID: Int
        var part: DeepSeekWebTelegramFormatter.Part
    }

    private static let openingMessage = "🌐 Открываю чат…"
    private static let waitingMessage = "💭 Отвечаю…"

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
    private var deliveries: [ChatKey: Task<Void, Never>] = [:]

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
    func admit(
        question: String, origin: GenerationOrigin, chatKey: ChatKey,
        attachments: [InboundMediaRef] = [], albumUpdateIDs: [Int]? = nil
    ) async throws -> Bool {
        guard canRun, let persistence, let updateID = origin.updateID else {
            await notify(Self.message(.unavailable), chatKey, origin.telegramThreadID)
            return false
        }
        let started = ContinuousClock.now
        // Count admission calls while awaiting actor and database work.
        inAdmission += 1
        defer { inAdmission -= 1 }
        let items = await store.webOperations()
        guard items.count + inAdmission <= queueLimit,
              items.lazy.filter({ $0.0 == chatKey }).count < perChatLimit else {
            await notify("⏳ Очередь DeepSeek Web заполнена. Попробуйте позже.", chatKey, origin.telegramThreadID)
            return false
        }

        if let epoch = await store.webGroupNoticeEpoch(chatKey: chatKey) {
            _ = try await telegram.sendMessage(.init(
                chatID: chatKey.chatID, threadID: origin.telegramThreadID, replyTo: nil,
                text: Texts.webGroupDisclosure, replyMarkup: nil
            ))
            guard await store.mutateWeb(chatKey: chatKey, contextEpoch: epoch, { $0.groupNoticeSent = true }) else {
                return false
            }
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
                replyToMessageID: origin.replyToMessageID, asker: origin.userKey,
                attachments: attachments.isEmpty ? nil : attachments,
                albumUpdateIDs: albumUpdateIDs?.map(Int64.init)
            ) else { return false }
            let inserted = try await persistence.webAdmit(chatKey: chatKey, operation: operation)
            if inserted {
                let telegramAge = origin.telegramMessageDate.map { Date().timeIntervalSince($0) }
                logger.info(
                    "DeepSeek Web operation \(operation.id) admitted in \(started.duration(to: .now))"
                    + (telegramAge.map { " (Telegram message age \($0.formatted(.number.precision(.fractionLength(3))))s)" } ?? "")
                )
            }
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
        activeRequest.attachmentDownload?.cancel()
        if let request = activeRequest.request {
            _ = try? await gateway.perform(.cancel, request)
        }
        return true
    }

    func waitForDelivery(chatKey: ChatKey) async {
        await deliveries[chatKey]?.value
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
            guard let workerHealth, workerHealth.status == .ready || workerHealth.status == .warming else {
                let status = workerHealth?.status ?? .unavailable
                if status == .loginRequired { await alerter.report(.deepSeekWebLogin, active: true) }
                try await fail(Self.message(status), key, operation, persistence: persistence)
                return
            }
            if operation.attachments?.isEmpty == false, workerHealth.supportsAttachments != true {
                try await fail(Self.message(.attachmentsUnavailable), key, operation, persistence: persistence)
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
        activeRequest = ActiveRequest(key: key, operationID: queued.id)
        let markup = Self.stopMarkup(for: queued)
        let notice = Task { [telegram, logger] () -> Int? in
            let started = ContinuousClock.now
            guard let message = try? await telegram.sendMessage(.init(
                chatID: key.chatID, threadID: queued.telegramThreadID, replyTo: queued.replyToMessageID,
                text: queued.attachments?.isEmpty == false ? "📎 Загружаю вложения…" : Self.openingMessage,
                replyMarkup: markup
            )) else { return nil }
            logger.info(
                "DeepSeek Web operation \(queued.id) sent opening status in \(started.duration(to: .now))"
                + " (queued operation age \(Date().timeIntervalSince(queued.createdAt).formatted(.number.precision(.fractionLength(3))))s)"
            )
            return message.message_id
        }
        var noticeRecorded = false
        defer {
            activeRequest = nil
            if !noticeRecorded {
                Task { [telegram] in
                    if let id = await notice.value { try? await telegram.deleteMessage(chatID: key.chatID, messageID: id) }
                }
            }
        }
        let batch: DeepSeekWebAttachmentBatch?
        if let attachments = queued.attachments, !attachments.isEmpty {
            let download = Task { [telegram] in
                try await DeepSeekWebAttachmentBatch.stage(attachments, telegram: telegram)
            }
            activeRequest?.attachmentDownload = download
            do {
                batch = try await withTaskCancellationHandler {
                    try await download.value
                } onCancel: {
                    download.cancel()
                }
            } catch {
                guard canRun, !Task.isCancelled else { return }
                let feedback = activeRequest?.stopRequested == true
                    ? Self.message(.cancelled)
                    : (error as? DeepSeekWebAttachmentBatch.Failure ?? .downloadFailed).message
                try await fail(feedback, key, queued, persistence: persistence)
                return
            }
            activeRequest?.attachmentDownload = nil
        } else {
            batch = nil
        }
        defer { batch?.remove() }
        guard canRun, !Task.isCancelled, await isCurrent(key, queued) else { return }
        if activeRequest?.stopRequested == true {
            try await fail(Self.message(.cancelled), key, queued, persistence: persistence)
            return
        }

        var context = state
        if context.remoteUnits >= remoteUnitLimit { context.rotate() }
        var prepared = await prepare(queued, state: context, account: account, attachmentNames: batch?.names)
        if prepared.1.status == .chatUnavailable, context.remoteChatID != nil, !prepared.1.accepted,
           activeRequest?.stopRequested == false, canRun, !Task.isCancelled, await isCurrent(key, queued) {
            context.rotate()
            prepared = await prepare(queued, state: context, account: account, attachmentNames: batch?.names)
        }

        let (operation, status) = prepared
        let request = request(for: operation, account: account)
        if activeRequest?.stopRequested == true {
            _ = try? await gateway.perform(.cancel, request)
            try await fail(Self.message(.cancelled), key, queued, persistence: persistence)
            return
        }
        guard status.status == .prepared else {
            try await consume(status, key, operation, account: account, persistence: persistence)
            return
        }
        var staged = operation
        if let id = await notice.value { staged.previewMessageIDs = [id] }
        let sending = staged
        do {
            guard canRun, !Task.isCancelled, await store.mutateWeb(chatKey: key, contextEpoch: queued.contextEpoch, { state in
                if state.remoteChatID != sending.remoteChatID { state.rotate() }
                state.accountEpoch = account.epoch
                if let index = state.operations.firstIndex(where: { $0.id == sending.id }) {
                    state.operations[index] = sending
                }
            }) else { throw DeepSeekWebPersistenceError.superseded }
            noticeRecorded = true
            try await persistence.webCheckpoint(chatKey: key, contextEpoch: sending.contextEpoch)
            guard canRun, !Task.isCancelled, await isCurrent(key, sending) else { throw DeepSeekWebPersistenceError.superseded }
        } catch {
            _ = try? await gateway.perform(.cancel, request)
            if !(await isCurrent(key, sending)) { noticeRecorded = false }
            throw error
        }

        if activeRequest?.stopRequested == true {
            _ = try? await gateway.perform(.cancel, request)
            try await fail(Self.message(.cancelled), key, sending, persistence: persistence)
            return
        }
        let observer = Task {
            await observeTurn(key, sending, request: request, persistence: persistence)
        }
        await metrics.increment(MetricName.generationsStarted)
        var submission = request
        submission.attachmentBatchID = batch?.id
        let outcome: DeepSeekWebWorkerResponse
        do {
            outcome = try await withTaskCancellationHandler {
                try await gateway.perform(.send, submission)
            } onCancel: { [gateway] in
                Task.detached { _ = try? await gateway.perform(.cancel, request) }
            }
        } catch {
            observer.cancel()
            await observer.value
            guard canRun, !Task.isCancelled, let current = await currentOperation(key, sending) else { return }
            outcome = try await reconcile(request, candidateRemoteChatID: current.candidateRemoteChatID)
        }
        observer.cancel()
        await observer.value
        guard canRun, !Task.isCancelled, let current = await currentOperation(key, sending) else { return }
        if activeRequest?.stopRequested == true {
            try await fail(Self.message(.cancelled), key, current,
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
        try await consume(result, key, current, account: account, persistence: persistence)
    }

    private func observeTurn(
        _ key: ChatKey, _ operation: DeepSeekWebOperation, request: DeepSeekWebWorkerRequest,
        persistence: PersistenceCoordinator
    ) async {
        var candidate = operation.remoteChatID
        var previews = (operation.previewMessageIDs ?? []).map {
            PreviewPart(messageID: $0, part: .init(text: Self.openingMessage))
        }
        var canPreview = true
        var showedText = false
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(750))
            if Task.isCancelled { break }
            guard canRun, await isCurrent(key, operation) else {
                _ = try? await gateway.perform(.cancel, request)
                break
            }
            guard activeRequest?.stopRequested == false else { break }
            guard let response = try? await gateway.perform(.status, request), response.status == .inProgress,
                  response.accepted, let remoteID = response.remoteChatID, !remoteID.isEmpty else { continue }
            if let candidate, candidate != remoteID { continue }
            if candidate == nil {
                guard await store.webBindingAvailable(chatKey: key, accountEpoch: request.accountEpoch, remoteChatID: remoteID) else {
                    _ = try? await gateway.perform(.cancel, request)
                    break
                }
                guard !Task.isCancelled, await store.mutateWeb(chatKey: key, contextEpoch: operation.contextEpoch, { state in
                    guard let index = state.operations.firstIndex(where: { $0.id == operation.id }) else { return }
                    state.operations[index].candidateRemoteChatID = remoteID
                }) else { break }
                do {
                    try await persistence.webCheckpoint(chatKey: key, contextEpoch: operation.contextEpoch)
                } catch {
                    continue
                }
                candidate = remoteID
            }

            guard canPreview else { continue }
            let parts: [DeepSeekWebTelegramFormatter.Part]
            if let partial = response.partialText, !partial.isEmpty {
                parts = DeepSeekWebTelegramFormatter.parts(response.partialFormattedText ?? partial)
                showedText = true
            } else {
                guard !showedText, !previews.isEmpty else { continue }
                parts = [.init(text: Self.waitingMessage)]
            }
            let previousCount = previews.count
            let markup = Self.stopMarkup(for: operation)
            for (index, part) in parts.enumerated() {
                guard canRun, !Task.isCancelled, activeRequest?.stopRequested == false,
                      await isCurrent(key, operation) else { break }
                do {
                    if index < previews.count {
                        let preview = previews[index]
                        guard preview.part != part else { continue }
                        try await editPart(preview.messageID, part: part, key: key, markup: index == 0 ? markup : nil)
                        previews[index].part = part
                    } else {
                        let message = try await sendPart(
                            part, key: key, thread: operation.telegramThreadID,
                            replyTo: previews.last?.messageID ?? operation.replyToMessageID, markup: index == 0 ? markup : nil
                        )
                        previews.append(.init(messageID: message.message_id, part: part))
                    }
                } catch {
                    canPreview = false
                    break
                }
            }

            if previews.count != previousCount {
                let ids = previews.map(\.messageID)
                guard await store.mutateWeb(chatKey: key, contextEpoch: operation.contextEpoch, { state in
                    guard let index = state.operations.firstIndex(where: { $0.id == operation.id }) else { return }
                    state.operations[index].previewMessageIDs = ids
                }) else { break }
                try? await persistence.webCheckpoint(chatKey: key, contextEpoch: operation.contextEpoch)
            }
        }
        if !(await isCurrent(key, operation)) {
            removePreviews(previews.map(\.messageID), key: key)
        }
    }

    private static func stopMarkup(for operation: DeepSeekWebOperation) -> InlineKeyboardMarkup {
        let action = BotCallbackAction.stop(GenerationID(raw: operation.id)).rawData
        return .init(inline_keyboard: [[.init(text: "⏹ Остановить", callback_data: action)]])
    }

    private func prepare(
        _ queued: DeepSeekWebOperation, state: DeepSeekWebChatState,
        account: DeepSeekWebAccount, attachmentNames: [String]?
    ) async -> (DeepSeekWebOperation, DeepSeekWebWorkerResponse) {
        var operation = queued
        operation.workerOperationID = UUID()
        guard let prompt = DeepSeekWebPrompt.build(operation: queued, state: state) else {
            return (operation, .init(version: 1, operationID: operation.id, status: .inputTooLong,
                                     accepted: false, remoteChatID: nil, remoteTail: nil, text: nil, retryAfterSeconds: nil))
        }
        operation.prompt = prompt.text
        operation.attachments = nil
        operation.attachmentNames = attachmentNames
        operation.remoteChatID = state.remoteChatID
        operation.remoteTail = state.remoteTail
        operation.plannedListeningThrough = prompt.listeningThrough
        operation.sentListeningSequences = prompt.sentListeningSequences
        operation.usedListening = state.usesListening || prompt.usedListening
        operation.stage = .sending

        let request = request(for: operation, account: account)
        activeRequest?.request = request
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
              remoteTail: operation.remoteTail, prompt: operation.prompt, deepThink: operation.deepThink,
              webSearch: operation.webSearch, attachmentNames: operation.attachmentNames)
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
            confirmed.formattedResponse = result.formattedText ?? text
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

        // The persisted source also keeps chunk boundaries stable after restart.
        let parts = operation.formattedResponse.map(DeepSeekWebTelegramFormatter.parts)
            ?? DeepSeekWebTelegramFormatter.plainParts(response)
        var ids = operation.deliveryMessageIDs
        let previews = operation.previewMessageIDs ?? []
        for (index, part) in parts.enumerated().dropFirst(ids.count) {
            guard canRun, await isCurrent(key, operation) else { return }
            if previews.indices.contains(index) {
                let messageID = previews[index]
                if try await finalizePreview(messageID, part: part, key: key) {
                    ids.append(messageID)
                    try await updateDelivery(key, operation, ids: ids, inFlight: false, persistence: persistence)
                    continue
                }
            }

            try await updateDelivery(key, operation, ids: ids, inFlight: true, persistence: persistence)
            guard canRun, await isCurrent(key, operation) else { return }
            let message: TelegramMessage
            do {
                message = try await sendPart(
                    part, key: key, thread: operation.telegramThreadID,
                    replyTo: ids.last ?? operation.replyToMessageID, markup: nil
                )
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
        removePreviews(previews.filter { !ids.contains($0) }, key: key)
        let covered = await store.hasSubscriptionCoverage(
            key: operation.requesterID.map(UserKey.identified), userID: operation.requesterID, chatID: key.chatID
        )
        if !covered, canRun, await store.webState(chatKey: key)?.contextEpoch == operation.contextEpoch {
            await GenerationCoordinator.serveAd(state: store, telegram: telegram, chatKey: key, isPrivate: !key.chatID.isGroup)
        }
    }

    private func sendPart(
        _ part: DeepSeekWebTelegramFormatter.Part, key: ChatKey, thread: Int64?, replyTo: Int?, markup: InlineKeyboardMarkup?
    ) async throws -> TelegramMessage {
        try await deliverToTelegram(key) { [telegram] in
            try await Self.withFormattingFallback(part) { entities in
                try await telegram.sendMessage(.init(
                    chatID: key.chatID, threadID: thread, replyTo: replyTo,
                    text: part.text, replyMarkup: markup, isPlainText: true, entities: entities
                ))
            }
        }
    }

    private func editPart(
        _ id: Int, part: DeepSeekWebTelegramFormatter.Part, key: ChatKey, markup: InlineKeyboardMarkup?
    ) async throws {
        try await deliverToTelegram(key) { [telegram] in
            try await Self.withFormattingFallback(part) { entities in
                try await telegram.editMessage(.init(
                    chatID: key.chatID, messageID: id, text: part.text,
                    replyMarkup: markup, isPlainText: true, entities: entities
                ))
            }
        }
    }

    private func finalizePreview(_ id: Int, part: DeepSeekWebTelegramFormatter.Part, key: ChatKey) async throws -> Bool {
        do {
            try await editPart(id, part: part, key: key, markup: .init(inline_keyboard: []))
            return true
        } catch let error as TelegramAPIError where error.statusCode == 400 && (
            error.descriptionText.contains("message to edit not found") || error.descriptionText.contains("message can't be edited")
        ) {
            return false
        }
    }

    private static func withFormattingFallback<Result>(
        _ part: DeepSeekWebTelegramFormatter.Part, send: ([TelegramTextEntity]?) async throws -> Result
    ) async throws -> Result {
        var entities = part.entities
        while !entities.isEmpty {
            do {
                return try await send(entities)
            } catch let error as TelegramAPIError where error.statusCode == 400 {
                let description = error.descriptionText.lowercased()
                guard ["entit", "custom emoji", "custom_emoji", "url_invalid", "wrong http url"].contains(where: {
                    description.contains($0)
                }) else { throw error }
                let withoutEmoji = entities.filter { $0.customEmojiID == nil }
                entities = withoutEmoji.count < entities.count ? withoutEmoji : []
            }
        }
        return try await send(nil)
    }

    private func deliverToTelegram<Result: Sendable>(
        _ key: ChatKey, _ send: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        // Wait for an in-flight preview edit before publishing the final text.
        let pending = Task { try await send() }
        deliveries[key] = Task { _ = try? await pending.value }
        defer { deliveries[key] = nil }
        return try await pending.value
    }

    private func removePreviews(_ ids: [Int], key: ChatKey) {
        guard !ids.isEmpty else { return }
        Task { [telegram] in
            for id in ids { try? await telegram.deleteMessage(chatID: key.chatID, messageID: id) }
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
        guard canRun, let current = await currentOperation(key, operation),
              await store.mutateWeb(chatKey: key, contextEpoch: operation.contextEpoch, { state in
            if rotate { state.rotate() }
            if uncertainDelivery { state.hasUncertainDelivery = true }
            state.operations.removeAll { $0.id == operation.id }
        }) else { return }
        try await persistence.webCheckpoint(chatKey: key, contextEpoch: operation.contextEpoch)
        removePreviews((current.previewMessageIDs ?? []).filter { !current.deliveryMessageIDs.contains($0) }, key: key)
        await notify(text, key, operation.telegramThreadID, replyTo: operation.replyToMessageID)
    }

    private func isCurrent(_ key: ChatKey, _ operation: DeepSeekWebOperation) async -> Bool {
        await currentOperation(key, operation) != nil
    }

    private func currentOperation(_ key: ChatKey, _ operation: DeepSeekWebOperation) async -> DeepSeekWebOperation? {
        guard let state = await store.webState(chatKey: key), state.contextEpoch == operation.contextEpoch else { return nil }
        return state.operations.first { $0.id == operation.id }
    }

    private func notify(_ text: String, _ key: ChatKey, _ thread: Int64?, replyTo: Int? = nil) async {
        _ = try? await telegram.sendMessage(.init(
            chatID: key.chatID, threadID: thread, replyTo: replyTo, text: text, replyMarkup: nil
        ))
    }

    static func message(_ status: DeepSeekWebWorkerStatus) -> String {
        switch status {
        case .quota: return "DeepSeek Web исчерпал лимит запросов. Попробуйте позже."
        case .busy: return "DeepSeek Web временно перегружен. Попробуйте чуть позже."
        case .loginRequired: return "DeepSeek Web просит войти в аккаунт. Сообщите администратору бота."
        case .maintenance: return "DeepSeek Web на обслуживании. Попробуйте позже."
        case .moderated: return "DeepSeek Web отклонил запрос по правилам сервиса."
        case .attachmentsUnavailable: return "Загрузка файлов доступна, когда DeepSeek Web работает через браузер."
        case .attachmentFormat: return "DeepSeek Web не принимает формат одного из файлов. Попробуйте отправить файл в другом формате."
        case .attachmentFailed: return "DeepSeek Web не загрузил все вложения. Отправьте запрос ещё раз."
        case .inputTooLong: return "Сообщение для DeepSeek Web слишком длинное. Сократите вопрос или роль."
        case .uncertain: return "DeepSeek Web не подтвердил результат отправки. Отправьте вопрос ещё раз."
        case .chatUnavailable: return "Диалог DeepSeek Web недоступен. Отправьте вопрос ещё раз."
        case .cancelled: return "⏹ Запрос DeepSeek Web остановлен."
        default: return "DeepSeek Web временно недоступен. Попробуйте позже."
        }
    }
}
