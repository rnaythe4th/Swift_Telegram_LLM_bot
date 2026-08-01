import Foundation

struct TelegramUpdate: Codable, Sendable {
    let update_id: Int
    let message: TelegramMessage?
    let callback_query: CallbackQuery?
    let pre_checkout_query: TelegramPreCheckoutQuery?
    let my_chat_member: ChatMemberUpdate?
}

/// The bot's own membership transition in a chat (added / removed / promoted).
struct ChatMemberUpdate: Codable, Sendable {
    let chat: TelegramChat
    /// User who caused the change — i.e. who added the bot.
    let from: TelegramUser
    let oldStatus: String
    let newStatus: String
}

/// A class rather than a struct only because `reply_to_message` makes the type
/// recursive. Every field is `let` and every field type is `Sendable`, so the
/// compiler can check this one — no `@unchecked` needed, and the album buffer
/// builds a new message rather than mutating one.
final class TelegramMessage: Codable, Sendable {
    let message_id: Int
    let from: TelegramUser?
    let chat: TelegramChat
    let date: Int
    let text: String?
    let caption: String?
    let voice: TelegramVoice?
    let video: TelegramVideo?
    let message_thread_id: Int64?
    let media_group_id: String?
    let reply_to_message: TelegramMessage?
    let photo: [PhotoSize]?
    // Internal marker for a synthetic merged album: one primary photo per album item.
    let album_photos: [PhotoSize]?
    let successful_payment: TelegramSuccessfulPayment?

    init(
        message_id: Int,
        from: TelegramUser?,
        chat: TelegramChat,
        date: Int,
        text: String?,
        caption: String?,
        voice: TelegramVoice?,
        video: TelegramVideo?,
        message_thread_id: Int64?,
        media_group_id: String?,
        reply_to_message: TelegramMessage?,
        photo: [PhotoSize]?,
        album_photos: [PhotoSize]? = nil,
        successful_payment: TelegramSuccessfulPayment? = nil
    ) {
        self.message_id = message_id
        self.from = from
        self.chat = chat
        self.date = date
        self.text = text
        self.caption = caption
        self.voice = voice
        self.video = video
        self.message_thread_id = message_thread_id
        self.media_group_id = media_group_id
        self.reply_to_message = reply_to_message
        self.photo = photo
        self.album_photos = album_photos
        self.successful_payment = successful_payment
    }
}

struct TelegramVoice: Codable, Sendable {
    let file_id: String
    let file_unique_id: String
    let duration: Int
    let mime_type: String?
    let file_size: Int?
}

struct TelegramVideo: Codable, Sendable {
    let file_id: String
    let file_unique_id: String
    let width: Int
    let height: Int
    let duration: Int
    let mime_type: String?
    let file_size: Int?
}

struct PhotoSize: Codable, Sendable {
    let file_id: String
    let file_unique_id: String
    let width: Int
    let height: Int
    let file_size: Int?
}

struct TelegramFile: Codable, Sendable {
    let file_id: String
    let file_unique_id: String
    let file_size: Int?
    let file_path: String?
}

struct TelegramUser: Codable, Sendable {
    let id: UserID
    let is_bot: Bool
    let first_name: String
    let username: String?
}

struct TelegramChat: Codable, Sendable {
    let id: ChatID
    let type: String
    /// Group/channel title (nil for private chats).
    let title: String?
    /// Peer @username for private chats (nil when the user has none).
    let username: String?
    /// Peer first name for private chats.
    let first_name: String?

    init(id: ChatID, type: String, title: String? = nil, username: String? = nil, first_name: String? = nil) {
        self.id = id
        self.type = type
        self.title = title
        self.username = username
        self.first_name = first_name
    }
}

struct InlineKeyboardButton: Codable, Sendable {
    let text: String
    let callback_data: String?
    let url: String?

    init(text: String, callback_data: String) {
        self.text = text
        self.callback_data = callback_data
        self.url = nil
    }

    init(text: String, url: String) {
        self.text = text
        self.callback_data = nil
        self.url = url
    }
}

struct InlineKeyboardMarkup: Codable, Sendable {
    let inline_keyboard: [[InlineKeyboardButton]]
}

struct CallbackQuery: Codable, Sendable {
    let id: String
    let from: TelegramUser
    let data: String?
    let message: MaybeInaccessibleMessage?
}

struct MaybeInaccessibleMessage: Codable, Sendable {
    let chat: TelegramChat
    let message_id: Int
    let date: Int
    let text: String?
    let message_thread_id: Int64?
}

