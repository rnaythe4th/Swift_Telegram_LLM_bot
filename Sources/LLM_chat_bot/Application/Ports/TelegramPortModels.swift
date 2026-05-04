import Foundation

struct TelegramUpdate: Codable, Sendable {
    let update_id: Int
    let message: TelegramMessage?
    let callback_query: CallbackQuery?
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
        album_photos: [PhotoSize]? = nil
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
}

struct InlineKeyboardButton: Codable, Sendable {
    let text: String
    let callback_data: String
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
}
