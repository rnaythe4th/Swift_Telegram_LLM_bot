import Foundation

// Reference pages: the admin help text and the super-admin sections.

extension BotMenuHandler {
    /// Super-admin reference, split by topic.
    func processHelpAction(
        command: String,
        parts: [String],
        chatKey: ChatKey,
        callback: CallbackQuery,
        message: MaybeInaccessibleMessage
    ) async throws {
        switch command {
        case "sahelp":
            // One topic of the super-admin reference (the whole text does not
            // fit in a single Telegram message).
            guard await state.isSuperAdmin(username: invokerKey(callback)) else {
                try? await telegram.answerCallback(callbackQueryID: callback.id, text: "🔒 Только суперадмин")
                return
            }
            guard parts.count >= 2, let section = SuperHelpSection(rawValue: parts[1]) else {
                try await showPage(.superAdminHelp, chatKey: chatKey, callback: callback, message: message)
                return
            }
            let (helpText, helpMarkup) = renderSuperAdminHelpSection(section)
            try await editOrAnswer(callback: callback, message: message, text: helpText, markup: helpMarkup)
            return

        default:
            break
        }
    }

    func renderAdminHelp() -> (String, InlineKeyboardMarkup) {
        let rows: [[InlineKeyboardButton]] = [
            [menuButton("← К моему премиуму", action: "nav:admin")],
        ]
        return (Self.adminHelpText, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    /// Index of the super-admin reference. The whole text is far past
    /// Telegram's 4096-character ceiling, and `editMessage` cannot split a
    /// message — it silently trims to the first chunk, so half the reference
    /// used to be invisible with no hint that anything was missing. One page
    /// per topic keeps every section whole and makes it findable.
    func renderSuperAdminHelp() -> (String, InlineKeyboardMarkup) {
        var rows: [[InlineKeyboardButton]] = SuperHelpSection.allCases.map {
            [menuButton($0.buttonLabel, action: "sahelp:\($0.rawValue)")]
        }
        rows.append([menuButton("← К супер-админу", action: "nav:superadmin")])
        let text = """
        <b>🛡 Справка супер-админа</b>

        Любая настройка имеет и кнопку, и команду: кнопки удобнее, команды быстрее.

        Выберите раздел:
        \(SuperHelpSection.allCases.map { "• \($0.title)" }.joined(separator: "\n"))
        """
        return (text, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    private func renderSuperAdminHelpSection(_ section: SuperHelpSection) -> (String, InlineKeyboardMarkup) {
        let rows: [[InlineKeyboardButton]] = [
            [menuButton("← К разделам справки", action: "nav:superadminhelp")],
            [menuButton("🛡 К супер-админу", action: "nav:superadmin")],
        ]
        return (section.body, InlineKeyboardMarkup(inline_keyboard: rows))
    }

    static let adminHelpText: String = """
<b>⚡ Как пользоваться премиумом</b>

Всё, что тут описано, есть и кнопками в панели, и командами. Кнопки удобнее, команды быстрее.

<b>━━━ 📌 Где работает премиум ━━━</b>

Ваш премиум действует в личке с ботом и в тех чатах, которые вы отметили. В таком чате умные модели доступны <b>всем участникам</b> — платите только вы.

Чтобы включить премиум в чате, достаточно добавить туда бота: он подхватит доступ сам. Либо откройте нужный чат и нажмите «📌 Включить премиум здесь».

<b>Проще всего поделиться доступом</b> — ссылка-приглашение (<code>/tenant invite</code>). Кто по ней придёт, получит умные модели за ваш счёт — никаких номеров вводить не нужно.

Команды: <code>/tenant claim</code> — включить премиум здесь · <code>/tenant release</code> — выключить · <code>/tenant chats</code> — список чатов · <code>/tenant adduser @username</code> и <code>/tenant removeuser @username</code> — добавить или убрать гостя · <code>/tenant users</code> — список гостей · <code>/chatid</code> — номер и статус текущего чата.

<b>━━━ 💳 Оплата и продление ━━━</b>

Премиум действует \(ChatContextStore.subscriptionDays) дней. Продление — снова /buy: новый срок прибавляется к текущему, ничего не сгорает.

Если премиум закончился, ваши чаты и гости временно возвращаются к бесплатным моделям. Все настройки и списки при этом сохраняются — после оплаты всё включается обратно.

За несколько дней до конца бот напомнит. Кнопка «🔔 Напоминания о продлении» выключает эти сообщения лично для вас.

<b>━━━ 👤 Гости этого чата ━━━</b>

Отдельным людям можно открыть умные модели в конкретном чате — по их номеру в Telegram.
<code>/whitelist add &lt;номер&gt;</code> · <code>/whitelist remove &lt;номер&gt;</code> · <code>/whitelist list</code>

<b>━━━ ⚙️ Что включается в новых чатах ━━━</b>

Задайте модель, память и роль, с которыми бот стартует в каждом новом вашем чате.
<code>/defaults</code> — посмотреть · <code>/defaults model &lt;название&gt;</code> · <code>/defaults role &lt;текст&gt;</code> · <code>/defaults historylength &lt;1–50&gt;</code>

<b>━━━ 📋 Общие заготовки ━━━</b>

Готовые варианты модели, роли, стиля ответа и памяти — появятся кнопками во всех ваших чатах.

Типы: <code>model</code>, <code>temp</code>, <code>history</code>, <code>role</code>
<code>/presets &lt;тип&gt; add &lt;название&gt; | &lt;значение&gt;</code>
<code>/presets &lt;тип&gt; remove &lt;значение&gt;</code>
<code>/presets &lt;тип&gt; list</code>
<blockquote>/presets model add GPT-4o | openai/gpt-4o</blockquote>

<b>━━━ 📋 Посмотреть ━━━</b>

<code>/chats</code> — все чаты бота · <code>/users</code> — кто пишет в личке
"""
}
