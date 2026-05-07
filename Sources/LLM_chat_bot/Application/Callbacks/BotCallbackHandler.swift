import Foundation

final class BotCallbackHandler: @unchecked Sendable {
    private let telegram: TelegramGatewayPort
    private let state: ChatContextStore
    private let sessionRegistry: SessionRegistry
    private let logger: LoggerPort
    private let menuHandler: BotMenuHandler
    
    init(
        telegram: TelegramGatewayPort,
        state: ChatContextStore,
        sessionRegistry: SessionRegistry,
        logger: LoggerPort,
        menuHandler: BotMenuHandler
    ) {
        self.telegram = telegram
        self.state = state
        self.sessionRegistry = sessionRegistry
        self.logger = logger
        self.menuHandler = menuHandler
    }
    
    func handleIfSupported(_ callback: CallbackQuery) async {
        guard let data = callback.data else {
            return
        }
        
        guard let action = BotCallbackAction(rawData: data) else {
            logger.warning("callback parse failed, raw=\(data)")
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Неизвестное действие")
            return
        }
        
        switch action {
        case .stop(let generationID):
            guard let chatKey = await sessionRegistry.cancel(generationID: generationID, reason: .userRequested) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Уже готово")
                return
            }

            await state.cancelPendingTurn(chatKey: chatKey, generationID: generationID)

            if let message = callback.message {
                try? await telegram.editMessage(
                    .init(
                        chatID: message.chat.id,
                        messageID: message.message_id,
                        text: (message.text ?? "") + "\n\n⏹ <i>Остановлено</i>",
                        replyMarkup: InlineKeyboardMarkup(inline_keyboard: [])
                    )
                )
            }

            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Остановлено")
            
        case .menu(let action):
            await menuHandler.handle(action: action, callback: callback)
        case .faq:
            guard let message = callback.message else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Сообщение недоступно")
                return
            }
            let chatKey = ChatKey(chatID: message.chat.id, threadID: message.message_thread_id ?? 0)
            _ = try? await telegram.sendMessage(.init(
                chatID: chatKey.chatID,
                threadID: chatKey.threadID == 0 ? nil : chatKey.threadID,
                replyTo: nil,
                text: Self.faqText,
                replyMarkup: nil
            ))
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: nil)
        }
    }
    
    static let faqText: String = """
<b>📘 Инструкция</b>

Просто пишите сообщения — бот ответит. Понимает текст, картинки, голос, видео.

Большинство настроек проще менять через <b>/menu</b>. Команды ниже — на случай, если хочется быстро.

<b>━━━ 💬 Чат ━━━</b>

<code>/setrole &lt;текст&gt;</code> — задать характер бота (история очищается)
<blockquote>/setrole Ты — эксперт по математике, отвечай кратко.</blockquote>

<code>/default_role</code> — вернуть стандартную роль
<code>/clear_history</code> — забыть историю, роль сохранить
<code>/history</code> — показать что бот помнит

<b>━━━ 🤖 Модель и поведение ━━━</b>

<code>/model &lt;id&gt;</code> — сменить модель (история очищается)
<blockquote>/model openai/gpt-4o</blockquote>

<code>/settemp &lt;0.0–2.0&gt;</code> — креативность (0 — точно, 2 — хаотично)
<code>/historylength &lt;1–50&gt;</code> — сколько сообщений помнить
<code>/provider &lt;deepseek|openrouter|yandex&gt;</code> — сменить провайдера
<code>/reasoning &lt;low|medium|high|off&gt;</code> — глубина размышлений (если поддерживается)

<b>━━━ 📊 Что показывать в ответе ━━━</b>

<code>/show_tokens</code> · <code>/show_cost</code> · <code>/show_model</code>
<code>/backup_notify</code> — уведомлять о бэкапах состояния

<b>━━━ 🛠 Прочее ━━━</b>

<code>/menu</code> — интерактивные настройки (там же текущие параметры чата)
<code>/help</code> — эта справка
<code>/reset</code> — сбросить чат к стандарту
<code>/testmode</code> — добавить суффикс к командам для тестов

<b>━━━ 💳 Покупка доступа ━━━</b>

<code>/buy</code> — открыть выбор способа оплаты.

Если включён только один способ — бот сразу его предложит. Если оба — покажет кнопки.

<b>💫 Telegram Stars</b>
Оплата прямо в Telegram. После успешной оплаты доступ активируется автоматически.

<b>🪙 Криптовалюта</b>
Поддерживаются: TON (native), USDT на TON, BSC (BEP20), Ethereum (ERC20), Tron (TRC20).

После выбора сети бот покажет:
• <b>адрес</b> для перевода
• <b>точную сумму</b> к оплате
• таймер — счёт живёт <b>30 минут</b>

<b>⚠️ Важно: отправьте РОВНО указанную сумму.</b>
Сумма уникальна — по ней бот находит ваш счёт. Если отправить меньше — бот напишет, сколько ещё доплатить на тот же адрес. Если больше — лишнее не возвращается автоматически (пишите админу).

В режиме <i>уникального адреса</i> сумма у всех одинаковая, но каждому счёту выдаётся свой адрес — отправляйте сколько указано на тот адрес, что показал бот.

Бот опрашивает блокчейны каждые 30 секунд. После подтверждения транзакции (обычно 1–3 минуты) бот пришлёт сообщение и активирует доступ.

Кнопки счёта:
• <b>🔄 Обновить</b> — перечитать статус
• <b>❌ Отменить</b> — закрыть счёт (только свой)

Если не хватает <code>@username</code> в Telegram — установите его в настройках, иначе покупка невозможна.
"""
}
