import Foundation

/// Subscription lifecycle outreach (roadmap step 8): a renewal reminder before
/// a sponsor's subscription ends, then winback offers with a time-limited
/// discount after it.
///
/// The schedule comes entirely from `SubscriptionReminderConfig` (super-admin
/// editable, persisted), so nothing here is hardcoded. Every notice is
/// deduplicated per subscription cycle inside `ChatContextStore`, so a restart,
/// an extra manual sweep or a redelivery can never double-send; a notice is
/// only marked as sent once at least one delivery succeeded, so a transient
/// Telegram error is retried on the next sweep.
actor SubscriptionReminderService {
    /// Outcome of one sweep — the monitoring surface for the super-admin page.
    struct SweepResult: Sendable {
        var finishedAt: Date = Date()
        var due: Int = 0
        var expiryRemindersSent: Int = 0
        var winbacksSent: Int = 0
        var unreachable: Int = 0
        var failed: Int = 0
        var skippedDisabled: Bool = false

        var sentTotal: Int { expiryRemindersSent + winbacksSent }

        var summaryLine: String {
            if skippedDisabled { return "выключены" }
            if due == 0 { return "нечего отправлять" }
            var parts = ["к отправке \(due)"]
            if expiryRemindersSent > 0 { parts.append("напоминаний \(expiryRemindersSent)") }
            if winbacksSent > 0 { parts.append("winback \(winbacksSent)") }
            if unreachable > 0 { parts.append("недоступны \(unreachable)") }
            if failed > 0 { parts.append("ошибок \(failed)") }
            return parts.joined(separator: " · ")
        }
    }

    /// Cap group notices per sponsor per cycle: a licence covering dozens of
    /// chats must not turn one expiry into a broadcast.
    private static let maxGroupNoticesPerSponsor = 10

    private let telegram: TelegramGatewayPort
    private let state: ChatContextStore
    private let logger: LoggerPort
    private let metrics: RuntimeMetrics

    private var lastResult: SweepResult?
    private var lastRunAt: Date?
    private var sweeping = false

    init(
        telegram: TelegramGatewayPort,
        state: ChatContextStore,
        logger: LoggerPort,
        metrics: RuntimeMetrics
    ) {
        self.telegram = telegram
        self.state = state
        self.logger = logger
        self.metrics = metrics
    }

    // MARK: - Monitoring

    func status() -> (last: SweepResult?, lastRunAt: Date?) {
        (lastResult, lastRunAt)
    }

    // MARK: - Loop

    func run() async {
        // Let boot settle (state restore, webhook registration) before the
        // first pass, so a redeploy never sends from half-loaded state.
        try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
        while !Task.isCancelled {
            await sweep()
            let minutes = await state.reminderConfig().sweepIntervalMinutes
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
        }
    }

    // MARK: - Sweep

    @discardableResult
    func sweep(now: Date = Date()) async -> SweepResult {
        // The loop and the super-admin "check now" button share this actor;
        // one sweep at a time keeps the notice bookkeeping single-writer.
        guard !sweeping else { return lastResult ?? SweepResult() }
        sweeping = true
        defer { sweeping = false }

        var result = SweepResult()
        let config = await state.reminderConfig()
        guard config.enabled else {
            result.skippedDisabled = true
            result.finishedAt = Date()
            lastResult = result
            lastRunAt = result.finishedAt
            return result
        }

        await metrics.increment(MetricName.reminderSweeps)
        let targets = await state.dueSubscriptionNotices(now: now)
        result.due = targets.count

        for target in targets {
            switch await deliver(target: target, config: config) {
            case .sent:
                await state.markNoticeSent(
                    username: target.username,
                    notice: target.notice,
                    paidUntil: target.paidUntil
                )
                if target.notice.isWinback {
                    result.winbacksSent += 1
                    await metrics.increment(MetricName.winbacksSent)
                    await state.bumpFunnel(.winbackSent)
                } else {
                    result.expiryRemindersSent += 1
                    await metrics.increment(MetricName.remindersSent)
                    await state.bumpFunnel(.expiryReminder)
                }
            case .noChannel:
                // Nothing to send this notice on. Marked as handled so the
                // sweep doesn't reconsider it every hour; the count keeps
                // silent sponsors visible to the super-admin.
                await state.markNoticeSent(
                    username: target.username,
                    notice: target.notice,
                    paidUntil: target.paidUntil
                )
                result.unreachable += 1
            case .failed:
                // Telegram error — leave the notice unmarked so the next sweep
                // retries, bounded by the notice's own window.
                result.failed += 1
                await metrics.increment(MetricName.reminderSendErrors)
            }
        }

        result.finishedAt = Date()
        lastResult = result
        lastRunAt = result.finishedAt
        if result.sentTotal > 0 || result.failed > 0 {
            logger.info("subscription reminders: \(result.summaryLine)")
        }
        return result
    }

    private enum DeliveryOutcome {
        case sent
        /// Nowhere to send this notice: no DM, and no group notice for it.
        case noChannel
        case failed
    }

    private func deliver(target: SubscriptionNoticeTarget, config: SubscriptionReminderConfig) async -> DeliveryOutcome {
        // Group notice: the sponsor may be gone, but any member can renew.
        // Only the first winback wave posts publicly — later waves would nag a
        // chat that already saw the message.
        let publicWave: Bool
        switch target.notice {
        case .expiring: publicWave = true
        case .winback(let day): publicWave = day == config.winbackDays.min()
        }
        let groupChatIDs = config.notifyChats && publicWave
            ? Array(target.groupChatIDs.prefix(Self.maxGroupNoticesPerSponsor))
            : []
        guard target.privateChatID != nil || !groupChatIDs.isEmpty else { return .noChannel }

        // Winback: grant the discount before rendering, so the offer text and
        // every purchase path quote exactly the same discounted price.
        var discount: SubscriptionDiscount?
        if target.notice.isWinback, config.winbackDiscountPercent > 0 {
            discount = await state.grantWinbackDiscount(
                username: target.username,
                percent: config.winbackDiscountPercent,
                hours: config.winbackOfferHours
            )
        }
        let pricing = await state.subscriptionPricing(username: target.username)
        var delivered = false

        if let chatID = target.privateChatID {
            let text = personalText(target: target, pricing: pricing, discount: discount)
            delivered = await send(chatID: chatID, text: text, pricing: pricing, notice: target.notice)
        }
        if !groupChatIDs.isEmpty {
            let text = groupText(target: target)
            for chatID in groupChatIDs {
                let ok = await send(chatID: chatID, text: text, pricing: pricing, notice: target.notice)
                delivered = delivered || ok
            }
        }
        return delivered ? .sent : .failed
    }

    private func send(chatID: Int, text: String, pricing: SubscriptionPricing, notice: SubscriptionNotice) async -> Bool {
        do {
            _ = try await telegram.sendMessage(.init(
                chatID: chatID,
                threadID: nil,
                replyTo: nil,
                text: text,
                replyMarkup: buyMarkup(pricing: pricing, notice: notice)
            ))
            return true
        } catch {
            logger.warning("subscription notice to chat \(chatID) failed: \(error)")
            return false
        }
    }

    // MARK: - Texts

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy"
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM HH:mm"
        return f
    }()

    private func buyMarkup(pricing: SubscriptionPricing, notice: SubscriptionNotice) -> InlineKeyboardMarkup {
        let payAction = BotCallbackAction.menu(action: "nav:pay").rawData
        let priceSuffix = pricing.stars.map { " · \($0) ⭐" } ?? ""
        let label = notice.isWinback
            ? "⚡ Вернуть премиум\(priceSuffix)"
            : "🔄 Продлить\(priceSuffix)"
        return InlineKeyboardMarkup(inline_keyboard: [[
            InlineKeyboardButton(text: label, callback_data: payAction)
        ]])
    }

    /// Price line with the discount made visible — people renew on a number,
    /// not on a promise.
    private func priceLine(_ pricing: SubscriptionPricing) -> String? {
        if let stars = pricing.stars {
            if let full = pricing.starsFull, full != stars {
                return "Цена: <s>\(full) ⭐</s> <b>\(stars) ⭐</b> за \(ChatContextStore.subscriptionDays) дней."
            }
            return "Цена: <b>\(stars) ⭐</b> за \(ChatContextStore.subscriptionDays) дней."
        }
        if let cents = pricing.cryptoCents {
            let price = String(format: "$%.2f", Double(cents) / 100.0)
            if let full = pricing.cryptoCentsFull, full != cents {
                return "Цена: <s>\(String(format: "$%.2f", Double(full) / 100.0))</s> <b>\(price)</b> за \(ChatContextStore.subscriptionDays) дней."
            }
            return "Цена: <b>\(price)</b> за \(ChatContextStore.subscriptionDays) дней."
        }
        if let label = pricing.cardLabel {
            if let full = pricing.cardLabelFull, full != label {
                return "Цена: <s>\(full)</s> <b>\(label)</b> за \(ChatContextStore.subscriptionDays) дней."
            }
            return "Цена: <b>\(label)</b> за \(ChatContextStore.subscriptionDays) дней."
        }
        return nil
    }

    private func personalText(
        target: SubscriptionNoticeTarget,
        pricing: SubscriptionPricing,
        discount: SubscriptionDiscount?
    ) -> String {
        let until = Self.dateFormatter.string(from: target.paidUntil)
        var lines: [String] = []
        switch target.notice {
        case .expiring:
            let days = max(1, Int(ceil(target.paidUntil.timeIntervalSinceNow / 86_400)))
            let chatsSuffix = target.groupChatIDs.isEmpty
                ? "."
                : " — и у вас, и во всех ваших чатах (\(target.groupChatIDs.count))."
            lines.append("⏳ <b>Премиум заканчивается \(until)</b>")
            lines.append("")
            lines.append("Через \(days) дн. умные модели выключатся, вернутся реклама и дневной лимит\(chatsSuffix)")
        case .winback:
            lines.append("⛔ <b>Премиум истёк \(until).</b>")
            lines.append("")
            if let discount, discount.percent > 0 {
                let deadline = Self.dateTimeFormatter.string(from: discount.expiresAt)
                lines.append("Возвращайтесь со скидкой <b>−\(discount.percent)%</b> — предложение действует до <b>\(deadline)</b>.")
            } else {
                lines.append("Умные модели, без рекламы и лимитов — возвращаются одной оплатой.")
            }
        }
        if let priceLine = priceLine(pricing) {
            lines.append("")
            lines.append(priceLine)
        }
        lines.append("")
        lines.append("<i>Не хотите такие сообщения — /menu → 🛠 Админ-панель → кнопка «Напоминания о продлении».</i>")
        return lines.joined(separator: "\n")
    }

    private func groupText(target: SubscriptionNoticeTarget) -> String {
        let until = Self.dateFormatter.string(from: target.paidUntil)
        switch target.notice {
        case .expiring:
            return "⏳ Премиум для этого чата заканчивается <b>\(until)</b> — потом вернутся реклама и дневной лимит умных ответов. Продлить может любой участник."
        case .winback:
            return "⛔ Премиум для этого чата закончился (\(until)) — вернулись реклама и лимиты. Открыть снова умные модели для всех может любой участник."
        }
    }

    // MARK: - Preview (super-admin test send)

    /// Renders both notices for a super-admin without touching any state, so
    /// the wording and the buttons can be checked before real sends go out.
    func previewTexts(username: String?) async -> [(text: String, markup: InlineKeyboardMarkup)] {
        let config = await state.reminderConfig()
        let pricing = await state.subscriptionPricing(username: username)
        let sample = Date().addingTimeInterval(Double(max(config.daysBeforeExpiry, 1)) * 86_400)
        let expiring = SubscriptionNoticeTarget(
            username: username ?? "",
            notice: .expiring,
            paidUntil: sample,
            privateChatID: nil,
            groupChatIDs: []
        )
        let winbackDay = config.winbackDays.first ?? 1
        let winback = SubscriptionNoticeTarget(
            username: username ?? "",
            notice: .winback(dayOffset: winbackDay),
            paidUntil: Date().addingTimeInterval(-Double(winbackDay) * 86_400),
            privateChatID: nil,
            groupChatIDs: []
        )
        // Preview discount is hypothetical — nothing is granted here.
        let previewDiscount = config.winbackDiscountPercent > 0
            ? SubscriptionDiscount(
                percent: config.winbackDiscountPercent,
                expiresAt: Date().addingTimeInterval(Double(config.winbackOfferHours) * 3600)
              )
            : nil
        var discountedPricing = pricing
        if let previewDiscount {
            discountedPricing.discount = previewDiscount
            discountedPricing.stars = pricing.starsFull.map { previewDiscount.apply(to: $0) }
            discountedPricing.cryptoCents = pricing.cryptoCentsFull.map { previewDiscount.apply(to: $0) }
        }
        return [
            (
                personalText(target: expiring, pricing: pricing, discount: nil),
                buyMarkup(pricing: pricing, notice: .expiring)
            ),
            (
                personalText(target: winback, pricing: discountedPricing, discount: previewDiscount),
                buyMarkup(pricing: discountedPricing, notice: .winback(dayOffset: winbackDay))
            ),
        ]
    }
}
