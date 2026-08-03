import Foundation

/// What the owner needs to hear about, unprompted.
enum OwnerAlert: String, Sendable, CaseIterable {
    /// Writes have been failing for a while.
    case databaseDown
    /// Running memory-only: nothing survives a restart and nothing is sold (§4.3).
    case volatileMode
    /// We are the second instance and have been for a while (§3.1).
    case notWriter
    /// `sum(bot_ledger) != bot_wallet.balance` somewhere (§2.3).
    case ledgerMismatch
    /// The OpenRouter catalogue has been unreachable long enough that every
    /// paid model is being treated as capped.
    case modelCatalogueDown
    /// A spending ceiling stopped paid models (§4.1).
    case spendCapReached

    var title: String {
        switch self {
        case .databaseDown: return "🛑 База данных не отвечает"
        case .volatileMode: return "⚠️ Бот работает без хранилища"
        case .notWriter: return "ℹ️ Эта копия бота — не основная"
        case .ledgerMismatch: return "🛑 Расхождение в журнале балансов"
        case .modelCatalogueDown: return "⚠️ Каталог моделей недоступен"
        case .spendCapReached: return "⏸ Достигнут дневной лимит расходов"
        }
    }

    /// What it means and what to do — the owner is on their own here, so a
    /// symptom without a next step is only half a message.
    var advice: String {
        switch self {
        case .databaseDown:
            return "Запись состояния падает. Продажи отключены, ответы продолжаются. Проверьте DATABASE_URL и статус базы."
        case .volatileMode:
            return "Состояние живёт только в памяти и пропадёт при перезапуске. Покупки не принимаются — это намеренно."
        case .notWriter:
            return "Другой процесс держит блокировку писателя. Обычно это старый инстанс, который вот-вот выключится; если нет — проверьте число реплик."
        case .ledgerMismatch:
            return "У части кошельков сумма журнала не сходится с остатком. Деньги не потеряны, но объяснить остаток нечем — нужна проверка."
        case .modelCatalogueDown:
            return "Список бесплатных моделей не обновляется, поэтому все платные модели считаются платными и работают по дневному лимиту."
        case .spendCapReached:
            return "Умные модели переключены на бесплатные до конца суток. Поднять потолок — /menu → 🛡 Супер-админ."
        }
    }
}

/// Sends each incident to the owners once, and its recovery once (§6.1).
///
/// The bot has one owner and no on-call rotation: a failed restore, an
/// unreachable model catalogue, a ledger that stopped adding up are all just
/// lines in Railway's stdout, which nobody reads. The first signal today is a
/// complaint or an invoice.
///
/// Deduplication is the whole design. An alerter that repeats itself is muted
/// on day two, and a muted alerter is worse than none — so: one message when an
/// incident starts, one when it clears, and never more than one per hour per
/// kind even if it flaps. State is in memory; a restart costs at most one
/// duplicate message.
actor OwnerAlerter {
    /// One condition that is currently on: when it started, and whether the
    /// owner was actually **told** it started.
    ///
    /// The two travel in one value because the recovery message is only honest
    /// for an incident that was announced. A "✅ Восстановлено" for something
    /// nobody ever heard about is pure noise — and worse, it is unbounded
    /// noise: the announcement is rate-limited, so a condition flapping every
    /// few minutes used to be silent on the way up and chatty on the way down.
    private struct Incident {
        let since: Date
        var announced: Bool
    }

    private let telegram: TelegramGatewayPort
    private let state: ChatContextStore
    private let logger: LoggerPort

    private var incidents: [OwnerAlert: Incident] = [:]
    /// One announcement attempt per kind per hour — the flood bound. It counts
    /// attempts rather than deliveries, so an unreachable owner does not turn
    /// into a retry loop, and an incident that could not be delivered is tried
    /// again on the next hour instead of being remembered as told.
    private var attempts = AnnouncementThrottle<OwnerAlert>(interval: OwnerAlerter.repeatInterval)

    static let repeatInterval: TimeInterval = 3600
    /// Upstream error text is quoted, not retold: long enough to identify the
    /// failure, short enough that it cannot push the message past Telegram's
    /// 4096.
    private static let maxDetailChars = 500

    init(telegram: TelegramGatewayPort, state: ChatContextStore, logger: LoggerPort) {
        self.telegram = telegram
        self.state = state
        self.logger = logger
    }

    /// Reports the current state of one condition. Only transitions are sent.
    func report(_ alert: OwnerAlert, active: Bool, detail: String? = nil, now: Date = Date()) async {
        guard active else {
            // Recovery belongs to the incident that was announced. An incident
            // suppressed by the throttle ends the way it began — quietly.
            guard let incident = incidents.removeValue(forKey: alert), incident.announced else { return }
            let minutes = max(1, Int(now.timeIntervalSince(incident.since) / 60))
            _ = await send("<b>✅ Восстановлено:</b> \(alert.title)\n\n<i>длилось ~\(minutes) мин</i>")
            return
        }
        if incidents[alert]?.announced == true { return }
        if incidents[alert] == nil { incidents[alert] = Incident(since: now, announced: false) }
        guard attempts.claim(alert, now: now) else { return }
        let body = "<b>\(alert.title)</b>\n\n\(alert.advice)" + Self.detailLine(detail)
        if await send(body) { incidents[alert]?.announced = true }
    }

    /// What is firing right now — reported in `/metrics`, so an external
    /// monitor can see the incidents even in the window where the owner's own
    /// message was throttled away.
    func activeAlerts() -> [OwnerAlert] { OwnerAlert.allCases.filter { incidents[$0] != nil } }

    /// The detail is somebody else's words — a Postgres error, a NIO
    /// description, a connection string — and it is going into an HTML message.
    /// A single `&` in it is enough for Telegram to reject the send outright,
    /// which would silence exactly the alert that says the database is
    /// unreachable.
    private static func detailLine(_ detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return "" }
        let clipped = detail.count > maxDetailChars
            ? String(detail.prefix(maxDetailChars)) + "…"
            : detail
        return "\n\n<i>\(MessageText.escaped(clipped))</i>"
    }

    /// True when at least one owner actually received it. A failed send is not
    /// queued: the caller either records it as unannounced (and the throttle
    /// offers another attempt next hour) or it was a recovery, which is
    /// worthless late anyway.
    private func send(_ text: String) async -> Bool {
        // Every super-admin's DM, the same channel the model-price monitor uses.
        let chats = await state.superAdminPrivateChats()
        guard !chats.isEmpty else {
            logger.warning("owner alert not delivered — no super-admin has ever written to the bot: \(text)")
            return false
        }
        var delivered = false
        for chat in chats {
            do {
                _ = try await telegram.sendMessage(.init(
                    chatID: chat.chatID, threadID: nil, replyTo: nil, text: text, replyMarkup: nil
                ))
                delivered = true
            } catch {
                logger.warning("owner alert to chat \(chat.chatID) failed: \(error)")
            }
        }
        return delivered
    }
}
