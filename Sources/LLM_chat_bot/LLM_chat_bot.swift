import Foundation

@main
struct LLM_chat_bot {
    
    static let companyMembers = ". Участники чата: max_semenko, maythe4th, vladnest02, xleb_s_korochkoi и бот CatchMyVidBot."
    static let systemPrompt = "Ты физик, тебя зовут Анатолий."
    static let formatOptions = " Ты можешь форматировать свой текст в соответствии с HTML (по документации Telegram bot api). При упоминании или обращении к участникам никогда не ставь @ перед их именами, чтобы не тегать их."
    //    static let formatOptions = " Отвечай с внятным форматированием и аккуратно соблюдай HTML-entities для Telegram."
    
    static func main() async throws {
        let appConfig = try AppConfig.load()
        let deepseekKey = appConfig.deepseekKey
        let routerApiKey = appConfig.routerApiKey
        
        let telegramUrl = appConfig.telegramUrl
        
        let state = BotState(
            model: "x-ai/grok-4.1-fast",
            systemPrompt: systemPrompt,
            formatOptions: formatOptions,
            companyChatId: appConfig.companyChatId,
            companyMembers: companyMembers,
            defaultHistoryLength: 11,
        )
        
        let tasks = TaskCenter()
        
        // избегаем 409 (не знаю откуда оно взялось, потом разобраться)
        try? await TelegramAPI.deleteWebhook(telegramUrl: telegramUrl)
        
        var currentOffset: Int? = nil
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
                        print("[Bot] callback query received, data=\(cq.data ?? "nil"), id=\(cq.id)")
                        // формат callback_data ниже
                        let data = cq.data ?? ""
                        if data.hasPrefix("stop:") {
                            // распарсим chatID и threadID
                            let parts = data.split(separator: ":")
                            if parts.count >= 3,
                               let chatID = Int(parts[1]),
                               let threadID = Int64(parts[2]) {
                                print("[Bot] stop parsed chatID=\(chatID), threadID=\(threadID)")
                                
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
                                print("[Bot] stop callback answered")
                            } else {
                                print("[Bot] stop callback parse failed, raw=\(data)")
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
                try await sendUserFeedback("Роль изменена + история очищена")
                
                
            case "/clear_history", "/clear_history@SwiftPT_bot":
                let role = await state.ensureRole(chatID: chatID, thread_id: thread_id)
                await state.resetHistory(chatID: chatID, thread_id: thread_id, role: role)
                // обратная связь юзеру
                try await sendUserFeedback("История очищена")
                
                
            case "/settemp":
                guard let temp = Float(arg), (0.0...2.0).contains(temp) else {
                    let errorMessage = Float(arg) == nil
                    ? "Ошибка: укажите ЧИСЛО от 0 до 2"
                    : "Ошибка: укажите число от 0 до 2. Вы указали: \(Float(arg)!)"
                    // обратная связь юзеру
                    try await sendUserFeedback(errorMessage)
                    return
                }
                await state.setTemp(chatID: chatID, thread_id: thread_id, value: temp)
                // обратная связь юзеру
                try await sendUserFeedback("Temperature: \(await state.temp(chatID: chatID, thread_id: thread_id))")
                
            case "/model":
                // установка новой модели и получение старой
                let oldModel = await state.setModel(newModel: String(arg))
                // сброс истории
                let role = await state.ensureRole(chatID: chatID, thread_id: thread_id)
                await state.resetHistory(chatID: chatID, thread_id: thread_id, role: role)
                // фидбек пользователю
                try await sendUserFeedback("""
Модель изменена:
\(oldModel) ----> \(await state.model).
История очищена.
""")
                
                
            case "/tokens_toggle", "/tokens_toggle@SwiftPT_bot":
                let new = await state.toggleShowStats(chatID: chatID, thread_id: thread_id)
                // обратная связь юзеру
                try await sendUserFeedback("Показывать расход токенов: \(new)")
                
                
            case "/default_role", "/default_role@SwiftPT_bot":
                // устанавливаем стандартную роль
                await state.setRole(chatID: chatID, thread_id: thread_id, role: systemPrompt + formatOptions)
                let role = await state.ensureRole(chatID: chatID, thread_id: thread_id)
                // инициализируем историю с установленной ролью
                await state.resetHistory(chatID: chatID, thread_id: thread_id, role: role)
                // обратная связь юзеру
                try await sendUserFeedback("Роль изменена на стандартную + история очищена")
                
                
            case "/historylength" , "/historylength@SwiftPT_bot":
                guard let newMax = Int(arg), (0...50).contains(newMax) else {
                    let errorMessage = Int(arg) == nil
                    ? "Ошибка: укажите ЧИСЛО от 0 до 50"
                    : "Ошибка: укажите число от 0 до 50. Вы указали: \(Int(arg)!)"
                    // обратная связь юзеру
                    try await sendUserFeedback(errorMessage)
                    return
                }
                await state.setMaxHistory(chatID: chatID, thread_id: thread_id, newMax: newMax)
                // обратная связь юзеру
                try await sendUserFeedback("Длина истории: \(newMax) сообщений")
                
                
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
            
            func sendUserFeedback(_ text: String) async throws {
                _ = try await TelegramAPI.sendTelegramMessage(telegramUrl: telegramUrl, chat_id: chatID, text: text, reply_parameters: nil, message_thread_id: thread_id != 0 ? thread_id : nil)
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
            
            await state.ensureMaxHistory(chatID: chatID, thread_id: thread_id)
            
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
            
            let provider = await state.serviceProvider
            let streamRequest: ProviderStreamRequest

            switch provider {
            case .openrouter:
                streamRequest = .openrouter(RouterRequestBody(
                    messages: messages,
                    model: await state.model,
                    stream: true,
                    stream_options: showStats ? .init(include_usage: true) : nil,
                    temperature: temp))
            case .deepseek:
                streamRequest = .deepseek(Prompt(
                    model: "deepseek-chat",
                    messages: messages,
                    stream: true,
                    temperature: temp,
                    showStats: showStats
                ))
            }
            
            let key = StreamKey(chatID: chatID, threadID: thread_id)
            print("[Bot] starting stream key=\(key), provider=\(provider.rawValue), showStats=\(showStats)")
            
            let streamingTask = Task {
                var accumulator = ""
                var lastLength = 0
                let clock = ContinuousClock()
                var lastEdit = clock.now // по идее теперь локально
                
                var isCancelled = false
                
                do {
                    let responseStream = streamRequest.makeStream(
                        routerApiKey: routerApiKey,
                        deepseekKey: deepseekKey,
                        showStats: showStats
                    )

                    for try await chunk in responseStream {
                        // Проверяем отмену в начале каждой итерации
                        if Task.isCancelled {
                            isCancelled = true
                            print("[Bot] stream cancelled flag observed in \(streamRequest.provider.rawValue) loop")
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
                } catch is CancellationError {
                    isCancelled = true
                    print("[Bot] streaming task received CancellationError for key=\(key)")
                } catch {
                    // Обработка ошибок
                    print("[Bot] streaming task failed for key=\(key): \(error)")
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
                if Task.isCancelled {
                    isCancelled = true
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
                print("[Bot] stream task finished key=\(key), cancelled=\(isCancelled), chars=\(accumulator.count)")
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
