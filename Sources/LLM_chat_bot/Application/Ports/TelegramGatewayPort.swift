import Foundation

struct SendMessageRequest: Sendable {
    let chatID: Int
    let threadID: Int64?
    let replyTo: Int?
    let text: String
    let replyMarkup: InlineKeyboardMarkup?
}

struct EditMessageRequest: Sendable {
    let chatID: Int
    let messageID: Int
    let text: String
    let replyMarkup: InlineKeyboardMarkup?
}

protocol TelegramGatewayPort: Sendable {
    func deleteWebhook() async throws
    func getMe() async throws -> TelegramUser
    func getUpdates(offset: Int?) async throws -> [TelegramUpdate]
    func sendMessage(_ request: SendMessageRequest) async throws -> TelegramMessage
    func editMessage(_ request: EditMessageRequest) async throws
    func answerCallback(callbackQueryID: String, text: String?) async throws
    func getFile(fileID: String) async throws -> TelegramFile
    func downloadFile(filePath: String) async throws -> Data
}

