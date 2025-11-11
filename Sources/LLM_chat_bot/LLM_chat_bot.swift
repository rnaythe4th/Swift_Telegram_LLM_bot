import AsyncHTTPClient
import Foundation

actor TaskCenter {
    private var tasks: [StreamKey: Task<Void, Never>] = [:]
    
    func register(key: StreamKey, task: Task<Void, Never>) {
        tasks[key] = task
    }
    
    func cancel(key: StreamKey) {
        tasks[key]?.cancel()
        tasks[key] = nil
    }
    
    func cancelAll(in chatID: Int, threadID: Int64) {
        for (k, t) in tasks where k.chatID == chatID && k.threadID == threadID {
            t.cancel()
            tasks[k] = nil
        }
    }
    
    func latest(for chatID: Int, threadID: Int64) -> StreamKey? {
        // Not strictly LIFO, but returning any one active key is fine for /stop.
        return tasks.keys.first(where: { $0.chatID == chatID && $0.threadID == threadID })
    }
}

actor BotState {
    var chatRoles: [Int: [Int64: String]] = [:]
    var chatHistories: [Int: [Int64: [ChatMessage]]] = [:]
    var chatTemps: [Int: [Int64: Float]] = [:]
    var chatShowStats: [Int: [Int64: Bool]] = [:]
    let maxHistoryLength: Int
    
    let systemPrompt: String
    let formatOptions: String
    let companyChatId: Int
    let companyMembers: String
    
    init(systemPrompt: String, formatOptions: String, companyChatId: Int, companyMembers: String, maxHistoryLength: Int) {
        self.systemPrompt = systemPrompt
        self.formatOptions = formatOptions
        self.companyChatId = companyChatId
        self.companyMembers = companyMembers
        self.maxHistoryLength = maxHistoryLength
    }
    
    func setRole(chatID: Int, thread_id: Int64, role: String) {
        if chatRoles[chatID] == nil { chatRoles[chatID] = [:] }
        chatRoles[chatID]![thread_id] = (chatID == companyChatId) ? role + companyMembers : role
    }
    
    func ensureRole(chatID: Int, thread_id: Int64) -> String {
        if chatRoles[chatID]?[thread_id] == nil {
            setRole(chatID: chatID, thread_id: thread_id, role: systemPrompt + formatOptions)
        }
        return chatRoles[chatID]![thread_id]!
    }
    
    func resetHistory(chatID: Int, thread_id: Int64, role: String) {
        if chatHistories[chatID] == nil { chatHistories[chatID] = [:] }
        chatHistories[chatID]![thread_id] = [.init(role: "system", content: role)]
    }
    
    func ensureHistory(chatID: Int, thread_id: Int64) {
        if chatHistories[chatID] == nil { chatHistories[chatID] = [:] }
        if chatHistories[chatID]![thread_id] == nil {
            let role = ensureRole(chatID: chatID, thread_id: thread_id)
            chatHistories[chatID]![thread_id] = [.init(role: "system", content: role)]
        }
    }
    
    func trimHistoryIfNeeded(chatID: Int, thread_id: Int64) {
        guard var arr = chatHistories[chatID]?[thread_id] else { return }
        if arr.count >= maxHistoryLength, arr.count > 1 {
            // оставляем системное 0, удаляем 1..2
            let hi = min(2, arr.count - 1)
            arr.removeSubrange(1...hi)
            chatHistories[chatID]![thread_id] = arr
        }
    }
    
    func appendUser(chatID: Int, thread_id: Int64, content: String, username: String?) {
        chatHistories[chatID]![thread_id]!.append(.init(role: "user", content: content, name: username))
    }
    
    func appendAssistant(chatID: Int, thread_id: Int64, content: String) {
        chatHistories[chatID]![thread_id]!.append(.init(role: "assistant", content: content))
    }
    
    func temp(chatID: Int, thread_id: Int64) -> Float { chatTemps[chatID]?[thread_id] ?? 1.5 }
    
    func setTemp(chatID: Int, thread_id: Int64, value: Float) {
        if chatTemps[chatID] == nil { chatTemps[chatID] = [:] }
        chatTemps[chatID]![thread_id] = value
    }
    
    func showStats(chatID: Int, thread_id: Int64) -> Bool { chatShowStats[chatID]?[thread_id] ?? false }
    
    func toggleShowStats(chatID: Int, thread_id: Int64) -> Bool {
        if chatShowStats[chatID] == nil { chatShowStats[chatID] = [:] }
        let new = !(chatShowStats[chatID]![thread_id] ?? false)
        chatShowStats[chatID]![thread_id] = new
        return new
    }
    
    func messages(chatID: Int, thread_id: Int64) -> [ChatMessage] {
        chatHistories[chatID]![thread_id]!
    }
}

