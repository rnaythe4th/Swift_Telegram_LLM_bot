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
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "Уже завершено")
                return
            }
            
            await state.cancelPendingTurn(chatKey: chatKey, generationID: generationID)
            
            if let message = callback.message {
                try? await telegram.editMessage(
                    .init(
                        chatID: message.chat.id,
                        messageID: message.message_id,
                        text: (message.text ?? "") + "\n\n🛑 Остановлено пользователем.",
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
            let chatKey = ChatKey(chatID: message.chat.id, threadID: 0)
            try? await telegram.sendMessage(.init(
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
<b>Инструкция по использованию бота</b>

<b>Команды для всех пользователей:</b>

/setrole #Роль# — установить роль боту (очищает историю).
Пример: <blockquote>/setrole Ты — эксперт по математике. Отвечай кратко.</blockquote>

/clear_history — очистить историю сообщений, роль сохраняется.

/settemp #число# — задать температуру (креативность). 0.0 — точность, 2.0 — креативность. По умолчанию: 1.5.
Пример: <blockquote>/settemp 1.0</blockquote>

/model #модель# — сменить модель ИИ (очищает историю).
Пример: <blockquote>/model openai/gpt-4o</blockquote>

/provider #deepseek|openrouter|yandex# — сменить провайдера.
Пример: <blockquote>/provider openrouter</blockquote>

/show_tokens — вкл/выкл показ расхода токенов после ответа.

/show_cost — вкл/выкл показ стоимости сообщения в USD.

/show_model — вкл/выкл показ названия модели после ответа.

/historylength #число# — сколько последних сообщений помнит бот (1-50). По умолчанию: 11.
Пример: <blockquote>/historylength 20</blockquote>

/default_role — вернуть стандартную роль и очистить историю.

/reasoning [low|medium|high|off] — управление режимом размышлений (доступно на поддерживающих провайдерах).
Пример: <blockquote>/reasoning off</blockquote>

/menu — открыть интерактивное меню с кнопками.

/history — показать текущую историю сообщений.

/reset — сбросить все настройки чата к значениям по умолчанию.

/testmode — вкл/выкл режим тестирования (добавляет суффикс к командам).

/help — показать текущие настройки чата.

/faq — открыть эту инструкцию.


<b>Команды для администраторов:</b>

/whitelist add #ID# — добавить пользователя в белый список.
Пример: <blockquote>/whitelist add 123456789</blockquote>

/whitelist remove #ID# — удалить пользователя из белого списка.
Пример: <blockquote>/whitelist remove 123456789</blockquote>

/whitelist list — показать белый список.

/defaults model #модель# — задать модель по умолчанию для новых чатов.
Пример: <blockquote>/defaults model openai/gpt-4o-mini</blockquote>

/defaults role #роль# — задать роль по умолчанию.
Пример: <blockquote>/defaults role Ты — полезный ассистент.</blockquote>

/defaults historylength #число# — задать длину истории по умолчанию.
Пример: <blockquote>/defaults historylength 15</blockquote>

/defaults — показать текущие значения по умолчанию.

/presets model add #название# | #значение# — добавить пресет модели в меню.
Пример: <blockquote>/presets model add GPT-4o | openai/gpt-4o</blockquote>

/presets model remove #значение# — удалить пресет модели.
/presets model list — показать пресеты моделей.

/presets temp add #название# | #значение# — добавить пресет температуры.
/presets temp remove #значение# — удалить пресет температуры.
/presets temp list — показать пресеты температуры.

/presets history add #название# | #значение# — добавить пресет длины истории.
/presets history remove #значение# — удалить пресет длины истории.
/presets history list — показать пресеты длины истории.

/presets role add #название# | #значение# — добавить пресет роли.
/presets role remove #значение# — удалить пресет роли.
/presets role list — показать пресеты ролей.

/chats — показать список всех чатов (групповых и личных).

/users — показать список пользователей в личных чатах.
"""
}
