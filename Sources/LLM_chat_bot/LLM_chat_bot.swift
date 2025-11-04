import AsyncHTTPClient
import Foundation

@main
struct LLM_chat_bot {
    
    static func main() async throws {
        let tgToken = try Config.env(.telegramToken)
        let deepseekKey = try Config.env(.deepseekKey)
        
        let telegramUrl = "https://api.telegram.org/bot\(tgToken)"
        
        // 0 - просто чат, thread_id > 0 — конкретный тред
        var chatRoles: [Int: [Int64: String]] = [:]
        var chatHistories: [Int: [Int64: [ChatMessage]]] = [:]
        var chatTemps: [Int: [Int64: Float]] = [:]
        var chatShowStats: [Int: [Int64: Bool]] = [:]
        
        let systemPrompt = "Ты физик, тебя зовут Анатолий"
        
        var currentOffset: Int? = nil
        var lastEdit = Date.distantPast
        while true {
            do {
                let updates = try await TelegramAPI.getUpdates(telegramUrl: telegramUrl, offset: currentOffset)
                print("получил апдейты")
                if let maxUpdateId = updates.map(\.update_id).max() {
                    currentOffset = maxUpdateId + 1
                }
                print("обновил оффсет")
                for u in updates {
                    if let msg = u.message, let text = msg.text {
                        
                        let thread_id: Int64 = msg.message_thread_id ?? 0
                        let chatID = msg.chat.id
                        
                        let splittedText = splitBySpace(from: text)
                        
                        switch splittedText[0] {
                        case "/setrole":
                            if chatRoles[chatID] == nil {
                                chatRoles[chatID] = [:]
                            }
                            chatRoles[chatID]?[thread_id] = splittedText[1]
                            
                            if chatHistories[chatID] == nil {
                                chatHistories[chatID] = [:]
                            }
                            chatHistories[chatID]?[thread_id] = [ .init(role: "system", content: splittedText[1]) ]
                            try await TelegramAPI.sendTelegramMessage(telegramUrl: telegramUrl, chat_id: chatID, text: "Роль изменена + история очищена", reply_parameters: nil, message_thread_id: thread_id != 0 ? thread_id : nil)
                            
                            
                        case "/clear_history", "/clear_history@SwiftPT_bot":
                            let role = chatRoles[chatID]?[thread_id] ?? systemPrompt
                            if chatHistories[chatID] == nil {
                                chatHistories[chatID] = [:]
                            }
                            chatHistories[chatID]?[thread_id] = [.init(role: "system", content: role)]
                            try await TelegramAPI.sendTelegramMessage(telegramUrl: telegramUrl, chat_id: chatID, text: "История очищена", reply_parameters: nil, message_thread_id: thread_id != 0 ? thread_id : nil)
                            
                            
                        case "/settemp":
                            if chatTemps[chatID] == nil {
                                chatTemps[chatID] = [:]
                            }
                            chatTemps[chatID]?[thread_id] = Float(splittedText[1]) ?? 1.5
                            try await TelegramAPI.sendTelegramMessage(telegramUrl: telegramUrl, chat_id: chatID, text: "Temperature: \(chatTemps[chatID]?[thread_id] ?? 1.5)", reply_parameters: nil, message_thread_id: thread_id != 0 ? thread_id : nil)
                            
                            
                        case "/tokens_toggle", "/tokens_toggle@SwiftPT_bot":
                            if chatShowStats[chatID] == nil {
                                chatShowStats[chatID] = [:]
                            }
                            let current = chatShowStats[chatID]?[thread_id] ?? false
                            chatShowStats[chatID]?[thread_id] = !current
                            try await TelegramAPI.sendTelegramMessage(telegramUrl: telegramUrl, chat_id: chatID, text: "Показывать расход токенов: \(!current)", reply_parameters: nil, message_thread_id: thread_id != 0 ? thread_id : nil)
                            
                            
                        case "/default_role", "/default_role@SwiftPT_bot":
                            if chatRoles[chatID] == nil {
                                chatRoles[chatID] = [:]
                            }
                            chatRoles[chatID]?[thread_id] = systemPrompt
                            
                            if chatHistories[chatID] == nil {
                                chatHistories[chatID] = [:]
                            }
                            chatHistories[chatID]?[thread_id] = [.init(role: "system", content: systemPrompt)]
                            try await TelegramAPI.sendTelegramMessage(telegramUrl: telegramUrl, chat_id: msg.chat.id, text: "Роль изменена на стандартную + история очищена", reply_parameters: nil, message_thread_id: thread_id != 0 ? thread_id : nil)
                            
                            
                        case "@SwiftPT_bot":
                            print(text)
                            try await processMention(msg: msg, cleanText: splittedText[1], thread_id: thread_id)
                            
                            
                        default:
                            continue
                        }
                    }
                }
            } catch {
                print("getUpdates error \(error)")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        
        func processMention(msg: TelegramMessage, cleanText: String, thread_id: Int64) async throws {
            let chatID = msg.chat.id
            
            if chatHistories[chatID] == nil {
                chatHistories[chatID] = [:]
            }
            if chatHistories[chatID]?[thread_id] == nil {
                let role = chatRoles[chatID]?[thread_id] ?? systemPrompt
                chatHistories[chatID]?[thread_id] = [.init(role: "system", content: role)]
            }
            
            // сообщение пользователя в исторю
            chatHistories[chatID]?[thread_id]?.append(.init(role: "user", content: cleanText))
            
            // отправить черновик чтобы юзер понял что промпт был принят
            let placeholder = try await TelegramAPI.sendTelegramMessage(
                telegramUrl: telegramUrl,
                chat_id: chatID,
                text: "Думаю...",
                reply_parameters: ReplyParameters(message_id: msg.message_id),
                message_thread_id: thread_id != 0 ? thread_id : nil
            )
            print("получил placeholder")
            // запрос к дипсику, причем с потоком
            let reqParams = Prompt(
                model: "deepseek-chat",
                messages: chatHistories[chatID]?[thread_id] ?? [.init(role: "system", content: systemPrompt)],
                stream: true,
                temperature: chatTemps[chatID]?[thread_id] ?? 1.5,
                showStats: chatShowStats[chatID]?[thread_id] ?? false
            )
            var accumulator = ""
            var lastLength = 0
            do {
                for try await piece in DeepseekAPI.deepseekStream(apiKey: deepseekKey, reqParams: reqParams, showStats: chatShowStats[chatID]?[thread_id] ?? false) {
                    accumulator += piece
                    // интервал обновление тг сообщения
                    if Date().timeIntervalSince(lastEdit) > 3 || (accumulator.count - lastLength) > 150 {
                        try await TelegramAPI.editTelegramMessage(
                            telegramUrl: telegramUrl,
                            chat_id: msg.chat.id,
                            message_id: placeholder?.message_id ?? msg.message_id, // тут чисто чтобы ошибку кинуло
                            text: accumulator
                        )
                        lastEdit = Date()
                        lastLength = accumulator.count
                    }
                }
            }
            // финальное редактирование
            let finalText = accumulator.isEmpty ? "Пустой ответ." : accumulator + "\nОтвет завершен."
            try await TelegramAPI.editTelegramMessage(
                telegramUrl: telegramUrl,
                chat_id: chatID,
                message_id: placeholder?.message_id ?? msg.message_id, // тут чисто чтобы ошибку кинуло
                text: finalText
            )
            // добавляем ответ бота в историю
            chatHistories[chatID]?[thread_id]?.append(.init(role: "assistant", content: accumulator))
        }
    }
    
    static func splitBySpace(from text: String) -> [String] {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .map(String.init)
        return [parts.first ?? "", parts.count > 1 ? parts[1] : ""]
    }
}
