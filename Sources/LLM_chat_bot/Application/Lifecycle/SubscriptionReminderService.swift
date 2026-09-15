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
        var walletWinbacksSent: Int = 0
        var unreachable: Int = 0
        var failed: Int = 0
        /// Due, but past this sweep's send budget — picked up by the next one.
        var deferred: Int = 0
        var skippedDisabled: Bool = false

        var sentTotal: Int { expiryRemindersSent + winbacksSent + walletWinbacksSent }

        var summaryLine: String {
            if skippedDisabled { return "выключены" }
            if due == 0 { return "нечего отправлять" }
            var parts = ["к отправке \(due)"]
            if expiryRemindersSent > 0 { parts.append("напоминаний \(expiryRemindersSent)") }
            if winbacksSent > 0 { parts.append("winback \(winbacksSent)") }
            if walletWinbacksSent > 0 { parts.append("по балансу \(walletWinbacksSent)") }
            if unreachable > 0 { parts.append("недоступны \(unreachable)") }
            if failed > 0 { parts.append("ошибок \(failed)") }
            if deferred > 0 { parts.append("отложено \(deferred)") }
            return parts.joined(separator: " · ")
        }
    }

    /// Cap group notices per sponsor per cycle: a licence covering dozens of
    /// chats must not turn one expiry into a broadcast.
    private static let maxGroupNoticesPerSponsor = 10

    /// Ceiling on the notices one sweep may send.
    ///
    /// A sweep is a background job spending the same Telegram budget live
    /// answers spend (~18 messages a second, globally): an outreach wave to a
    /// five-figure audience would hold that budget for minutes, and the sweep
    /// is serialised, so the super-admin's "проверить сейчас" would hang behind
    /// it too. Nothing is lost by stopping early — a notice is only marked
    /// after delivery and both queues are ordered deterministically, so the
    /// next sweep resumes at the same front.
    static let maxNoticesPerSweep = 200

    private let telegram: TelegramGatewayPort
    private let state: ChatContextStore
    /// Winback offers are stored money-side state (§10.2), never write-behind.
    private let subscriptions: SubscriptionWriter?

    /// Grants (and stores) a winback offer. Falls back to the cache-only path
    /// when no writer is wired — the tests and a memory-only bot, where there
    /// is nothing to store it in anyway.
    private func grantDiscount(invoker: UserKey, percent: Int, hours: Int) async -> SubscriptionDiscount? {
        if let subscriptions {
            return await subscriptions.grantWinback(key: invoker, percent: percent, hours: hours)
        }
        return await state.grantWinbackDiscount(key: invoker, percent: percent, hours: hours)
    }

    private func clearDiscount(_ invoker: UserKey) async {
        if let subscriptions {
            _ = await subscriptions.consumeWinback(key: invoker)
        } else {
            _ = await state.consumeWinbackDiscount(invoker)
        }
    }
    private let logger: LoggerPort
    private let metrics: RuntimeMetrics

    private var lastResult: SweepResult?
    private var lastRunAt: Date?
    private var sweeping = false

    init(
        telegram: TelegramGatewayPort,
        state: ChatContextStore,
        subscriptions: SubscriptionWriter? = nil,
        logger: LoggerPort,
        metrics: RuntimeMetrics
    ) {
        self.telegram = telegram
        self.state = state
        self.subscriptions = subscriptions
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
            let startedAt = Date()
            await sweep()
            // Wait in short slices instead of one long sleep: the interval is a
            // live super-admin setting, and shortening it must take effect
            // within a minute rather than after the old (possibly 24 h) sleep.
            while !Task.isCancelled {
                let minutes = await state.reminderConfig().sweepIntervalMinutes
                let due = startedAt.addingTimeInterval(Double(minutes) * 60)
                let remaining = due.timeIntervalSinceNow
                guard remaining > 0 else { break }
                let slice = min(remaining, 60)
                try? await Task.sleep(nanoseconds: UInt64(slice * 1_000_000_000))
            }
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
        var budget = SendBudget(remaining: Self.maxNoticesPerSweep)

        for target in targets {
            guard budget.take() else {
                result.deferred += 1
                continue
            }
            switch await deliver(target: target, config: config) {
            case .sent:
                await state.markNoticeSent(
            key: target.key,
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
            key: target.key,
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

        await sweepLapsedWallets(now: now, budget: &budget, into: &result)

        result.finishedAt = Date()
        lastResult = result
        lastRunAt = result.finishedAt
        if result.sentTotal > 0 || result.failed > 0 {
            logger.info("subscription reminders: \(result.summaryLine)")
        }
        return result
    }

    /// Second half of the sweep: people who paid into a pay-as-you-go balance,
    /// spent it and drifted away. A subscription expires loudly and gets a
    /// winback; a wallet just runs out, and nothing has ever said "вернитесь".
    /// One message per lapse, proven payers only (see `dueWalletWinbacks`).
    private func sweepLapsedWallets(now: Date, budget: inout SendBudget, into result: inout SweepResult) async {
        let targets = await state.dueWalletWinbacks(now: now)
        guard !targets.isEmpty else { return }
        result.due += targets.count

        for target in targets {
            guard budget.take() else {
                result.deferred += 1
                continue
            }
            switch await send(
                chatID: target.privateChatID,
                text: walletWinbackText(target: target),
                pricing: nil,
                markup: walletWinbackMarkup()
            ) {
            case .ok:
                await state.markWalletWinbackSent(key: target.key)
                result.walletWinbacksSent += 1
                await metrics.increment(MetricName.winbacksSent)
                await state.bumpFunnel(.walletWinbackSent)
            case .dead:
                // The DM is gone for good; mark it handled so the sweep stops
                // reconsidering a wallet it can never reach.
                await state.markWalletWinbackSent(key: target.key)
                result.unreachable += 1
            case .transient:
                result.failed += 1
                await metrics.increment(MetricName.reminderSendErrors)
            }
        }
    }

    private func walletWinbackText(target: WalletWinbackTarget) -> String {
        String(
            format: """
            👋 <b>Давно вас не было.</b>

            Ваш баланс закончился — умные модели снова недоступны, и бот отвечает бесплатными.

            Пополнить можно от %@: с баланса списывается стоимость каждого ответа, обычно доли цента, — этого хватает надолго. Нужен доступ без счётчика и для ваших чатов — есть премиум на месяц.
            """,
            CreditPack.label(cents: CreditPack.centsOptions.first ?? 200)
        )
    }

    private func walletWinbackMarkup() -> InlineKeyboardMarkup {
        let payAction = BotCallbackAction.menu(action: MenuRoute.purchase(from: .reminder)).rawData
        return InlineKeyboardMarkup(inline_keyboard: [[
            InlineKeyboardButton(text: "💰 Пополнить баланс", callback_data: payAction),
            InlineKeyboardButton(text: "⚡ Премиум на месяц", callback_data: payAction),
        ]])
    }

    /// What is left of this sweep's send budget. A value passed `inout` through
    /// both halves rather than a counter each half keeps for itself: the cap is
    /// on the sweep, and two independent caps are not one cap.
    private struct SendBudget {
        private(set) var remaining: Int

        mutating func take() -> Bool {
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
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
        // chat that already saw the message. Pre-expiry reminders go out on
        // the widest wave only, for the same reason.
        let publicWave: Bool
        switch target.notice {
        case .expiring(let days): publicWave = days == config.expiryReminderDays.max()
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
            discount = await grantDiscount(
                invoker: target.key,
                percent: config.winbackDiscountPercent,
                hours: config.winbackOfferHours
            )
        }
        // The sponsor's price carries their personal discount; the group's does
        // not. A winback offer belongs to one account, so quoting it to a chat
        // where anyone may tap "renew" would advertise a price the payer is not
        // going to be charged.
        let pricing = await state.subscriptionPricing(key: target.key)
        let listPricing = await state.subscriptionPricing(key: nil)
        var delivered = false
        var deadChannels = 0
        var attempted = 0

        if let chatID = target.privateChatID {
            attempted += 1
            let text = personalText(target: target, pricing: pricing, discount: discount)
            switch await send(chatID: chatID, text: text, pricing: pricing, notice: target.notice) {
            case .ok: delivered = true
            case .dead: deadChannels += 1
            case .transient: break
            }
        }
        if !groupChatIDs.isEmpty {
            let text = groupText(target: target)
            for chatID in groupChatIDs {
                attempted += 1
                switch await send(chatID: chatID, text: text, pricing: listPricing, notice: target.notice) {
                case .ok: delivered = true
                case .dead: deadChannels += 1
                case .transient: break
                }
            }
        }
        if delivered { return .sent }
        // Every channel is gone for good (blocked DM, kicked from every chat):
        // retrying next hour would burn the same 403s. The store now knows they
        // are dead, so the next cycle will not even list them.
        guard deadChannels == attempted else { return .failed }
        // The notice is about to be marked handled, and nobody saw the offer —
        // so the discount it granted is withdrawn too. Otherwise a price cut
        // nobody was ever told about waits for them at checkout.
        if discount != nil { await clearDiscount(target.key) }
        return .noChannel
    }

    private enum SendOutcome {
        case ok
        /// Permanent: the bot cannot post here any more (blocked / kicked /
        /// chat deleted). Recorded so this address stops being a channel.
        case dead
        case transient
    }

    private func send(
        chatID: ChatID,
        text: String,
        pricing: SubscriptionPricing?,
        notice: SubscriptionNotice? = nil,
        markup: InlineKeyboardMarkup? = nil
    ) async -> SendOutcome {
        let keyboard: InlineKeyboardMarkup?
        if let markup {
            keyboard = markup
        } else if let pricing, let notice {
            keyboard = buyMarkup(pricing: pricing, notice: notice)
        } else {
            keyboard = nil
        }
        do {
            _ = try await telegram.sendMessage(.init(
                chatID: chatID,
                threadID: nil,
                replyTo: nil,
                text: text,
                replyMarkup: keyboard
            ))
            return .ok
        } catch {
            logger.warning("subscription notice to chat \(chatID) failed: \(error)")
            if Self.isPermanentDeliveryFailure(error) {
                await state.setBotPresence(chatID: chatID, isMember: false)
                return .dead
            }
            return .transient
        }
    }

    /// 403 means blocked/kicked, 400 "chat not found" means the chat is gone —
    /// neither is worth another attempt. Anything else (429, 5xx, network) is
    /// retried on the next sweep.
    private static func isPermanentDeliveryFailure(_ error: Error) -> Bool {
        guard let api = error as? TelegramAPIError else { return false }
        if api.statusCode == 403 { return true }
        let text = api.descriptionText.lowercased()
        return api.statusCode == 400 && (text.contains("chat not found") || text.contains("group chat was upgraded"))
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
        let payAction = BotCallbackAction.menu(action: MenuRoute.purchase(from: .reminder)).rawData
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
            let hoursLeft = target.paidUntil.timeIntervalSinceNow / 3600
            let when = hoursLeft <= 36
                ? "Завтра"
                : "Через \(max(1, Int(ceil(hoursLeft / 24)))) дн."
            let chatsSuffix = target.groupChatIDs.isEmpty
                ? "."
                : " — и у вас, и во всех ваших чатах (\(target.groupChatIDs.count))."
            lines.append("⏳ <b>Премиум заканчивается \(until)</b>")
            lines.append("")
            lines.append("\(when) умные модели выключатся, вернутся реклама и дневной лимит\(chatsSuffix)")
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
        lines.append("<i>Не хотите такие сообщения — /menu → ⚡ Мой премиум → кнопка «Напоминания о продлении».</i>")
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
    func previewTexts(key: UserKey?) async -> [(text: String, markup: InlineKeyboardMarkup)] {
        let config = await state.reminderConfig()
        // List price: a preview must not inherit the previewing admin's own
        // live winback offer, or it stops showing what sponsors will see.
        let pricing = await state.subscriptionPricing(key: nil)
        let label = key == nil ? "—" : await state.displayLabel(forKey: key!)
        var previews: [(text: String, markup: InlineKeyboardMarkup)] = []

        for days in config.expiryReminderDays.sorted(by: >) {
            let notice = SubscriptionNotice.expiring(daysBefore: days)
            let target = SubscriptionNoticeTarget(
                key: key ?? UserKey.sanitizedPendingFallback("preview"),
                label: label,
                notice: notice,
                paidUntil: Date().addingTimeInterval(Double(days) * 86_400),
                privateChatID: nil,
                groupChatIDs: []
            )
            previews.append((
                personalText(target: target, pricing: pricing, discount: nil),
                buyMarkup(pricing: pricing, notice: notice)
            ))
        }

        // Preview discount is hypothetical — nothing is granted here, but it is
        // priced through the same store method as a real one, so the card and
        // crypto lines are as accurate as the Stars line.
        let previewDiscount = config.winbackDiscountPercent > 0
            ? SubscriptionDiscount(
                percent: config.winbackDiscountPercent,
                expiresAt: Date().addingTimeInterval(Double(config.winbackOfferHours) * 3600)
              )
            : nil
        let discountedPricing = await state.subscriptionPricing(key: nil, applying: previewDiscount)
        let winbackDay = config.winbackDays.first ?? 1
        let winbackNotice = SubscriptionNotice.winback(dayOffset: winbackDay)
        let winback = SubscriptionNoticeTarget(
                key: key ?? UserKey.sanitizedPendingFallback("preview"),
            label: label,
            notice: winbackNotice,
            paidUntil: Date().addingTimeInterval(-Double(winbackDay) * 86_400),
            privateChatID: nil,
            groupChatIDs: []
        )
        previews.append((
            personalText(target: winback, pricing: discountedPricing, discount: previewDiscount),
            buyMarkup(pricing: discountedPricing, notice: winbackNotice)
        ))
        return previews
    }
}
