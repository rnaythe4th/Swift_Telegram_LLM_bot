import Foundation

// Process lifecycle: restoring state on boot, the run loop for whichever
// transport is in use, the background sweeps, graceful shutdown, and the
// `/metrics` report that describes all of it.

extension BotOrchestrator {
    // MARK: - Boot: schema, writer lock, restore

    /// Brings the database up to date and, if this process wins the writer
    /// race, loads state into the store. The order is not negotiable:
    ///
    /// 1. **Migrate**, or refuse to start if the schema is newer than this
    ///    binary knows — an old build writing into a new schema loses whatever
    ///    the new columns hold.
    /// 2. **Take the writer lock** (§3.1) — one attempt here; `run` keeps
    ///    trying in the background, see `becomeWriterWhenFree`.
    /// 3. **Read** — after the lock, never before, or the race just moves.
    ///
    /// A failure at any step leaves the bot answering questions from memory and
    /// refusing to sell anything (§4.3), which is the only honest response to
    /// "I cannot promise this will still be here tomorrow".
    func bootstrapState(storage: AppAssembly.Storage) async -> Bool {
        writerLock.value = storage.writerLock
        guard let persistence = storage.persistence, storage.coordinator != nil else {
            flags.durability.value = .volatile(reason: "no DATABASE_URL")
            logger.warning("persistence disabled — state is in-memory only, purchases are refused")
            return false
        }

        do {
            try await persistence.migrate()
        } catch {
            flags.durability.value = .volatile(reason: "schema")
            logger.error("schema check failed — running memory-only, purchases refused: \(error)")
            return false
        }
        storedState.value = persistence
        retention.value = RetentionService(state: state, persistence: persistence, logger: logger)
        return await claimWriterAndRestore()
    }

    /// One attempt at the lock, and a full restore if it lands.
    func claimWriterAndRestore() async -> Bool {
        guard let persistence = storedState.value else { return false }

        if let lock = writerLock.value {
            let acquired = await lock.acquire { [weak self] in
                // The connection holding the lock died: we are not the writer
                // any more. Writing on top of whoever took it is worse than
                // stopping, so the process leaves rather than argues.
                guard let self else { return }
                Task { await self.stepDownAsWriter() }
            }
            guard acquired else {
                flags.durability.value = .readOnly(reason: "another instance is the writer")
                return false
            }
        }

        do {
            let stored = try await persistence.loadEverything()
            await state.restore(from: stored)
            flags.durability.value = .durable
            logger.info("state restored (chats: \(stored.contexts.count), tenants: \(stored.tenants.count), wallets: \(stored.wallets.count))")
            return true
        } catch {
            flags.durability.value = .volatile(reason: "restore failed")
            logger.error("state restore failed — running memory-only, writes disabled to protect stored data: \(error)")
            return false
        }
    }

    /// Waits for the outgoing instance to let the lock go, then takes over.
    ///
    /// This exists because of how a healthcheck-gated deploy actually works:
    /// the platform keeps the old instance serving until the new one reports
    /// ready, and the old one holds the writer lock until it is stopped. A new
    /// instance that refused to report ready without the lock would wait for an
    /// instance that is waiting for it — a deploy that can never finish.
    ///
    /// So the new process reports ready straight away and simply **declines
    /// every update** until it is the writer: the webhook answers 503, Telegram
    /// holds those updates and redelivers them, and nothing is lost. The
    /// handover costs a few seconds of queued updates, which is exactly what
    /// the redeploy path was already built for.
    private func becomeWriterWhenFree(mode: IntakeRunMode, intake: UpdateIntake) async {
        logger.warning("another instance is still the writer — waiting for the handover")
        let alertAfter = ContinuousClock().now + .seconds(600)
        var alerted = false

        while !flags.draining.value {
            try? await Task.sleep(for: .seconds(2))
            if await claimWriterAndRestore() {
                logger.info("writer lock acquired — taking over")
                await alerter.report(.notWriter, active: false)
                await startServing(mode: mode, intake: intake, persistenceHealthy: true)
                return
            }
            if !alerted, ContinuousClock().now > alertAfter {
                alerted = true
                // Ten minutes is no longer a handover; something is holding the
                // lock that is not going away (a stuck instance, replicas > 1).
                await alerter.report(.notWriter, active: true, detail: "дольше 10 минут")
            }
        }
    }

