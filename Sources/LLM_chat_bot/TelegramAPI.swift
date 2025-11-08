import Foundation
import AsyncHTTPClient
import NIOFoundationCompat

enum TelegramAPI {
    static func getUpdates(telegramUrl: String, offset: Int?) async throws -> [TelegramUpdate] {
        let url = "\(telegramUrl)/getUpdates?timeout=30&offset=\(offset ?? 0)"
        var request = HTTPClientRequest(url: url)
        request.method = .GET
        
        let response = try await HTTPClient.shared.execute(request, timeout: .seconds(35))
        print("got response")
        
        var buf = try await response.body.collect(upTo: 1 << 22)
        let responseData = buf.readData(length: buf.readableBytes) ?? Data()
        let decoded = try JSONDecoder().decode(TelegramResponse<[TelegramUpdate]>.self, from: responseData)
        if decoded.ok {return decoded.result} else {
            print("ne ok")
        }
        return decoded.result
    }
    
    static func sendTelegramMessage(telegramUrl: String, chat_id: Int, text: String, reply_parameters: ReplyParameters?, message_thread_id: Int64?, reply_markup: InlineKeyboardMarkup? = nil) async throws -> TelegramMessage? {
        
        let body = TelegramSendMessageBody(chat_id: chat_id, text: TelegramHTMLFormatter.helper(text: text), reply_parameters: reply_parameters, message_thread_id: message_thread_id, parse_mode: "HTML", reply_markup: reply_markup)
        
        var request = HTTPClientRequest(url: "\(telegramUrl)/sendMessage")
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/json")
        request.body = .bytes(try JSONEncoder().encode(body))
        
        let response = try await HTTPClient.shared.execute(request, timeout: .seconds(30))
        guard response.status == .ok else {
            print("error sending message: \(response.status)")
            return nil
        }
        var buf = try await response.body.collect(upTo: 1 << 22)
        let responseData = buf.readData(length: buf.readableBytes) ?? Data()
        let decoded = try JSONDecoder().decode(TelegramResponse<TelegramMessage>.self, from: responseData)
        
        return decoded.result
        
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
            print("error editing message: \(response.status)")
            // Попробуем понять причину
            if let apiErr = try? JSONDecoder().decode(TelegramResponse<String>.self, from: data),
               let desc = apiErr.description {
                throw NSError(domain: "TelegramAPI", code: apiErr.error_code ?? 400,
                              userInfo: [NSLocalizedDescriptionKey: desc])
            } else {
                let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                throw NSError(domain: "TelegramAPI", code: 400,
                              userInfo: [NSLocalizedDescriptionKey: "Bad Request, raw: \(raw)"])
            }
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
                // попытаемся вытащить нормальное описание ошибки от Telegram
                if let apiErr = try? JSONDecoder().decode(TelegramResponse<String>.self, from: data),
                   let desc = apiErr.description {
                    throw NSError(
                        domain: "TelegramAPI",
                        code: apiErr.error_code ?? 400,
                        userInfo: [NSLocalizedDescriptionKey: desc]
                    )
                } else {
                    let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                    throw NSError(
                        domain: "TelegramAPI",
                        code: 400,
                        userInfo: [NSLocalizedDescriptionKey: "Bad Request, raw: \(raw)"]
                    )
                }
            }
            // Telegram на успешный ответ возвращает {"ok":true,"result":true}, но нам ничего не нужно
        }
}
