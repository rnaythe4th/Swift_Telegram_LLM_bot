import Foundation

// What a menu page *is*: a body and a keyboard.
//
// Forty-three renderers used to return an unlabelled `(String,
// InlineKeyboardMarkup)`, so every caller re-invented the names — and the
// tuple carries no invariant. A page has one that nothing enforced: it must
// fit in a single Telegram message, because `editMessage` cannot be split in
// two and quietly truncates the rest (CLAUDE.md §13). That check now lives on
// the type and is applied at the one place a page is sent.

struct MenuScreen {
    let text: String
    let keyboard: [[InlineKeyboardButton]]

    init(_ text: String, _ keyboard: [[InlineKeyboardButton]] = []) {
        self.text = text
        self.keyboard = keyboard
    }

    init(_ text: String, _ keyboard: Keyboard) {
        self.init(text, keyboard.rows)
    }

    var markup: InlineKeyboardMarkup { InlineKeyboardMarkup(inline_keyboard: keyboard) }

    /// A page longer than this does not come back shortened — it comes back
    /// with the tail missing, which reads as settings that are not there.
    ///
    /// Measured in UTF-16 code units, because that is what Telegram counts and
    /// what the gateway decides by: every menu page is emoji from its first
    /// line, and an emoji is one `Character` and two of these. Counting
    /// characters said a page fits while the API was already cutting it.
    var fitsInOneMessage: Bool { length <= MessageSplitter.telegramMaxChars }

    /// Length in the unit Telegram counts in.
    var length: Int { text.utf16.count }
}

/// Rows of buttons, accumulated. Thin on purpose: it exists so a renderer says
/// what it is adding (a row) instead of how it is stored (append an array to
/// an array of arrays), and so the two conditional shapes that were written
/// out by hand a few dozen times — "this row only if …" and "these rows only
/// if …" — have one spelling each.
struct Keyboard: ExpressibleByArrayLiteral {
    private(set) var rows: [[InlineKeyboardButton]] = []

    init(_ rows: [[InlineKeyboardButton]] = []) {
        self.rows = rows
    }

    init(arrayLiteral rows: [InlineKeyboardButton]...) {
        self.rows = rows
    }

    var isEmpty: Bool { rows.isEmpty }
    var count: Int { rows.count }

    /// For the few keyboards that are sent directly rather than through a
    /// `MenuScreen` (a fresh message, not a page redraw).
    var markup: InlineKeyboardMarkup { InlineKeyboardMarkup(inline_keyboard: rows) }

    mutating func row(_ buttons: [InlineKeyboardButton]) {
        guard !buttons.isEmpty else { return }
        rows.append(buttons)
    }

    mutating func row(_ button: InlineKeyboardButton) {
        rows.append([button])
    }

    mutating func row(if condition: Bool, _ buttons: [InlineKeyboardButton]) {
        guard condition else { return }
        row(buttons)
    }

    mutating func row(if condition: Bool, _ button: InlineKeyboardButton) {
        guard condition else { return }
        row(button)
    }

    /// Slips a row in above the last one — where "the last one" is the row of
    /// navigation buttons every page ends with. `insert(at: rows.count - 1)`
    /// said the same thing by arithmetic, and traps on an empty keyboard.
    mutating func insertBeforeLast(_ buttons: [InlineKeyboardButton]) {
        rows.insert(buttons, at: max(0, rows.count - 1))
    }

    /// Widens the row already added — for the buttons that only exist when the
    /// provider supports the feature they toggle.
    mutating func extendLastRow(with button: InlineKeyboardButton) {
        guard !rows.isEmpty else { return row(button) }
        rows[rows.count - 1].append(button)
    }
}