    /// Called when the writer lock is lost mid-flight. Stops persisting
    /// immediately and **without a final flush**: writing over whoever holds the
    /// lock now is worse than losing the last two seconds.
    func stepDownAsWriter() async {
        guard flags.durability.value == .durable else { return }
        flags.durability.value = .readOnly(reason: "writer lock lost")
        logger.error("writer lock lost — stopping persistence and draining")
        await persistence?.abandon()
        await shutdown()
    }

    // MARK: - Run

    func run(mode: IntakeRunMode, intake: UpdateIntake, persistenceHealthy: Bool) async {
        activeIntake.value = intake
        // Ready as soon as the process can answer a healthcheck. Whether it may
        // *change* anything is a separate question, asked at every entrance by
        // `flags.durability` — including the webhook, which declines updates
        // until this instance is the writer.
        flags.ready.value = true

        if case .readOnly = flags.durability.value {
            await becomeWriterWhenFree(mode: mode, intake: intake)
            return
        }
        await startServing(mode: mode, intake: intake, persistenceHealthy: persistenceHealthy)
    }

    /// Everything that only a writer may do: persistence, the background
    /// sweeps, and taking updates.
    private func startServing(mode: IntakeRunMode, intake: UpdateIntake, persistenceHealthy: Bool) async {
        if persistenceHealthy {
            await persistence?.start()
        }

        await modelPriceMonitor?.performInitialFetch()

        var tasks: [Task<Void, Never>] = []
        tasks.append(Task { [weak self] in
            await self?.modelPriceMonitor?.run()
        })
        tasks.append(Task { [weak self] in
            await self?.cryptoMonitor?.run()
        })
        if persistenceHealthy {
            tasks.append(Task { [weak self] in
                await self?.runPersistenceNotifyLoop()
            })
        }
        tasks.append(Task { [weak self] in
            await self?.runHealthLoop()
        })
        // Retention (§7.2). Only the writer runs it — two instances deleting
        // the same rows is pointless, and only one of them owns the state.
        if let retention = retention.value {
            tasks.append(Task { await retention.run() })
        }
        // Renewal reminders / winback (roadmap step 8). Runs regardless of the
        // storage state: notices are deduplicated in memory too, and a
        // memory-only bot still shouldn't let subscriptions lapse silently.
        tasks.append(Task { [weak self] in
            await self?.reminderService.run()
        })
        backgroundTasks.value.append(contentsOf: tasks)

        switch mode {
        case .webhook(let publicBaseURL, let secret):
            do {
                let url = publicBaseURL + WebhookEndpoint.path
                try await telegram.setWebhook(
                    url: url,
                    secretToken: secret,
                    allowedUpdates: TelegramUpdateSubscription.allowedUpdates
                )
                logger.info("webhook registered: \(url)")
                // Updates now arrive via AppHTTPServer → intake; park until drain.
                while !flags.draining.value {
                    try? await Task.sleep(for: .seconds(1))
                }
            } catch {
                logger.error("setWebhook failed, falling back to polling: \(error)")
                // A half-registered webhook (or one left by a previous deploy)
                // makes every getUpdates fail with "webhook is active" — the
                // fallback would spin on errors instead of serving anyone.
                try? await telegram.deleteWebhook()
                await runPollingLoop(intake: intake)
            }
        case .polling:
            try? await telegram.deleteWebhook()
            logger.info("long polling started")
            await runPollingLoop(intake: intake)
        }
    }

