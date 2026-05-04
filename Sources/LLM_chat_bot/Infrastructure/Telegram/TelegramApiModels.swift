import Foundation

struct TelegramError: Codable {
    let ok: Bool
    let error_code: Int?
    let description: String?
    let parameters: TelegramErrorParameters?
}

struct TelegramErrorParameters: Codable {
    let migrate_to_chat_id: Int64?
    let retry_after: Int?
}

struct TelegramResponse<T: Decodable>: Decodable {
    let ok: Bool
    let result: T?
    let description: String?
    let error_code: Int?
    let parameters: TelegramErrorParameters?
}

struct TelegramAPIUpdate: Decodable {
    let update_id: Int
    let message: TelegramAPIMessage?
    let callback_query: TelegramAPICallbackQuery?
}

final class TelegramAPIMessage: Decodable, @unchecked Sendable {
    let message_id: Int
    let from: TelegramAPIUser?
    let chat: TelegramAPIChat
    let date: Int
    let text: String?
    let caption: String?
    let voice: TelegramAPIVoice?
    let video: TelegramAPIVideo?
    let message_thread_id: Int64?
    let media_group_id: String?
    let reply_to_message: TelegramAPIMessage?
    let photo: [TelegramAPIPhotoSize]?
}

struct TelegramAPIVoice: Decodable, Sendable {
    let file_id: String
    let file_unique_id: String
    let duration: Int
    let mime_type: String?
    let file_size: Int?
}

struct TelegramAPIVideo: Decodable, Sendable {
    let file_id: String
    let file_unique_id: String
    let width: Int
    let height: Int
    let duration: Int
    let mime_type: String?
    let file_size: Int?
}

struct TelegramAPIPhotoSize: Decodable, Sendable {
    let file_id: String
    let file_unique_id: String
    let width: Int
    let height: Int
    let file_size: Int?
}

struct TelegramAPIFile: Decodable, Sendable {
    let file_id: String
    let file_unique_id: String
    let file_size: Int?
    let file_path: String?
}

struct TelegramAPIUser: Decodable, Sendable {
    let id: Int
    let is_bot: Bool
    let first_name: String
    let username: String?
}

struct TelegramAPIChat: Decodable, Sendable {
    let id: Int
    let type: String
}

struct ReplyParameters: Codable, Sendable {
    let message_id: Int
}

struct TelegramSendMessageBody: Codable {
    let chat_id: Int
    let text: String
    let reply_parameters: ReplyParameters?
    let message_thread_id: Int64?
    let parse_mode: String?
    let reply_markup: InlineKeyboardMarkup?
}

struct TelegramEditMessageTextBody: Codable {
    let chat_id: Int
    let message_id: Int
    let text: String
    let parse_mode: String?
    let reply_markup: InlineKeyboardMarkup?
}

struct TelegramAPICallbackQuery: Decodable, Sendable {
    let id: String
    let from: TelegramAPIUser
    let data: String?
    let message: TelegramAPIMaybeInaccessibleMessage?
}

struct TelegramAPIMaybeInaccessibleMessage: Decodable, Sendable {
    let chat: TelegramAPIChat
    let message_id: Int
    let date: Int
    let text: String?
    let message_thread_id: Int64?
}

struct AnswerCallbackQueryBody: Codable {
    let callback_query_id: String
    let text: String?
    let show_alert: Bool?
}
