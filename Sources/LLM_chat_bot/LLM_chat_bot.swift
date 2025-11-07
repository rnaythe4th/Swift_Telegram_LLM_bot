import AsyncHTTPClient
import Foundation

@main
struct LLM_chat_bot {
    
    static func main() async throws {
        let tgToken = try Config.env(.telegramToken)
        let deepseekKey = try Config.env(.deepseekKey)
        let companyChatId = try Int(Config.env(.companyChatId))
        
        let companyMembers = ". Участники чата: @max_semenko, @maythe4th, @vladnest02, @xleb_s_korochkoi и бот @CatchMyVidBot."
        
        let telegramUrl = "https://api.telegram.org/bot\(tgToken)"
        
        // 0 - просто чат, thread_id > 0 — конкретный тред
        var chatRoles: [Int: [Int64: String]] = [:]
        var chatHistories: [Int: [Int64: [ChatMessage]]] = [:]
        var chatTemps: [Int: [Int64: Float]] = [:]
        var chatShowStats: [Int: [Int64: Bool]] = [:]
        let maxHistoryLength = 11
        
        let systemPrompt = "Ты физик, тебя зовут Анатолий."
        let formatOptions = " Ты можешь форматировать свой текст в соответствии с HTML (по документации Telegram bot api)."
        
        var currentOffset: Int? = nil
        var lastEdit = Date.distantPast
        while true {
            do {
                let updates = try await TelegramAPI.getUpdates(telegramUrl: telegramUrl, offset: currentOffset)
                print("получил апдейты")
                if let maxUpdateId = updates.map(\.update_id).max() {
                    currentOffset = maxUpdateId + 1
                }
                
                for u in updates {
                    if let msg = u.message, let text = msg.text {
                        
                        let thread_id: Int64 = msg.message_thread_id ?? 0
                        let chatID = msg.chat.id
                        
                        let splittedText = splitBySpace(from: text)
                        
                        switch splittedText[0] {
                        case "/setrole":
                            // устанавливаем заданную роль
                            setRole(chatID: chatID, thread_id: thread_id, role: splittedText[1] + formatOptions)
                            // инициализируем чистую историю с заданной ролью
                            resetHistory(chatID: chatID, thread_id: thread_id, role: chatRoles[chatID]![thread_id]!)
                            // обратная связь юзеру
                            _ = try await TelegramAPI.sendTelegramMessage(telegramUrl: telegramUrl, chat_id: chatID, text: "Роль изменена + история очищена", reply_parameters: nil, message_thread_id: thread_id != 0 ? thread_id : nil)
                            
                            
                        case "/clear_history", "/clear_history@SwiftPT_bot":
                            // если роль уже есть, то просто сбрасываем историю и делаем первое сообщение с этой ролью
                            if let role = chatRoles[chatID]?[thread_id] {
                                resetHistory(chatID: chatID, thread_id: thread_id, role: role)
                            } else {
                                // а если роли нет, то сначала устанавливаем роль, а потом ресетаем историю с системной ролью
                                setRole(chatID: chatID, thread_id: thread_id, role: systemPrompt + formatOptions)
                                resetHistory(chatID: chatID, thread_id: thread_id, role: chatRoles[chatID]![thread_id]!)
                            }
                            // обратная связь юзеру
                            _ = try await TelegramAPI.sendTelegramMessage(telegramUrl: telegramUrl, chat_id: chatID, text: "История очищена", reply_parameters: nil, message_thread_id: thread_id != 0 ? thread_id : nil)
                            
                            
                        case "/settemp":
                            if chatTemps[chatID] == nil {
                                chatTemps[chatID] = [:]
                            }
                            chatTemps[chatID]?[thread_id] = Float(splittedText[1]) ?? 1.5
                            // обратная связь юзеру
                            _ = try await TelegramAPI.sendTelegramMessage(telegramUrl: telegramUrl, chat_id: chatID, text: "Temperature: \(chatTemps[chatID]?[thread_id] ?? 1.5)", reply_parameters: nil, message_thread_id: thread_id != 0 ? thread_id : nil)
                            
                            
                        case "/tokens_toggle", "/tokens_toggle@SwiftPT_bot":
                            if chatShowStats[chatID] == nil {
                                chatShowStats[chatID] = [:]
                            }
                            let current = chatShowStats[chatID]?[thread_id] ?? false
                            chatShowStats[chatID]?[thread_id] = !current
                            // обратная связь юзеру
                            _ = try await TelegramAPI.sendTelegramMessage(telegramUrl: telegramUrl, chat_id: chatID, text: "Показывать расход токенов: \(!current)", reply_parameters: nil, message_thread_id: thread_id != 0 ? thread_id : nil)
                            
                            
                        case "/default_role", "/default_role@SwiftPT_bot":
                            // устанавливаем стандартную роль
                            setRole(chatID: chatID, thread_id: thread_id, role: systemPrompt + formatOptions)
                            // инициализируем историю с установленной ролью
                            resetHistory(chatID: chatID, thread_id: thread_id, role: chatRoles[chatID]![thread_id]!)
                            // обратная связь юзеру
                            _ = try await TelegramAPI.sendTelegramMessage(telegramUrl: telegramUrl, chat_id: msg.chat.id, text: "Роль изменена на стандартную + история очищена", reply_parameters: nil, message_thread_id: thread_id != 0 ? thread_id : nil)
                            
                            
                        case "@SwiftPT_bot":
                            print(text)
                            try await processMention(msg: msg, cleanText: splittedText[1], chatID:chatID, thread_id: thread_id)
                            
                            
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
        
        func setRole(chatID: Int, thread_id: Int64, role: String) {
            if chatRoles[chatID] == nil {
                chatRoles[chatID] = [:]
            }
            
            if chatID == companyChatId {
                chatRoles[chatID]?[thread_id] = role + companyMembers
            } else {
                chatRoles[chatID]?[thread_id] = role
            }
        }
        
        func resetHistory(chatID: Int, thread_id: Int64, role: String) {
            if chatHistories[chatID] == nil {
                chatHistories[chatID] = [:]
            }
            
            chatHistories[chatID]?[thread_id] = [.init(role: "system", content: role)]
        }
        
        
        func processMention(msg: TelegramMessage, cleanText: String, chatID: Int, thread_id: Int64) async throws {
            var promptText = cleanText
            
            if let senderUsername = msg.from?.username {
                promptText = "Тебе пишет @\(senderUsername): \(cleanText)"
            } else {
                promptText = cleanText
            }
            
            //сначала проверки всё ли у нас есть, и если нет, то инициализация
            // не дает блин использовать просто chatTemps[chatID]?[thread_id, default: 1.5]
            // поэтому пока делаю тут
            
            // проверяем роль
            if chatRoles[chatID]?[thread_id] == nil {
                // если нет, то ставим стандартную
                setRole(chatID: chatID, thread_id: thread_id, role: systemPrompt + formatOptions)
            }
            
            // инициализируем историю чата, если ее нет
            if chatHistories[chatID] == nil {
                chatHistories[chatID] = [:]
            }
            // и теперь записываем туда сисемный промпт с ролью
            if chatHistories[chatID]?[thread_id] == nil {
                // роль уже точно есть, поэтому норм, force unwrap
                chatHistories[chatID]?[thread_id] = [.init(role: "system", content: chatRoles[chatID]![thread_id]!)]
            }
            
            // проверка длины истории сообщений
            if chatHistories[chatID]![thread_id]!.count >= maxHistoryLength {
                // системный промпт с ролью надо оставить (индекс 0)
                chatHistories[chatID]![thread_id]!.removeSubrange(1...2)
            }
            
            // сообщение пользователя в исторю
            chatHistories[chatID]?[thread_id]?.append(.init(role: "user", content: promptText, name: msg.from?.username ?? nil))
            
            // отправить черновик чтобы юзер понял что промпт был принят
            let placeholder = try await TelegramAPI.sendTelegramMessage(
                telegramUrl: telegramUrl,
                chat_id: chatID,
                text: "Думаю...",
                reply_parameters: ReplyParameters(message_id: msg.message_id),
                message_thread_id: thread_id != 0 ? thread_id : nil
            )
            
            // запрос к дипсику, причем с потоком
            let reqParams = Prompt(
                model: "deepseek-chat",
                messages: chatHistories[chatID]![thread_id]!,
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
            let finalText = accumulator.isEmpty ? "Пустой ответ." : accumulator + "\n\n✅ <b>Ответ завершен.</b>"
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
