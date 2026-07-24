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
        case .example:
            // Onboarding examples start a generation, so the orchestrator takes
            // them off the callback fast path before this handler is reached.
            // Landing here means that routing was bypassed — fail visibly.
            logger.warning("onboarding example callback reached the fast path")
            try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Попробуйте ещё раз")
        }
    }
    
    static let faqText: String = """
<b>📘 Инструкция</b>

Просто пишите сообщения — бот ответит. Понимает текст, картинки, голос, видео.

Любую настройку можно поменять <b>двумя способами</b>: кнопками в /menu или командой. Кнопки удобнее, команды быстрее. Свои значения (роль, модель, температура, длина истории) вводятся и кнопкой «✏️» в соответствующем разделе меню.

<b>━━━ 💬 Чат ━━━</b>

<code>/setrole &lt;текст&gt;</code> — задать характер бота (история очищается)
<blockquote>/setrole Ты — эксперт по математике, отвечай кратко.</blockquote>

<code>/default_role</code> — вернуть стандартную роль
<code>/clear_history</code> — забыть историю, роль сохранить
<code>/history</code> — показать что бот помнит (кнопка «📜 Показать историю» в /menu → История)

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
<code>/reset_stats</code> — обнулить счётчик токенов/стоимости (или кнопка «🗑 Сбросить статистику»)

<b>━━━ 🛠 Прочее ━━━</b>

<code>/menu</code> — интерактивные настройки (там же текущие параметры чата)
<code>/examples</code> — готовые примеры-запросы: нажали кнопку — бот сразу ответил
<code>/help</code> — эта справка
<code>/reset</code> — сбросить чат к стандарту
<code>/testmode</code> — суффикс к командам для тестов (или тумблер в /menu → Что показывать)

<b>━━━ 💳 Покупка доступа ━━━</b>

Кнопкой: /menu → <b>💳 Полный доступ</b> — статус подписки, баланс и способы оплаты в одном месте.

<code>/buy</code> — купить или продлить подписку (действует 30 дней, при продлении срок прибавляется).
<code>/balance</code> — личный баланс: альтернатива подписке, оплата за каждый ответ по факту. Стоимость ответа видна в футере (включите /show_cost), остаток — там же.
<code>/ref</code> — своя ссылка-приглашение: друг переходит по ней и пишет первый вопрос — вам обоим падает бонус на баланс.

Если включён только один способ оплаты — бот сразу его предложит. Если оба — покажет кнопки.

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

<b>━━━ 🏢 Ваш премиум-доступ (после оплаты) ━━━</b>

После покупки вы становитесь <b>спонсором</b> — умный ИИ открывается для чата, где прошла оплата, и для вашей лички. Доступ можно расширить на другие чаты и пользователей.

<b>Через меню:</b> /menu → <b>🛠 Админ-панель</b>
• <b>📌 Привязать этот чат</b> / <b>Отвязать</b> — управление текущим чатом
• <b>📋 Чаты лицензии</b> — список + быстрая отвязка
• <b>👥 Пользователи</b> — лицензированные @username

<b>Через команды:</b>
<code>/tenant invite</code> — 🔗 пригласительная ссылка: кто откроет — получит доступ за ваш счёт
<code>/tenant claim</code> — привязать текущий чат к вашей лицензии
<code>/tenant release</code> — отвязать
<code>/tenant assign @username &lt;chatID&gt;</code> — привязать чат вручную
<code>/tenant unassign &lt;chatID&gt;</code> — отвязать чат
<code>/tenant chats</code> — список чатов лицензии
<code>/tenant adduser @username</code> — дать @пользователю доступ к платным моделям
<code>/tenant removeuser @username</code> — забрать доступ
<code>/tenant users</code> — список лицензированных пользователей
<code>/chatid</code> — узнать ID текущего чата (доступно всем)

<b>Автопривязка:</b> добавьте бота в групповой чат — чат автоматически попадёт в вашу лицензию (если ещё не привязан к другому админу). В личных чатах: участники из <code>/tenant adduser</code> получают полный доступ к платным моделям через бота.

<b>Глобальные пресеты</b> (для всех чатов вашей лицензии) редактируются на админ-панели; обычные пресеты чата — кнопкой «⚙️ Управление пресетами» в каждом разделе меню.

<b>━━━ 🛡 Суперадмин ━━━</b>

Главный владелец бота (@maythe4th) задаёт цены и настройки оплаты, ведёт список суперадминов и видит статистику по всем tenants.

<code>/superadmin add @username</code> · <code>remove</code> · <code>list</code> — управление списком (только @maythe4th).
<code>/tenant list</code> · <code>/tenant stats</code> — все tenants и расход токенов / $.
<code>/tenant cryptoinvoices</code> — открытые крипто-счета.
<code>/simulate admin|user|off|status</code> — симуляция роли для отладки.

Все эти действия также доступны кнопками: /menu → <b>🛡 Супер-админ</b> → «🛡 Суперадмины», «🏢 Tenants» (нажмите на tenant — продление и управление подпиской), «💰 Балансы», «💹 Наценка», «🎭 Симуляция», «🪙 Открытые счета».
"""
}