    private func runPollingLoop(intake: UpdateIntake) async {
        var offset = await state.pollingOffset()
        while !flags.draining.value {
            do {
                let updates = try await telegram.getUpdates(offset: offset)
                if let maxUpdateID = updates.map(\.update_id).max() {
                    let next = maxUpdateID + 1
                    offset = next
                    await state.setPollingOffset(next)
                }
                await intake.enqueue(updates)
            } catch {
                logger.error("getUpdates error: \(error)")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    /// Turns the conditions nobody watches into messages the owner gets once
    /// (§6.1). Every check is cheap and reads state the bot already holds; the
    /// alerter itself does the deduplication.
    private func runHealthLoop() async {
        // A first pass after a minute: long enough for boot to settle, short
        // enough that a bot that came up degraded says so while the owner is
        // still looking at the deploy.
        try? await Task.sleep(for: .seconds(60))
        var nextReconcile = ContinuousClock().now
        while !Task.isCancelled {
            let durability = flags.durability.value
            switch durability {
            case .durable:
                await alerter.report(.volatileMode, active: false)
                await alerter.report(.notWriter, active: false)
            case .volatile(let reason):
                await alerter.report(.volatileMode, active: true, detail: reason)
            case .readOnly(let reason):
                await alerter.report(.notWriter, active: true, detail: reason)
            }

            if let persistence {
                let status = await persistence.status()
                let stuck = status.lastErrorMessage != nil
                    && (status.lastSuccessAt.map { Date().timeIntervalSince($0) > 300 } ?? true)
                await alerter.report(.databaseDown, active: stuck, detail: status.lastErrorMessage)
            }

            // An unknown free-model set means every paid model is being gated by
            // the daily allowance — the bot keeps working, but the owner should
            // know why answers got worse.
            let catalogueDown = await state.allowedFreeModelIDs() == nil
            await alerter.report(.modelCatalogueDown, active: catalogueDown)

            // Reconciliation reads the whole journal, so it runs on its own
            // slower clock: the invariant it checks cannot drift in five
            // minutes without something else alerting first.
            if ContinuousClock().now >= nextReconcile {
                nextReconcile = ContinuousClock().now + .seconds(3600)
                if let mismatched = try? await ledger.reconcile() {
                    await alerter.report(
                        .ledgerMismatch,
                        active: !mismatched.isEmpty,
                        detail: mismatched.isEmpty ? nil : "кошельков: \(mismatched.count)"
                    )
                }
            }

            try? await Task.sleep(for: .seconds(300))
        }
    }

    /// Periodic persistence status for chats that opted into backup
    /// notifications (the write-behind replacement for the old 60s backup
    /// report).
    private func runPersistenceNotifyLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            guard let persistence else { return }
            let chatKeys = await state.chatsWithBackupNotify()
            guard !chatKeys.isEmpty else { continue }
            let line = await persistence.statusLine()
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = TimeZone(abbreviation: "UTC")
            let timeString = formatter.string(from: Date())
            for chatKey in chatKeys {
                _ = try? await telegram.sendMessage(
                    .init(
                        chatID: chatKey.chatID,
                        threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                        replyTo: nil,
                        text: "💾 <b>Хранилище</b> · \(line)\n<i>\(timeString)</i>",
                        replyMarkup: nil
                    )
                )
            }
        }
    }

    // MARK: - Graceful shutdown

    /// SIGTERM path: stop taking updates (webhook answers 503 → Telegram
    /// redelivers after restart), let in-flight generations finish briefly,
    /// then flush all dirty state.
    func shutdown() async {
        let alreadyStarted = shutdownStarted.withLock { started -> Bool in
            let was = started
            started = true
            return was
        }
        guard !alreadyStarted else { return }

        logger.info("shutdown: draining…")
        flags.draining.value = true
        flags.ready.value = false

        // Everything the webhook answered 200 for is ours to finish: Telegram
        // will not redeliver it. Release the album buffer first, then wait for
        // the per-chat queues as well as the in-flight streams — an update
        // sitting in a queue is a message the user sent and never got an answer
        // to, and it leaves no trace anywhere.
        if let intake = activeIntake.value { await intake.shutdown() }

        let deadline = ContinuousClock().now + .seconds(8)
        while ContinuousClock().now < deadline {
            let queued = await updateDispatcher.totalQueuedOperations
            let streaming = await sessionRegistry.activeCount
            if queued == 0, streaming == 0 { break }
            try? await Task.sleep(for: .milliseconds(250))
        }

        for task in backgroundTasks.value {
            task.cancel()
        }

        await persistence?.stop()

        // The lock goes last, after the final flush: it is what tells the next
        // instance that this one is done. Dropping the connection releases it —
        // no unlock to forget, no lease to wait out, so the incoming deploy can
        // start writing within its next retry (two seconds).
        if let lock = writerLock.value {
            await lock.release()
        }
        logger.info("shutdown: state flushed, writer lock released, exiting")
    }


    // MARK: - Metrics report (GET /metrics)

    struct MetricsReport: Codable, Sendable {
        let uptimeSeconds: Int
        let activeGenerations: Int
        let queuedChatOperations: Int
        let dirtyEntities: Int
        let persistence: String
        /// Whether what the bot writes now will still be there later (§4.3).
        /// `degraded` is the one boolean worth an external alert rule.
        let durability: String
        let degraded: Bool
        /// Conditions the owner has already been messaged about (§6.1).
        let alerts: [String]
        let counters: [String: Int]
        /// Conversion-funnel event counts + live sponsor tallies (roadmap step 7).
        let funnel: [String: Int]
        /// The same events over the last day / 7 days: a total says how big,
        /// a window says whether it is moving.
        let funnelToday: [String: Int]
        let funnelWeek: [String: Int]
    }

    /// The same numbers in Prometheus exposition format, for `GET /metrics`
    /// with `Accept: text/plain`.
    ///
    /// Forty lines of string building rather than a dependency, and it turns
    /// the endpoint that already exists (and is already token-guarded) into
    /// something a free Grafana Cloud can scrape. Without it the funnel is a
    /// number you read by hand, once, when you remember to.
    func prometheusReport() async -> String {
        let report = await metricsReport()
        var out: [String] = []

        func metric(_ name: String, _ help: String, _ value: Int, labels: String = "") {
            out.append("# HELP \(name) \(help)")
            out.append("# TYPE \(name) gauge")
            out.append("\(name)\(labels) \(value)")
        }

        metric("bot_uptime_seconds", "Process uptime.", report.uptimeSeconds)
        metric("bot_active_generations", "Streams in flight.", report.activeGenerations)
        metric("bot_queued_chat_operations", "Updates waiting behind a per-chat queue.", report.queuedChatOperations)
        metric("bot_dirty_entities", "Entities waiting for the next write-behind flush.", report.dirtyEntities)
        // The one gauge worth an alert rule: it means the bot is answering but
        // cannot promise anything it writes will still be there (§4.3).
        metric("bot_state_degraded", "1 when state is not durable and nothing is sold.", report.degraded ? 1 : 0)

        for (name, value) in report.counters.sorted(by: { $0.key < $1.key }) {
            out.append("# TYPE bot_\(name)_total counter")
            out.append("bot_\(name)_total \(value)")
        }
        out.append("# HELP bot_funnel_total Conversion-funnel events, all time.")
        out.append("# TYPE bot_funnel_total counter")
        for (event, value) in report.funnel.sorted(by: { $0.key < $1.key }) {
            out.append("bot_funnel_total{event=\"\(Self.escapeLabel(event))\"} \(value)")
        }
        out.append("# HELP bot_funnel_today Conversion-funnel events today.")
        out.append("# TYPE bot_funnel_today gauge")
        for (event, value) in report.funnelToday.sorted(by: { $0.key < $1.key }) {
            out.append("bot_funnel_today{event=\"\(Self.escapeLabel(event))\"} \(value)")
        }
        out.append("# HELP bot_alert_firing Owner alerts currently raised (§6.1).")
        out.append("# TYPE bot_alert_firing gauge")
        for alert in OwnerAlert.allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
            let firing = report.alerts.contains(alert.rawValue) ? 1 : 0
            out.append("bot_alert_firing{alert=\"\(alert.rawValue)\"} \(firing)")
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// Label values are counter keys, which include a super-admin-chosen
    /// campaign tag. Prometheus would read an unescaped quote as the end of the
    /// label and the rest as syntax.
    static func escapeLabelForTests(_ value: String) -> String { escapeLabel(value) }

    private static func escapeLabel(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }

    func metricsReport() async -> MetricsReport {
        let snapshot = await metrics.snapshot()
        let funnel = await state.funnelReport()
        let persistenceLine: String
        if let persistence {
            let status = await persistence.status()
            if let error = status.lastErrorMessage {
                persistenceLine = "error: \(error) (retry pending: \(status.pendingRetryEntities))"
            } else {
                persistenceLine = "ok (flushes: \(status.totalFlushes), entities: \(status.totalEntitiesFlushed))"
            }
        } else {
            persistenceLine = "disabled"
        }
        return MetricsReport(
            uptimeSeconds: snapshot.uptimeSeconds,
            activeGenerations: await sessionRegistry.activeCount,
            queuedChatOperations: await updateDispatcher.totalQueuedOperations,
            dirtyEntities: await state.dirtyEntityCount,
            persistence: persistenceLine,
            durability: flags.durability.value.statusLine,
            degraded: flags.durability.value.isDegraded,
            alerts: await alerter.activeAlerts().map(\.rawValue),
            counters: snapshot.counters,
            funnel: funnel.flat,
            funnelToday: funnel.todayCounters,
            funnelWeek: funnel.weekCounters
        )
    }
}
