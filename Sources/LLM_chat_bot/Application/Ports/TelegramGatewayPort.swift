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

struct SendMessageDraftRequest: Sendable {
    let chatID: Int
    let threadID: Int64?
    let draftID: Int
    let text: String
}

protocol TelegramGatewayPort: Sendable {
    func deleteWebhook() async throws
    func setWebhook(url: String, secretToken: String, allowedUpdates: [String]) async throws
    /// Decodes a single update delivered to the webhook endpoint.
    func decodeIncomingUpdate(_ data: Data) throws -> TelegramUpdate
    func getMe() async throws -> TelegramUser
    func getUpdates(offset: Int?) async throws -> [TelegramUpdate]
    func sendMessage(_ request: SendMessageRequest) async throws -> TelegramMessage
    func editMessage(_ request: EditMessageRequest) async throws
    func sendMessageDraft(_ request: SendMessageDraftRequest) async throws
    func deleteMessage(chatID: Int, messageID: Int) async throws
    func sendChatAction(chatID: Int, threadID: Int64?, action: String) async throws
    func answerCallback(callbackQueryID: String, text: String?) async throws
    func getFile(fileID: String) async throws -> TelegramFile
    func downloadFile(filePath: String) async throws -> Data
    func sendInvoice(_ request: SendInvoiceRequest) async throws
    func answerPreCheckoutQuery(queryID: String, ok: Bool, errorMessage: String?) async throws
}

