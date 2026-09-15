import Foundation

// User-facing strings that appear in more than one place.
//
// A refusal copied 43 times is 43 chances for the wording to drift apart and
// 43 edits when the tone changes — and drift already happened ("🔒 Только
// админ" next to "🔒 Только администратор"). Here it is one line.
//
// **Only literals live here.** Anything that names a person, a chat or a
// model is built at the call site, where the label has already been through
// `displayLabel`/`sanitizeName` (CLAUDE.md §17). The catalog must never
// become a second, unescaped path for user-supplied text into an HTML message
// the bot signs with its own name.
enum Texts {

    // MARK: - Refusals (inline-menu toasts)

    /// Toast on a `super*` button tapped by somebody else. Toasts are short by
    /// necessity — Telegram truncates them — hence no trailing period.
    static let superAdminOnly = "🔒 Только суперадмин"
    static let rootSuperAdminOnly = "🔒 Только главный суперадмин"
    static let adminOnly = "🔒 Только администратор"
    static let notYourChat = "🔒 Не ваш чат"
    static let notYourInvoice = "🔒 Не ваш счёт"

    // MARK: - Refusals (chat messages)

    /// Sent into the chat rather than shown as a toast: a slash command has no
    /// callback to answer, so the refusal is a message and gets a full stop.
    static let superAdminOnlyCommand = "🔒 Команда только для суперадминистратора."
    static let rootSuperAdminOnlyCommand = "🔒 Команда только для главного суперадмина."
    static let adminOnlyCommand = "🔒 Команда только для администратора."
    /// Answer to a typed value from someone who may not change that setting.
    static let superAdminOnlySetting = "🔒 Это может изменить только суперадмин."

    // MARK: - Button labels

    static let cancel = "❌ Отмена"
    static let back = "← Назад"
    static let close = "✕ Закрыть"

    // MARK: - "Not found" toasts

    static let presetNotFound = "Заготовка не найдена — список изменился"
    /// The list is at `PresetList.maxCount`; the value typed was not saved.
    static let presetListFull = "⚠️ Больше \(PresetList.maxCount) заготовок в одном списке не помещается — удалите ненужную и попробуйте снова."
    static let tenantNotFound = "Тенант не найден"
    static let modelNotFound = "Модель не найдена"
    static let modeNotFound = "Режим не найден"
    /// A mode whose model cannot be resolved right now — a 🆓 mode set to "auto"
    /// while the OpenRouter catalogue is unreachable and nothing is pinned.
    static let modeUnavailable = "Режим сейчас недоступен — попробуйте позже"
    static let exampleNotFound = "Пример не найден"
    static let cannotRemove = "Нельзя удалить"
    /// "+30 дней" on an open-ended sponsor: adding a term would replace
    /// unlimited access with an expiry date, so nothing was changed.
    static let subscriptionAlreadyUnlimited = "Доступ бессрочный — продлевать нечего"
    static let unknownPack = "Неизвестный пакет"
    static let cryptoUnavailable = "Крипто-оплата недоступна"
    static let externalUnavailable = "Оплата через кассу недоступна"
    static let notFound = "Не найдено"
    static let usernameRequired = "⚠️ Нужен @username"

    /// A button whose payload no longer resolves — a menu message left over
    /// from an older build, or one whose target has since been deleted.
    static let staleButton = "Кнопка устарела — откройте меню заново: /menu"

    /// A payment credential that is stored but sealed under a different
    /// `STATE_ENCRYPTION_KEY`. Said out loud rather than shown as "не задано":
    /// the value is still in the row, so the fix is the key, not another trip
    /// to the vendor's cabinet.
    static let secretUnreadable = "🔒 <i>не читается — сменился ключ шифрования</i>"
}