struct TelegramPreCheckoutQuery: Codable, Sendable {
    let id: String
    let from: TelegramUser
    let currency: String
    let total_amount: Int
    let invoice_payload: String
}

struct TelegramSuccessfulPayment: Codable, Sendable {
    let currency: String
    let total_amount: Int
    let invoice_payload: String
    let telegram_payment_charge_id: String
    let provider_payment_charge_id: String
}

struct SendInvoiceRequest: Sendable {
    enum PaymentKind: Sendable {
        /// Telegram Stars (currency XTR, no provider needed).
        case stars(amount: Int)
        /// Card payment through a BotFather-connected provider.
        /// `amountMinorUnits` — price in cents/kopecks.
        case fiat(currency: String, amountMinorUnits: Int, providerToken: String)
    }

    let chatID: ChatID
    let title: String
    let description: String
    let payload: String
    let kind: PaymentKind

    /// Backward-compatible convenience for Stars invoices.
    init(chatID: ChatID, title: String, description: String, payload: String, starsAmount: Int) {
        self.init(chatID: chatID, title: title, description: description, payload: payload, kind: .stars(amount: starsAmount))
    }

    init(chatID: ChatID, title: String, description: String, payload: String, kind: PaymentKind) {
        self.chatID = chatID
        self.title = title
        self.description = description
        self.payload = payload
        self.kind = kind
    }
}

enum MessageSplitter {
    static let telegramMaxChars = 4096
    static let footerReserve = 200
    static let charLimit = telegramMaxChars - footerReserve

    static func split(_ text: String, limit: Int = charLimit) -> (done: String, remaining: String) {
        let safeLimit = min(limit, text.count)
        let cutoff = text.index(text.startIndex, offsetBy: safeLimit)

        if let nl = text[..<cutoff].lastIndex(of: "\n"),
           text.distance(from: text.startIndex, to: nl) > limit / 2 {
            return (String(text[..<nl]), String(text[text.index(after: nl)...]))
        }
        if let sp = text[..<cutoff].lastIndex(of: " "),
           text.distance(from: text.startIndex, to: sp) > limit / 2 {
            return (String(text[..<sp]), String(text[text.index(after: sp)...]))
        }
        let hardCut = text.index(text.startIndex, offsetBy: safeLimit)
        return (String(text[..<hardCut]), String(text[hardCut...]))
    }

    /// Splits so the *rendered* prefix stays inside `limit`.
    ///
    /// Telegram counts the HTML it receives, and rendering grows the text:
    /// `&` becomes `&amp;`, a bare `<` becomes `&lt;`. A chunk cut at 3896 raw
    /// characters of code (`if (a < b && c > d)`) renders past 4096 and comes
    /// back as 400 "message is too long" — with that part of the answer lost.
    /// The cut is also kept out of the middle of a tag or an entity, and any
    /// markup still open at the boundary is re-opened at the head of the
    /// continuation — see `openTagMarkup`.
    static func splitRendered(_ text: String, limit: Int = charLimit) -> (done: String, remaining: String) {
        let rawLimit = rawPrefixLength(of: text, renderedLimit: limit)
        guard rawLimit < text.count else { return (text, "") }
        var (done, remaining) = split(text, limit: max(1, rawLimit))

        // A cut landing inside `<a href="…">` or `&amp;` breaks both halves:
        // the head renders as escaped junk, the tail as a stray attribute.
        // Moving the boundary in front of it costs a handful of characters.
        // Skipped when it would empty the chunk — an empty message is worse
        // than a mangled tag, and the streaming loops must always make progress.
        if let dangling = danglingMarkupStart(in: done), dangling != done.startIndex {
            remaining = String(done[dangling...]) + remaining
            done = String(done[..<dangling])
        }

        let reopened = openTagMarkup(in: done)
        if !reopened.isEmpty { remaining = reopened + remaining }
        return (done, remaining)
    }

    /// Tags Telegram renders — mirrors the allow-list in
    /// `TelegramHTMLFormatter`. Only used to decide what is worth re-opening
    /// after a split, so drift is cheap in both directions: a missing name
    /// costs that formatting across the boundary, an extra one costs nothing
    /// (the sanitizer silently drops tags it does not know).
    static let renderedTags: Set<String> = [
        "b", "strong", "i", "em", "u", "ins", "s", "strike", "del",
        "span", "tg-spoiler", "a", "code", "pre", "blockquote", "tg-emoji",
    ]

