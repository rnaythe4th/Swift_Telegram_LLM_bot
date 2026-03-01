import Foundation
import AsyncHTTPClient
import NIOFoundationCompat

enum TelegramAPI {
    private static func formatErrorParameters(_ parameters: TelegramErrorParameters?) -> String? {
        guard let parameters else { return nil }
        
        var parts: [String] = []
        if let retryAfter = parameters.retry_after {
            parts.append("retry_after=\(retryAfter)")
        }
        if let migrateToChatID = parameters.migrate_to_chat_id {
            parts.append("migrate_to_chat_id=\(migrateToChatID)")
        }
        
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
    
    private static func makeTelegramError(action: String, statusCode: Int, statusText: String, data: Data) -> NSError {
        let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        
        if let telegramError = try? JSONDecoder().decode(TelegramError.self, from: data),
           !telegramError.ok || telegramError.error_code != nil || telegramError.description != nil {
            
            var description = telegramError.description ?? "Telegram returned error without description"
            if let parameters = formatErrorParameters(telegramError.parameters) {
                description += " (parameters: \(parameters))"
            }
            
            return NSError(
                domain: "TelegramAPI",
                code: telegramError.error_code ?? statusCode,
                userInfo: [
                    NSLocalizedDescriptionKey: "\(action) failed: \(description)",
                    "raw": raw
                ]
            )
        }
        
        return NSError(
            domain: "TelegramAPI",
            code: statusCode,
            userInfo: [
                NSLocalizedDescriptionKey: "\(action) failed: HTTP \(statusText). Raw: \(raw)",
                "raw": raw
            ]
        )
    }
    
    static func deleteWebhook(telegramUrl: String) async throws {
        let url = "\(telegramUrl)/deleteWebhook"
        var request = HTTPClientRequest(url: url)
        request.method = .POST
        
        let response = try await HTTPClient.shared.execute(request, timeout: .seconds(10))
        var buf = try await response.body.collect(upTo: 1 << 18)
        let data = buf.readData(length: buf.readableBytes) ?? Data()
        
        guard response.status == .ok else {
            throw makeTelegramError(
                action: "deleteWebhook",
                statusCode: Int(response.status.code),
                statusText: "\(response.status)",
                data: data
            )
        }
        
        if let decoded = try? JSONDecoder().decode(TelegramError.self, from: data),
           !decoded.ok {
            throw makeTelegramError(
                action: "deleteWebhook",
                statusCode: Int(response.status.code),
                statusText: "\(response.status)",
                data: data
            )
        }
    }
    
    static func getUpdates(telegramUrl: String, offset: Int?) async throws -> [TelegramUpdate] {
        let url = "\(telegramUrl)/getUpdates?timeout=30&offset=\(offset ?? 0)"
        var request = HTTPClientRequest(url: url)
        request.method = .GET
        
        let response = try await HTTPClient.shared.execute(request, timeout: .seconds(35))
        //print("got response")
        
        var buf = try await response.body.collect(upTo: 1 << 22)
        let responseData = buf.readData(length: buf.readableBytes) ?? Data()
        
        let decoded: TelegramResponse<[TelegramUpdate]>
        do {
            decoded = try JSONDecoder().decode(TelegramResponse<[TelegramUpdate]>.self, from: responseData)
        } catch {
            throw makeTelegramError(
                action: "getUpdates",
                statusCode: Int(response.status.code),
                statusText: "\(response.status)",
                data: responseData
            )
        }
        
        if decoded.ok, let result = decoded.result {
            return result
        }
        
        throw makeTelegramError(
            action: "getUpdates",
            statusCode: Int(response.status.code),
            statusText: "\(response.status)",
            data: responseData
        )
    }
    
    static func sendTelegramMessage(telegramUrl: String, chat_id: Int, text: String, reply_parameters: ReplyParameters?, message_thread_id: Int64?, reply_markup: InlineKeyboardMarkup? = nil) async throws -> TelegramMessage {
        
        let body = TelegramSendMessageBody(chat_id: chat_id, text: TelegramHTMLFormatter.helper(text: text), reply_parameters: reply_parameters, message_thread_id: message_thread_id, parse_mode: "HTML", reply_markup: reply_markup)
        
        var request = HTTPClientRequest(url: "\(telegramUrl)/sendMessage")
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/json")
        request.body = .bytes(try JSONEncoder().encode(body))
        
        let response = try await HTTPClient.shared.execute(request, timeout: .seconds(30))
        var buf = try await response.body.collect(upTo: 1 << 22)
        let data = buf.readData(length: buf.readableBytes) ?? Data()
        
        guard response.status == .ok else {
            throw makeTelegramError(
                action: "sendMessage",
                statusCode: Int(response.status.code),
                statusText: "\(response.status)",
                data: data
            )
        }
        
        let decoded: TelegramResponse<TelegramMessage>
        do {
            decoded = try JSONDecoder().decode(TelegramResponse<TelegramMessage>.self, from: data)
        } catch {
            throw makeTelegramError(
                action: "sendMessage",
                statusCode: Int(response.status.code),
                statusText: "\(response.status)",
                data: data
            )
        }
        
        guard decoded.ok, let result = decoded.result else {
            throw makeTelegramError(
                action: "sendMessage",
                statusCode: Int(response.status.code),
                statusText: "\(response.status)",
                data: data
            )
        }
        
        return result
        
    }
    
    static func editTelegramMessage(telegramUrl: String, chat_id: Int, message_id: Int, text: String, reply_markup: InlineKeyboardMarkup? = nil) async throws {
        let body = TelegramEditMessageTextBody(chat_id: chat_id, message_id: message_id, text: TelegramHTMLFormatter.helper(text: text), parse_mode: "HTML", reply_markup: reply_markup)
        var request = HTTPClientRequest(url: "\(telegramUrl)/editMessageText")
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/json")
        request.body = .bytes(try JSONEncoder().encode(body))
        
        let response = try await HTTPClient.shared.execute(request, timeout: .seconds(30))
        var buf = try await response.body.collect(upTo: 1 << 20)
        let data = buf.readData(length: buf.readableBytes) ?? Data()
        guard response.status == .ok else {
            throw makeTelegramError(
                action: "editMessageText",
                statusCode: Int(response.status.code),
                statusText: "\(response.status)",
                data: data
            )
        }
        
        if let decoded = try? JSONDecoder().decode(TelegramError.self, from: data),
           !decoded.ok {
            throw makeTelegramError(
                action: "editMessageText",
                statusCode: Int(response.status.code),
                statusText: "\(response.status)",
                data: data
            )
        }
    }
    
    static func answerCallbackQuery(
        telegramUrl: String,
        callback_query_id: String,
        text: String? = nil,
        show_alert: Bool = false
    ) async throws {
        
        let body = AnswerCallbackQueryBody(
            callback_query_id: callback_query_id,
            text: text,
            show_alert: show_alert ? true : nil // не отправляем поле, если false
        )
        
        var request = HTTPClientRequest(url: "\(telegramUrl)/answerCallbackQuery")
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/json")
        request.body = .bytes(try JSONEncoder().encode(body))
        
        let response = try await HTTPClient.shared.execute(request, timeout: .seconds(30))
        var buf = try await response.body.collect(upTo: 1 << 20)
        let data = buf.readData(length: buf.readableBytes) ?? Data()
        
        guard response.status == .ok else {
            throw makeTelegramError(
                action: "answerCallbackQuery",
                statusCode: Int(response.status.code),
                statusText: "\(response.status)",
                data: data
            )
        }
        
        if let decoded = try? JSONDecoder().decode(TelegramError.self, from: data),
           !decoded.ok {
            throw makeTelegramError(
                action: "answerCallbackQuery",
                statusCode: Int(response.status.code),
                statusText: "\(response.status)",
                data: data
            )
        }
        // Telegram на успешный ответ возвращает {"ok":true,"result":true}, но нам ничего не нужно
    }
    
    static func getMe(telegramUrl: String) async throws -> TelegramUser {
        let url = "\(telegramUrl)/getMe"
        var request = HTTPClientRequest(url: url)
        request.method = .GET
        
        let response = try await HTTPClient.shared.execute(request, timeout: .seconds(35))
        //print("got response")
        
        var buf = try await response.body.collect(upTo: 1 << 22)
        let responseData = buf.readData(length: buf.readableBytes) ?? Data()
        
        let decoded: TelegramResponse<TelegramUser>
        do {
            decoded = try JSONDecoder().decode(TelegramResponse<TelegramUser>.self, from: responseData)
        } catch {
            throw makeTelegramError(
                action: "getMe",
                statusCode: Int(response.status.code),
                statusText: "\(response.status)",
                data: responseData
            )
        }
        
        if decoded.ok, let result = decoded.result {
            return result
        }
        
        throw makeTelegramError(
            action: "getMe",
            statusCode: Int(response.status.code),
            statusText: "\(response.status)",
            data: responseData
        )
    }
    
    // prepare file fow download
    // get filePath, required by downloadFile()
    static func getFile(telegramUrl: String, file_id: String) async throws -> TelegramFile {
        struct GetFileBody: Codable {
            let file_id: String
        }
        
        let url = "\(telegramUrl)/getFile"
        let body = GetFileBody(file_id: file_id)
        var request = HTTPClientRequest(url: url)
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/json")
        request.body = .bytes(try JSONEncoder().encode(body))
        
        let response = try await HTTPClient.shared.execute(request, timeout: .seconds(35))
        
        var responseBody = try await response.body.collect(upTo: 1 << 22)
        let responseData = responseBody.readData(length: responseBody.readableBytes) ?? Data()
        
        let decoded: TelegramResponse<TelegramFile>
        do {
            decoded = try JSONDecoder().decode(TelegramResponse<TelegramFile>.self, from: responseData)
        } catch {
            throw makeTelegramError(
                action: "getFile",
                statusCode: Int(response.status.code),
                statusText: "\(response.status)",
                data: responseData
            )
        }
        
        if decoded.ok, let result = decoded.result {
            return result
        }
        
        throw makeTelegramError(
            action: "getFile",
            statusCode: Int(response.status.code),
            statusText: "\(response.status)",
            data: responseData
        )
    }
    
    static func downloadFile(botToken:String, filePath: String) async throws -> Data {
        
        // https://api.telegram.org/file/bot<token>/<file_path>
        let url = "https://api.telegram.org/file/bot\(botToken)/\(filePath)"
        var request = HTTPClientRequest(url: url)
        request.method = .GET
        
        let response = try await HTTPClient.shared.execute(request, timeout: .seconds(35))
        //print("got response")
        
        guard response.status == .ok else {
            // process error
            var body = try await response.body.collect(upTo: 1 << 27)
            let errorData = body.readData(length: body.readableBytes) ?? Data()
            throw makeTelegramError(
                action: "downloadFile",
                statusCode: Int(response.status.code),
                statusText: "\(response.status)",
                data: errorData
            )
        }
        
        var body = try await response.body.collect(upTo: 20 << 20)
        guard let data = body.readData(length: body.readableBytes) else {
            throw NSError(domain: "TelegramAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to read response data"])
        }
        return data
    }
}
