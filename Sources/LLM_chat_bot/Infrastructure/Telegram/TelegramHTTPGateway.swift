import Foundation

struct TelegramAPIError: Error, LocalizedError {
    let action: String
    let statusCode: Int
    let descriptionText: String
    let retryAfter: Int?
    let migrateToChatID: Int64?
    let rawBody: String
    
    var errorDescription: String? {
        var parts: [String] = ["\(action) failed: \(descriptionText)", "HTTP \(statusCode)"]
        if let retryAfter { parts.append("retry_after=\(retryAfter)") }
        if let migrateToChatID { parts.append("migrate_to_chat_id=\(migrateToChatID)") }
        return parts.joined(separator: " | ")
    }
}

final class TelegramHTTPGateway: TelegramGatewayPort, @unchecked Sendable {
    private let network: NetworkClient
    private let telegramURL: String
    private let botToken: String
    
    init(network: NetworkClient, botToken: String) {
        self.network = network
        self.botToken = botToken
        self.telegramURL = "https://api.telegram.org/bot\(botToken)"
    }
    
    func deleteWebhook() async throws {
        let spec = HTTPRequestSpec(
            url: "\(telegramURL)/deleteWebhook",
            method: .post,
            timeoutSeconds: 10,
            maxBodyBytes: 1 << 18,
            validStatusCodes: 100..<600
        )
        let raw = try await network.perform(spec)
        try validateTelegramEnvelope(action: "deleteWebhook", statusCode: raw.statusCode, data: raw.data)
    }
    
    func getMe() async throws -> TelegramUser {
        let spec = HTTPRequestSpec(
            url: "\(telegramURL)/getMe",
            method: .get,
            timeoutSeconds: 35,
            validStatusCodes: 100..<600
        )
        let raw = try await network.perform(spec)
        let decoded: TelegramResponse<TelegramAPIUser> = try decodeEnvelope(action: "getMe", statusCode: raw.statusCode, data: raw.data)
        guard decoded.ok, let result = decoded.result else {
            throw buildTelegramError(action: "getMe", statusCode: raw.statusCode, data: raw.data)
        }
        return map(result)
    }
    
    func getUpdates(offset: Int?) async throws -> [TelegramUpdate] {
        let url = "\(telegramURL)/getUpdates?timeout=30&offset=\(offset ?? 0)"
        let spec = HTTPRequestSpec(url: url, method: .get, timeoutSeconds: 35, validStatusCodes: 100..<600)
        let raw = try await network.perform(spec)
        
        let decoded: TelegramResponse<[TelegramAPIUpdate]> = try decodeEnvelope(
            action: "getUpdates",
            statusCode: raw.statusCode,
            data: raw.data
        )
        
        guard decoded.ok, let result = decoded.result else {
            throw buildTelegramError(action: "getUpdates", statusCode: raw.statusCode, data: raw.data)
        }
        return result.map(map)
    }
    
    func sendMessage(_ request: SendMessageRequest) async throws -> TelegramMessage {
        let body = TelegramSendMessageBody(
            chat_id: request.chatID,
            text: TelegramHTMLFormatter.helper(text: request.text),
            reply_parameters: request.replyTo.map { ReplyParameters(message_id: $0) },
            message_thread_id: request.threadID,
            parse_mode: "HTML",
            reply_markup: request.replyMarkup
        )
        
        let spec = HTTPRequestSpec(
            url: "\(telegramURL)/sendMessage",
            method: .post,
            headers: ["Content-Type": "application/json"],
            body: .json(.init(body)),
            timeoutSeconds: 30,
            validStatusCodes: 100..<600
        )
        
        let raw = try await network.perform(spec)
        let decoded: TelegramResponse<TelegramAPIMessage> = try decodeEnvelope(
            action: "sendMessage",
            statusCode: raw.statusCode,
            data: raw.data
        )
        
        guard decoded.ok, let result = decoded.result else {
            throw buildTelegramError(action: "sendMessage", statusCode: raw.statusCode, data: raw.data)
        }
        
        return map(result)
    }
    
    func editMessage(_ request: EditMessageRequest) async throws {
        let body = TelegramEditMessageTextBody(
            chat_id: request.chatID,
            message_id: request.messageID,
            text: TelegramHTMLFormatter.helper(text: request.text),
            parse_mode: "HTML",
            reply_markup: request.replyMarkup
        )
        
        let spec = HTTPRequestSpec(
            url: "\(telegramURL)/editMessageText",
            method: .post,
            headers: ["Content-Type": "application/json"],
            body: .json(.init(body)),
            timeoutSeconds: 30,
            maxBodyBytes: 1 << 20,
            validStatusCodes: 100..<600
        )
        
        let raw = try await network.perform(spec)
        try validateTelegramEnvelope(action: "editMessageText", statusCode: raw.statusCode, data: raw.data)
    }
    
    func answerCallback(callbackQueryID: String, text: String?) async throws {
        let body = AnswerCallbackQueryBody(
            callback_query_id: callbackQueryID,
            text: text,
            show_alert: nil
        )
        
        let spec = HTTPRequestSpec(
            url: "\(telegramURL)/answerCallbackQuery",
            method: .post,
            headers: ["Content-Type": "application/json"],
            body: .json(.init(body)),
            timeoutSeconds: 30,
            maxBodyBytes: 1 << 20,
            validStatusCodes: 100..<600
        )
        
        let raw = try await network.perform(spec)
        try validateTelegramEnvelope(action: "answerCallbackQuery", statusCode: raw.statusCode, data: raw.data)
    }
    