@main
struct LLM_chat_bot {
    
    static let companyMembers = ". Участники чата: @max_semenko, @maythe4th, @vladnest02, @xleb_s_korochkoi и бот @CatchMyVidBot."
    static let systemPrompt = "Ты физик, тебя зовут Анатолий."
    static let formatOptions = " Ты можешь форматировать свой текст в соответствии с HTML (по документации Telegram bot api)."
//    static let formatOptions = " Отвечай с внятным форматированием и аккуратно соблюдай HTML-entities для Telegram."
    
    static func main() async throws {
        let tgToken = try Config.env(.telegramToken)
        let deepseekKey = try Config.env(.deepseekKey)
        let companyChatId = try Int(Config.env(.companyChatId))
        
        let telegramUrl = "https://api.telegram.org/bot\(tgToken)"
        
        let state = BotState(
            systemPrompt: systemPrompt,
            formatOptions: formatOptions,
            companyChatId: companyChatId ?? 0,
            companyMembers: companyMembers,
            maxHistoryLength: 11
        )
        
        let tasks = TaskCenter()
        
        var currentOffset: Int? = nil
        var lastEdit = Date.distantPast
        while true {
            do {
                let updates = try await TelegramAPI.getUpdates(telegramUrl: telegramUrl, offset: currentOffset)
                print("-------new updates-------")
                // среди всех обновлений находим максимальный оффсет
                if let maxUpdateId = updates.map(\.update_id).max() {
                    currentOffset = maxUpdateId + 1
                }
                // обработка каждого апдейта
                for u in updates {
                    if let cq = u.callback_query {
                        // формат callback_data ниже
                        let data = cq.data ?? ""
                        if data.hasPrefix("stop:") {
                            // распарсим chatID и threadID
                            let parts = data.split(separator: ":")
                            if parts.count >= 3,
                               let chatID = Int(parts[1]),
                               let threadID = Int64(parts[2]) {
                                
                                await tasks.cancelAll(in: chatID, threadID: threadID)
                                
                                // визуально подчистим клавиатуру на сообщении, по которому нажали
                                if let msg = cq.message {
                                    try? await TelegramAPI.editTelegramMessage(
                                        telegramUrl: telegramUrl,
                                        chat_id: msg.chat.id,
                                        message_id: msg.message_id,
                                        text: (msg.text ?? "") + "\n\n🛑 Остановлено пользователем.",
                                        reply_markup: InlineKeyboardMarkup(inline_keyboard: []) // убираем кнопки
                                    )
                                }
                                
                                // подтвердим нажатие
                                try? await TelegramAPI.answerCallbackQuery(
                                    telegramUrl: telegramUrl,
                                    callback_query_id: cq.id,
                                    text: "Остановлено"
                                )
                            }
                        }
                        continue
                    }
                    // если текста сообщения нет, то скипаем этот апдейт
                    guard let msg = u.message, let text = msg.text else { continue }
                    print(text)
                    // таска для синхронной обработки нескольких сообщений
                    Task {
                        do {
                            try await routeMessage(msg: msg, text: text)
                        } catch {
                            print("routeMessage error:", error)
                        }
                    }
                }
            } catch {
                print("getUpdates error \(error)")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        
        // обработка сообщения пользователя
        func routeMessage(msg: TelegramMessage, text: String) async throws {
            let (cmd, arg) = Self.splitBySpace(from: text)
            let chatID = msg.chat.id
            let thread_id: Int64 = msg.message_thread_id ?? 0
            
            switch cmd {
            case "/setrole":
                // устанавливаем заданную роль
                await state.setRole(chatID: chatID, thread_id: thread_id, role: arg + formatOptions)
                let role = await state.ensureRole(chatID: chatID, thread_id: thread_id)
                // инициализируем чистую историю с заданной ролью
                await state.resetHistory(chatID: chatID, thread_id: thread_id, role: role)
                // обратная связь юзеру
                _ = try await TelegramAPI.sendTelegramMessage(telegramUrl: telegramUrl, chat_id: chatID, text: "Роль изменена + история очищена", reply_parameters: nil, message_thread_id: thread_id != 0 ? thread_id : nil)
                
            case "/clear_history", "/clear_history@SwiftPT_bot":
                let role = await state.ensureRole(chatID: chatID, thread_id: thread_id)
                await state.resetHistory(chatID: chatID, thread_id: thread_id, role: role)
                // обратная связь юзеру
                _ = try await TelegramAPI.sendTelegramMessage(telegramUrl: telegramUrl, chat_id: chatID, text: "История очищена", reply_parameters: nil, message_thread_id: thread_id != 0 ? thread_id : nil)
                
            case "/settemp":
                await state.setTemp(chatID: chatID, thread_id: thread_id, value: Float(arg) ?? 1.5)
                // обратная связь юзеру
                _ = try await TelegramAPI.sendTelegramMessage(telegramUrl: telegramUrl, chat_id: chatID, text: "Temperature: \(await state.temp(chatID: chatID, thread_id: thread_id))", reply_parameters: nil, message_thread_id: thread_id != 0 ? thread_id : nil)
                
            case "/tokens_toggle", "/tokens_toggle@SwiftPT_bot":
                let new = await state.toggleShowStats(chatID: chatID, thread_id: thread_id)
                // обратная связь юзеру
                _ = try await TelegramAPI.sendTelegramMessage(telegramUrl: telegramUrl, chat_id: chatID, text: "Показывать расход токенов: \(new)", reply_parameters: nil, message_thread_id: thread_id != 0 ? thread_id : nil)
                
            case "/default_role", "/default_role@SwiftPT_bot":
                // устанавливаем стандартную роль
                await state.setRole(chatID: chatID, thread_id: thread_id, role: systemPrompt + formatOptions)
                let role = await state.ensureRole(chatID: chatID, thread_id: thread_id)
                // инициализируем историю с установленной ролью
                await state.resetHistory(chatID: chatID, thread_id: thread_id, role: role)
                // обратная связь юзеру
                _ = try await TelegramAPI.sendTelegramMessage(telegramUrl: telegramUrl, chat_id: chatID, text: "Роль изменена на стандартную + история очищена", reply_parameters: nil, message_thread_id: thread_id != 0 ? thread_id : nil)
                
            case "@SwiftPT_bot":
                print(text)
                // обрабатываем сообщение с промптом
                try await processMention(msg: msg, cleanText: arg, chatID: chatID, thread_id: thread_id)
                
            default:
                // если пишут в личку, то реагировать надо на всё
                if msg.chat.type == "private" {
                    try await processMention(msg: msg, cleanText: text, chatID: chatID, thread_id: thread_id)
                } else {
                    break
                }
            }
        }
        
        // обработка сообщения с промптом
        func processMention(msg: TelegramMessage, cleanText: String, chatID: Int, thread_id: Int64) async throws {
            // текст промпта для дипсика
            let promptText: String = {
                if let u = msg.from?.username { return "Тебе пишет @\(u): \(cleanText)" }
                return cleanText
            }()
            
            // подготовка роли и истории в акторе
            let role = await state.ensureRole(chatID: chatID, thread_id: thread_id)
            await state.ensureHistory(chatID: chatID, thread_id: thread_id)
            
            // проверка длины истории сообщений
            await state.trimHistoryIfNeeded(chatID: chatID, thread_id: thread_id)
            
            // сообщение пользователя в исторю
            await state.appendUser(chatID: chatID, thread_id: thread_id, content: promptText, username: msg.from?.username)
            
            let stopMarkup = InlineKeyboardMarkup(inline_keyboard: [[
                .init(text: "🛑 СТОП", callback_data: "stop:\(chatID):\(thread_id)")
            ]])
            
            // отправить черновик чтобы юзер понял что промпт был принят
            let placeholder = try await TelegramAPI.sendTelegramMessage(
                telegramUrl: telegramUrl,
                chat_id: chatID,
                text: "Думаю...",
                reply_parameters: ReplyParameters(message_id: msg.message_id),
                message_thread_id: thread_id != 0 ? thread_id : nil,
                reply_markup: stopMarkup
            )
            
            // параметры генерации читаем из актора
            let temp = await state.temp(chatID: chatID, thread_id: thread_id)
            let showStats = await state.showStats(chatID: chatID, thread_id: thread_id)
            let messages = await state.messages(chatID: chatID, thread_id: thread_id)
            
            // запрос к дипсику, причем с потоком
            let reqParams = Prompt(
                model: "deepseek-chat",
                messages: messages,
                stream: true,
                temperature: temp,
                showStats: showStats
            )
            
            let key = StreamKey(chatID: chatID, threadID: thread_id)
            
            let streamingTask = Task {
                var accumulator = ""
                var lastLength = 0
                let clock = ContinuousClock()
                var lastEdit = clock.now // по идее теперь локально
                
                var isCancelled = false
                
                do {
                    for try await chunk in DeepseekAPI.deepseekStream(apiKey: deepseekKey, reqParams: reqParams, showStats: showStats) {
                        // Проверяем отмену в начале каждой итерации
                        if Task.isCancelled {
                            isCancelled = true
                            break
                        }
                        
                        accumulator += chunk
                        // интервал обновление тг сообщения
                        if clock.now - lastEdit > .seconds(3) || (accumulator.count - lastLength) > 300 {
                            do {
                                try await TelegramAPI.editTelegramMessage(
                                    telegramUrl: telegramUrl,
                                    chat_id: msg.chat.id,
                                    message_id: placeholder?.message_id ?? msg.message_id, // тут чисто чтобы ошибку кинуло
                                    text: accumulator,
                                    reply_markup: stopMarkup
                                )
                                lastEdit = clock.now
                                lastLength = accumulator.count
                            } catch {
                                if (error as NSError).localizedDescription.contains("Too Many Requests") {
                                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                                } else {
                                    throw error
                                }
                            }
                        }
                    }
                } catch {
                    // Обработка ошибок
                    try? await TelegramAPI.editTelegramMessage(
                        telegramUrl: telegramUrl,
                        chat_id: chatID,
                        message_id: placeholder?.message_id ?? msg.message_id,
                        text: "❌ Ошибка: \(error)",
                        reply_markup: InlineKeyboardMarkup(inline_keyboard: [])
                    )
                    await tasks.cancel(key: key)
                    return
                }
                // финальное редактирование
                let finalText: String
                let finalMarkup: InlineKeyboardMarkup?
                
                if isCancelled {
                    finalText = accumulator.isEmpty ?
                    "🛑 <b>Остановлено пользователем.</b>" :
                    accumulator + "\n\n🛑 <b>Остановлено пользователем.</b>"
                    finalMarkup = InlineKeyboardMarkup(inline_keyboard: [])
                } else {
                    finalText = accumulator.isEmpty ?
                    "Пустой ответ." :
                    accumulator + "\n\n✅ <b>Ответ завершен.</b>"
                    finalMarkup = InlineKeyboardMarkup(inline_keyboard: [])
                }
                
                try? await TelegramAPI.editTelegramMessage(
                    telegramUrl: telegramUrl,
                    chat_id: chatID,
                    message_id: placeholder?.message_id ?? msg.message_id, // тут чисто чтобы ошибку кинуло
                    text: finalText,
                    reply_markup: finalMarkup
                )
                
                // добавляем ответ бота в историю
                await state.appendAssistant(chatID: chatID, thread_id: thread_id, content: accumulator)
                
                await tasks.cancel(key: key)
            }
            // регистрируем задачу для этого чата/треда
            await tasks.register(key: key, task: streamingTask)
        }
    }
    
    static func splitBySpace(from text: String) -> (String, String) {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .map(String.init)
        return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
    }
}
