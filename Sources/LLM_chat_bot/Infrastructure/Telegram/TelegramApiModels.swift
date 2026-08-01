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
    let pre_checkout_query: TelegramAPIPreCheckoutQuery?
    let my_chat_member: TelegramAPIChatMemberUpdated?
}

/// The bot's own membership in a chat changing (added / removed / promoted).
/// Delivered as a `my_chat_member` update — the reliable signal that the bot
/// was added to a group.
struct TelegramAPIChatMemberUpdated: Decodable, Sendable {
    let chat: TelegramAPIChat
    let from: TelegramAPIUser
    let date: Int
    let old_chat_member: TelegramAPIChatMember
    let new_chat_member: TelegramAPIChatMember
}

struct TelegramAPIChatMember: Decodable, Sendable {
    let status: String
    let user: TelegramAPIUser
}

/// Recursive for the same reason as `TelegramMessage`, immutable for the same
/// reason, and checked by the compiler for the same reason.
final class TelegramAPIMessage: Decodable, Sendable {
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
    let successful_payment: TelegramAPISuccessfulPayment?
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
    let title: String?
    let username: String?
    let first_name: String?
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

struct TelegramSendMessageDraftBody: Codable {
    let chat_id: Int
    let message_thread_id: Int64?
    let draft_id: Int
    let text: String
    let parse_mode: String?
}

struct TelegramDeleteMessageBody: Codable {
    let chat_id: Int
    let message_id: Int
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

struct TelegramAPIPreCheckoutQuery: Decodable, Sendable {
    let id: String
    let from: TelegramAPIUser
    let currency: String
    let total_amount: Int
    let invoice_payload: String
}

struct TelegramAPISuccessfulPayment: Decodable, Sendable {
    let currency: String
    let total_amount: Int
    let invoice_payload: String
    let telegram_payment_charge_id: String
    let provider_payment_charge_id: String
}

struct TelegramLabeledPrice: Codable, Sendable {
    let label: String
    let amount: Int
}

struct TelegramSendInvoiceBody: Codable {
    let chat_id: Int
    let title: String
    let description: String
    let payload: String
    let currency: String
    let prices: [TelegramLabeledPrice]
    let provider_token: String
}

struct TelegramAnswerPreCheckoutQueryBody: Codable {
    let pre_checkout_query_id: String
    let ok: Bool
    let error_message: String?
}
