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

final class TelegramMessage: Codable, @unchecked Sendable {
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
    let id: Int
    let is_bot: Bool
    let first_name: String
    let username: String?
}

struct TelegramChat: Codable, Sendable {
    let id: Int
    let type: String
    /// Group/channel title (nil for private chats).
    let title: String?
    /// Peer @username for private chats (nil when the user has none).
    let username: String?
    /// Peer first name for private chats.
    let first_name: String?

    init(id: Int, type: String, title: String? = nil, username: String? = nil, first_name: String? = nil) {
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

    let chatID: Int
    let title: String
    let description: String
    let payload: String
    let kind: PaymentKind

    /// Backward-compatible convenience for Stars invoices.
    init(chatID: Int, title: String, description: String, payload: String, starsAmount: Int) {
        self.init(chatID: chatID, title: title, description: description, payload: payload, kind: .stars(amount: starsAmount))
    }

    init(chatID: Int, title: String, description: String, payload: String, kind: PaymentKind) {
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
    static func splitRendered(_ text: String, limit: Int = charLimit) -> (done: String, remaining: String) {
        let rawLimit = rawPrefixLength(of: text, renderedLimit: limit)
        guard rawLimit < text.count else { return (text, "") }
        return split(text, limit: max(1, rawLimit))
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
