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
    private let telegram: TelegramGatewayPort
    private let state: ChatContextStore
    private let logger: LoggerPort

    private var firing: [OwnerAlert: Date] = [:]
    private var lastSentAt: [OwnerAlert: Date] = [:]

    static let repeatInterval: TimeInterval = 3600

    init(telegram: TelegramGatewayPort, state: ChatContextStore, logger: LoggerPort) {
        self.telegram = telegram
        self.state = state
        self.logger = logger
    }

    /// Reports the current state of one condition. Only transitions are sent.
    func report(_ alert: OwnerAlert, active: Bool, detail: String? = nil, now: Date = Date()) async {
        if active {
            guard firing[alert] == nil else { return }
            if let last = lastSentAt[alert], now.timeIntervalSince(last) < Self.repeatInterval {
                // Flapping: remember that it is on, but do not say so again.
                firing[alert] = now
                return
            }
            firing[alert] = now
            lastSentAt[alert] = now
            await send("<b>\(alert.title)</b>\n\n\(alert.advice)" + (detail.map { "\n\n<i>\($0)</i>" } ?? ""))
        } else {
            guard let since = firing.removeValue(forKey: alert) else { return }
            let minutes = max(1, Int(now.timeIntervalSince(since) / 60))
            await send("<b>✅ Восстановлено:</b> \(alert.title)\n\n<i>длилось ~\(minutes) мин</i>")
        }
    }

    /// What is firing right now — reported in `/metrics`, so an external
    /// monitor can see the same incidents the owner was messaged about.
    func activeAlerts() -> [OwnerAlert] { OwnerAlert.allCases.filter { firing[$0] != nil } }

    private func send(_ text: String) async {
        // Every super-admin's DM, the same channel the model-price monitor
        // uses. A failed send is not retried: the next transition will say it
        // again, and an alerter that queues is an alerter that floods.
        let chats = await state.superAdminPrivateChats()
        guard !chats.isEmpty else {
            logger.warning("owner alert not delivered — no super-admin has ever written to the bot: \(text)")
            return
        }
        for chat in chats {
            _ = try? await telegram.sendMessage(.init(
                chatID: chat.chatID, threadID: nil, replyTo: nil, text: text, replyMarkup: nil
            ))
        }
    }
}
