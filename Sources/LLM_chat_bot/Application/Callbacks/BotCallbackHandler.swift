import Foundation

final class BotCallbackHandler: Sendable {
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
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: Texts.staleButton)
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
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: Texts.staleButton)
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
        case .example:
            // Onboarding examples start a generation, so the orchestrator takes
            // them off the callback fast path before this handler is reached.
            // Landing here means that routing was bypassed — fail visibly.
            logger.warning("onboarding example callback reached the fast path")
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Не получилось — попробуйте ещё раз")
        }
    }

    static let faqText: String = """
<b>📘 Инструкция</b>

Просто пишите боту — он ответит. Понимает текст, картинки, голос и видео, помнит разговор.

Всё настраивается двумя способами: кнопками в /menu или командой. Кнопки удобнее, команды быстрее.

<b>━━━ ⚙️ Как настроить бота под себя ━━━</b>

<b>Режимы</b> — готовые связки настроек. Один тап меняет всё сразу: и модель, и стиль ответа, и память. Не нужно ни в чём разбираться — выберите, что подходит задаче.
/menu → кнопка режима
🆓 — работает у всех · ⭐ — с премиумом или балансом
Не понравилось — «↺ Рабочий режим» вернёт проверенный.

<b>🎭 Роль</b> — кем бот себя считает и как разговаривает. Нужен строгий редактор или весёлый собеседник — опишите словами.
/menu → 🎭 Роль · команда <code>/setrole &lt;текст&gt;</code>
<blockquote>/setrole Ты — эксперт по математике, отвечай кратко.</blockquote>

<b>🤖 Модель</b> — какой именно ИИ отвечает. Бесплатные (🆓) доступны всем, умные (⭐) — по премиуму или с баланса.
/menu → 🤖 Модель · команда <code>/model &lt;id&gt;</code>

<b>⚙️ Тонкая настройка</b> — стиль ответа и обдумывание по отдельности, если готовых режимов мало. Открывается с премиумом или балансом.
/menu → ⚙️ Тонкая настройка · команды <code>/settemp 0.0–2.0</code>, <code>/reasoning быстро|средне|глубоко|выкл</code>

Начать заново: <code>/clear_history</code> — забыть переписку · <code>/reset</code> — вернуть стандартные настройки · <code>/history</code> — что бот помнит.

<b>━━━ 📊 Что показывать под ответом ━━━</b>

Бот может подписывать каждый ответ: сколько текста обработано, сколько это стоило и какая модель отвечала.
/menu → 📊 Что показывать в ответе
Команды: <code>/show_tokens</code> · <code>/show_cost</code> · <code>/show_model</code> · <code>/reset_stats</code> — обнулить счётчик этого чата.

<b>━━━ 💳 Сколько это стоит ━━━</b>

Бесплатные модели доступны всегда и без ограничений. Умные модели открываются двумя способами — выбирайте любой.

<b>⚡ Премиум на 30 дней</b> — все модели, без рекламы и без дневных лимитов. Одна оплата открывает доступ и в вашей личке, и во всех ваших чатах — сразу для всех участников.
<code>/buy</code>

<b>💰 Баланс</b> — как счёт на телефоне: вы его пополняете, а с него списывается стоимость каждого ответа. Обычно это доли цента, так что $2 хватает надолго. Подписка не нужна — платите только за то, чем пользуетесь.
<code>/balance</code>

<b>🎁 Бесплатно</b> — пригласить друга. Он переходит по вашей ссылке и задаёт первый вопрос — бонус на баланс приходит вам обоим.
<code>/ref</code>

Оплатить можно звёздами Telegram, картой или криптовалютой — доступные способы бот покажет сам. При оплате криптой отправьте <b>ровно</b> ту сумму, что он показал: именно по ней бот узнаёт ваш платёж.

<b>━━━ 👥 Умный ИИ в вашей группе ━━━</b>

Добавьте бота в групповой чат — там он отвечает на @упоминание или на реплай своего сообщения.

🎧 <b>Прослушка беседы</b> — бот читает разговор целиком и отвечает, зная, о чём речь: /menu → 🎧 или <code>/listen on</code>.

Премиум для группы может открыть любой участник, и умные модели заработают сразу у всех. Того, кто это сделал, бот отмечает под ответами: заплатил один — пользуются все.

<b>━━━ ⚡ Если премиум у вас ━━━</b>

/menu → <b>⚡ Мой премиум</b>. Там видно, до какой даты всё оплачено, и можно:
• включить или выключить премиум в текущем чате
• посмотреть список чатов, где он работает
• пригласить человека по ссылке — умные модели заработают у него за ваш счёт
• задать, что включается в новых чатах: модель, роль, память

За несколько дней до конца бот напомнит о продлении. Напоминания выключаются там же кнопкой.

<b>━━━ 🛠 Прочее ━━━</b>

<code>/menu</code> — настройки и текущие параметры чата · <code>/examples</code> — готовые примеры в один тап · <code>/chatid</code> — номер этого чата · <code>/help</code> — эта инструкция
"""
}
