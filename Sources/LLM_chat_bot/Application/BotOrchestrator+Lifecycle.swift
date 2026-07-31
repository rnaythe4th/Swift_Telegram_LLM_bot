import Foundation

// Process lifecycle: restoring state on boot, the run loop for whichever
// transport is in use, the background sweeps, graceful shutdown, and the
// `/metrics` report that describes all of it.

extension BotOrchestrator {
    // MARK: - Boot: restore state (with one-time legacy migration)

    /// Loads state from the row-based schema; if those tables are empty and a
    /// legacy blob exists, imports it once and flushes everything as rows.
    /// On load failure the bot runs memory-only (persistence loop stays off)
    /// rather than risking partial overwrites of good data.
    func bootstrapState(rawPersistence: StatePersistencePort?) async -> Bool {
        guard let rawPersistence, let persistence else {
            logger.warning("persistence disabled (missing Supabase credentials) — state is in-memory only")
            return false
        }
        do {
            let stored = try await rawPersistence.loadEverything()
            if stored.isEmpty {
                if let legacy = try await rawPersistence.loadLegacySnapshot() {
                    await state.restoreFromSnapshot(legacy)
                    await state.markAllDirty()
                    await persistence.flushNow()
                    logger.info("migrated legacy snapshot to row schema (chats: \(legacy.contexts.count))")
                } else {
                    logger.info("no saved state found, starting fresh")
                }
            } else {
                await state.restore(from: stored)
                logger.info("state restored (chats: \(stored.contexts.count), tenants: \(stored.tenants.count))")
            }
            return true
        } catch {
            logger.error("state restore failed — running memory-only, writes disabled to protect stored data: \(error)")
            return false
        }
    }

    // MARK: - Run

    func run(mode: IntakeRunMode, intake: UpdateIntake, persistenceHealthy: Bool) async {
        activeIntake.value = intake
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
        // Renewal reminders / winback (roadmap step 8). Runs regardless of the
        // storage state: notices are deduplicated in memory too, and a
        // memory-only bot still shouldn't let subscriptions lapse silently.
        tasks.append(Task { [weak self] in
            await self?.reminderService.run()
        })
        backgroundTasks.value = tasks

        flags.ready.value = true

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
        logger.info("shutdown: state flushed, exiting")
    }


    // MARK: - Metrics report (GET /metrics)

    struct MetricsReport: Codable, Sendable {
        let uptimeSeconds: Int
        let activeGenerations: Int
        let queuedChatOperations: Int
        let dirtyEntities: Int
        let persistence: String
        let counters: [String: Int]
        /// Conversion-funnel event counts + live sponsor tallies (roadmap step 7).
        let funnel: [String: Int]
        /// The same events over the last day / 7 days: a total says how big,
        /// a window says whether it is moving.
        let funnelToday: [String: Int]
        let funnelWeek: [String: Int]
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
            counters: snapshot.counters,
            funnel: funnel.flat,
            funnelToday: funnel.todayCounters,
            funnelWeek: funnel.weekCounters
        )
    }
}