    func getFile(fileID: String) async throws -> TelegramFile {
        struct GetFileBody: Codable {
            let file_id: String
        }
        
        let spec = HTTPRequestSpec(
            url: "\(telegramURL)/getFile",
            method: .post,
            headers: ["Content-Type": "application/json"],
            body: .json(.init(GetFileBody(file_id: fileID))),
            timeoutSeconds: 35,
            validStatusCodes: 100..<600
        )
        
        let raw = try await network.perform(spec)
        let decoded: TelegramResponse<TelegramAPIFile> = try decodeEnvelope(
            action: "getFile",
            statusCode: raw.statusCode,
            data: raw.data
        )
        
        guard decoded.ok, let result = decoded.result else {
            throw buildTelegramError(action: "getFile", statusCode: raw.statusCode, data: raw.data)
        }
        
        return map(result)
    }
    
    func downloadFile(filePath: String) async throws -> Data {
        let spec = HTTPRequestSpec(
            url: "https://api.telegram.org/file/bot\(botToken)/\(filePath)",
            method: .get,
            timeoutSeconds: 35,
            maxBodyBytes: 20 << 20,
            validStatusCodes: 100..<600
        )
        let raw = try await network.perform(spec)
        guard (200..<300).contains(raw.statusCode) else {
            throw buildTelegramError(action: "downloadFile", statusCode: raw.statusCode, data: raw.data)
        }
        return raw.data
    }
    
    private func decodeEnvelope<T: Decodable>(action: String, statusCode: Int, data: Data) throws -> TelegramResponse<T> {
        do {
            return try JSONDecoder().decode(TelegramResponse<T>.self, from: data)
        } catch {
            throw buildTelegramError(action: action, statusCode: statusCode, data: data)
        }
    }
    
    private func validateTelegramEnvelope(action: String, statusCode: Int, data: Data) throws {
        if let decoded = try? JSONDecoder().decode(TelegramError.self, from: data), !decoded.ok {
            throw buildTelegramError(action: action, statusCode: statusCode, data: data)
        }
        if !(200..<300).contains(statusCode) {
            throw buildTelegramError(action: action, statusCode: statusCode, data: data)
        }
    }
    
    private func buildTelegramError(action: String, statusCode: Int, data: Data) -> TelegramAPIError {
        let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        if let decoded = try? JSONDecoder().decode(TelegramError.self, from: data) {
            return TelegramAPIError(
                action: action,
                statusCode: decoded.error_code ?? statusCode,
                descriptionText: decoded.description ?? "Telegram returned an unknown error",
                retryAfter: decoded.parameters?.retry_after,
                migrateToChatID: decoded.parameters?.migrate_to_chat_id,
                rawBody: raw
            )
        }
        
        return TelegramAPIError(
            action: action,
            statusCode: statusCode,
            descriptionText: "Invalid Telegram response",
            retryAfter: nil,
            migrateToChatID: nil,
            rawBody: raw
        )
    }
    
    // пока не знаю насколько это правильно, но хочется отделить внешний api от внутренних типов
    
    private func map(_ update: TelegramAPIUpdate) -> TelegramUpdate {
        TelegramUpdate(
            update_id: update.update_id,
            message: update.message.map(map),
            callback_query: update.callback_query.map(map)
        )
    }
    
    private func map(_ message: TelegramAPIMessage) -> TelegramMessage {
        TelegramMessage(
            message_id: message.message_id,
            from: message.from.map(map),
            chat: map(message.chat),
            date: message.date,
            text: message.text,
            caption: message.caption,
            voice: message.voice.map(map),
            video: message.video.map(map),
            message_thread_id: message.message_thread_id,
            media_group_id: message.media_group_id,
            reply_to_message: message.reply_to_message.map(map),
            photo: message.photo?.map(map)
        )
    }
    
    private func map(_ callback: TelegramAPICallbackQuery) -> CallbackQuery {
        CallbackQuery(
            id: callback.id,
            from: map(callback.from),
            data: callback.data,
            message: callback.message.map(map)
        )
    }
    
    private func map(_ message: TelegramAPIMaybeInaccessibleMessage) -> MaybeInaccessibleMessage {
        MaybeInaccessibleMessage(
            chat: map(message.chat),
            message_id: message.message_id,
            date: message.date,
            text: message.text
        )
    }
    
    private func map(_ user: TelegramAPIUser) -> TelegramUser {
        TelegramUser(
            id: user.id,
            is_bot: user.is_bot,
            first_name: user.first_name,
            username: user.username
        )
    }
    
    private func map(_ chat: TelegramAPIChat) -> TelegramChat {
        TelegramChat(id: chat.id, type: chat.type)
    }
    
    private func map(_ voice: TelegramAPIVoice) -> TelegramVoice {
        TelegramVoice(
            file_id: voice.file_id,
            file_unique_id: voice.file_unique_id,
            duration: voice.duration,
            mime_type: voice.mime_type,
            file_size: voice.file_size
        )
    }
    
    private func map(_ video: TelegramAPIVideo) -> TelegramVideo {
        TelegramVideo(
            file_id: video.file_id,
            file_unique_id: video.file_unique_id,
            width: video.width,
            height: video.height,
            duration: video.duration,
            mime_type: video.mime_type,
            file_size: video.file_size
        )
    }
    
    private func map(_ photo: TelegramAPIPhotoSize) -> PhotoSize {
        PhotoSize(
            file_id: photo.file_id,
            file_unique_id: photo.file_unique_id,
            width: photo.width,
            height: photo.height,
            file_size: photo.file_size
        )
    }
    
    private func map(_ file: TelegramAPIFile) -> TelegramFile {
        TelegramFile(
            file_id: file.file_id,
            file_unique_id: file.file_unique_id,
            file_size: file.file_size,
            file_path: file.file_path
        )
    }
}