    /// Opening markup of every tag still open at the end of `text`, outermost
    /// first, copied verbatim.
    ///
    /// A split between `<b>` and `</b>` otherwise costs the continuation its
    /// formatting: the sanitizer closes the dangling tag at the end of the
    /// first message and drops the orphan closer at the start of the second,
    /// so a bolded paragraph, a link or a whole code block silently turns into
    /// plain text halfway through a long answer. Re-opening them restores it.
    ///
    /// The markup is copied raw on purpose: the continuation is rendered by
    /// `TelegramHTMLFormatter` like any other text, so attributes are
    /// sanitized there rather than duplicated here. The stack rules below
    /// mirror that formatter — most notably a closing tag pops whatever is on
    /// top regardless of its name, which is what the formatter does.
    static func openTagMarkup(in text: String) -> String {
        openTagStack(in: text).map(\.markup).joined()
    }

    /// Closing markup for whatever `text` leaves open, innermost first.
    ///
    /// The sanitizer closes dangling tags on its own, but only at the very end
    /// of the message — so a trailer appended by the caller («↓ продолжение
    /// ниже», the usage footer) ends up *inside* the block it follows, which in
    /// a code listing means the note is rendered as part of the code.
    static func closingTagMarkup(in text: String) -> String {
        openTagStack(in: text).reversed().map { "</\($0.name)>" }.joined()
    }

    private static func openTagStack(in text: String) -> [(name: String, markup: String)] {
        var stack: [(name: String, markup: String)] = []
        var i = text.startIndex

        while i < text.endIndex {
            guard text[i] == "<" else {
                i = text.index(after: i)
                continue
            }
            let afterBracket = text.index(after: i)
            guard afterBracket < text.endIndex else { break }
            let next = text[afterBracket]

            // Comments and processing instructions are dropped whole.
            if next == "!" || next == "?" {
                guard let close = text[i...].firstIndex(of: ">") else { break }
                i = text.index(after: close)
                continue
            }
            if next == "/" {
                guard let close = text[i...].firstIndex(of: ">") else { break }
                if !stack.isEmpty { stack.removeLast() }
                i = text.index(after: close)
                continue
            }
            // Not a tag at all (`2 < 3`), or one with no closing bracket: the
            // formatter escapes the `<` and moves on, and so do we.
            guard next.isLetter, let close = text[i...].firstIndex(of: ">") else {
                i = afterBracket
                continue
            }

            let markup = String(text[i...close])
            var content = String(text[afterBracket..<close])
            let isSelfClosing = content.hasSuffix("/")
            if isSelfClosing { content = String(content.dropLast()) }
            let name = content
                .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                .first?
                .lowercased() ?? ""
            i = text.index(after: close)

            // `<script>`/`<style>` swallow their content in the formatter, so
            // re-opening one would eat the entire continuation.
            if name == "script" || name == "style" {
                if let range = text[close...].range(of: "</\(name)>", options: .caseInsensitive) {
                    i = range.upperBound
                }
                continue
            }
            if name == "br" || isSelfClosing { continue }
            stack.append((name, markup))
        }

        return stack.filter { renderedTags.contains($0.name) }
    }

    /// Start of markup left half-written by a cut: an unterminated `<…>` tag or
    /// `&…;` entity. nil when the text ends cleanly.
    private static func danglingMarkupStart(in text: String) -> String.Index? {
        if let bracket = text.lastIndex(of: "<"), !text[bracket...].contains(">") {
            return bracket
        }
        if let amp = text.lastIndex(of: "&") {
            let tail = text[text.index(after: amp)...]
            // A lone `&` is ordinary text ("Tom & Jerry"); only a short run of
            // entity-shaped characters with no `;` looks like a split entity.
            if !tail.contains(";"), tail.count <= 10,
               tail.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "#" }) {
                return amp
            }
        }
        return nil
    }

    /// Upper bound on the rendered length. Deliberately pessimistic: a real
    /// `<b>` survives rendering unchanged but is counted as if escaped, so the
    /// estimate can only ever split earlier than strictly necessary — never
    /// later, which is the direction that loses text.
    static func renderedLength(_ text: String) -> Int {
        text.reduce(0) { $0 + renderedCost($1) }
    }

    private static func rawPrefixLength(of text: String, renderedLimit: Int) -> Int {
        var rendered = 0
        var raw = 0
        for ch in text {
            rendered += renderedCost(ch)
            if rendered > renderedLimit { break }
            raw += 1
        }
        return raw
    }

    private static func renderedCost(_ ch: Character) -> Int {
        switch ch {
        case "&": return 5   // &amp;
        case "<": return 4   // &lt;
        case ">": return 4   // &gt;
        default: return 1
        }
    }
}
