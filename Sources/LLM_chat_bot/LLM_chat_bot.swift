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
        
        let state = ChatContextStore(
            model: "google/gemini-3-flash-preview",
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
            let parsedCommand = ParsedBotCommand.parse(from: text)
            let chatID = msg.chat.id
            let thread_id: Int64 = msg.message_thread_id ?? 0
            
            switch parsedCommand.name {
            case .setRole:
                // устанавливаем роль и сразу сбрасываем историю в одной actor-операции
                _ = await state.setRoleAndResetHistory(chatID: chatID, thread_id: thread_id, role: parsedCommand.argument + formatOptions)
                // обратная связь юзеру
                try await sendUserFeedback("Роль изменена + история очищена")
                
            case .clearHistory:
                await state.clearHistory(chatID: chatID, thread_id: thread_id)
                // обратная связь юзеру
                try await sendUserFeedback("История очищена")
                
            case .setTemp:
                guard let temp = Float(parsedCommand.argument), (0.0...2.0).contains(temp) else {
                    let errorMessage = Float(parsedCommand.argument) == nil
                    ? "Ошибка: укажите ЧИСЛО от 0 до 2"
                    : "Ошибка: укажите число от 0 до 2. Вы указали: \(Float(parsedCommand.argument)!)"
                    // обратная связь юзеру
                    try await sendUserFeedback(errorMessage)
                    return
                }
                await state.setTemp(chatID: chatID, thread_id: thread_id, value: temp)
                // обратная связь юзеру
                try await sendUserFeedback("Temperature: \(await state.temp(chatID: chatID, thread_id: thread_id))")
                
            case .model:
                // атомарно меняем модель и сбрасываем историю
                let changedModel = await state.setModelAndResetHistory(
                    chatID: chatID,
                    thread_id: thread_id,
                    newModel: String(parsedCommand.argument)
                )
                // фидбек пользователю
                try await sendUserFeedback("""
Модель изменена:
\(changedModel.oldModel) ----> \(changedModel.newModel).
История очищена.
""")
                
            case .showTokens:
                let new = await state.toggleShowStats(chatID: chatID, thread_id: thread_id)
                // обратная связь юзеру
                try await sendUserFeedback("Показывать расход токенов: \(new)")
            
            case .showCost:
                let new = await state.toggleShowCost(chatID: chatID, thread_id: thread_id)
                try await sendUserFeedback("Показывать стоимость сообщений: \(new)")
                
            case .showModel:
                let new = await state.toggleShowModel(chatID: chatID, thread_id: thread_id)
                try await sendUserFeedback("Показывать использованную модель: \(new)")
                
            case .help:
                let currentModel = await state.getCurrentModel(chatID: chatID, thread_id: thread_id)
                let currentRole = await state.getCurrentRole(chatID: chatID, thread_id: thread_id)
                let currentTemp = await state.temp(chatID: chatID, thread_id: thread_id)
                let currentMaxHistory = await state.getCurrentMaxHistory(chatID: chatID, thread_id: thread_id)
                let currentShowTokens = await state.getShowStats(chatID: chatID, thread_id: thread_id)
                let currentShowCost = await state.getShowCost(chatID: chatID, thread_id: thread_id)
                let currentShowModel = await state.getShowModel(chatID: chatID, thread_id: thread_id)
                let defaultRole = await state.defaultRole(chatID: chatID)
                let currentProvider = await state.serviceProvider.rawValue
                try await sendUserFeedback("""
                    /setrole <Новая роль> - установить новую роль боту и очистить историю сообщений
                    /clear_history - очистить историю сообщений, сохранив роль
                    /settemp <число> - задать креативность бота. 2.0 - максимальная креативность, 0.0 - максимальна точность и стабильность ответов. (По умолчанию = 1.5)
                    /show_tokens - вкл/выкл показ расхода токенов, использованных для генерации сообщения. (По умолчанию = выкл)
                    /default_role - вернуть стандартную роль
                    /historylength <число> - задать количество последних сообщений, которые будет помнить бот. (По умолчанию = 11)
                    /model <новая модель> - задать новую модель ИИ для ответов (По умолчанию - \(state.defaultModel)
                    /show_model - вкл/выкл показ использованной модели (По умолчанию = вкл)
                    /show_cost - вкл/выкл показ стоимости сгенерированного сообщения в $ (По умолчанию = выкл)
                    
                    -------------------
                    Текущие настройки для этого чата:
                    -------------------
                    
                    • Провайдер: \(currentProvider)
                    • Модель: \(currentModel)
                    • Temperature: \(currentTemp)
                    • Длина истории: \(currentMaxHistory)
                    • Показать расход токенов: \(currentShowTokens)
                    • Показать стоимость сообщения: \(currentShowCost)
                    • Показать использованную модель: \(currentShowModel)
                    • Роль: <blockquote>\(currentRole)</blockquote>
                    • Дефолтная роль: <blockquote>\(defaultRole)</blockquote>
                    """)
                
            case .defaultRole:
                // устанавливаем стандартную роль и сразу сбрасываем историю
                _ = await state.setRoleAndResetHistory(chatID: chatID, thread_id: thread_id, role: systemPrompt + formatOptions)
                // обратная связь юзеру
                try await sendUserFeedback("Роль изменена на стандартную + история очищена")
                
            case .historyLength:
                guard let newMax = Int(parsedCommand.argument), (0...50).contains(newMax) else {
                    let errorMessage = Int(parsedCommand.argument) == nil
                    ? "Ошибка: укажите ЧИСЛО от 0 до 50"
                    : "Ошибка: укажите число от 0 до 50. Вы указали: \(Int(parsedCommand.argument)!)"
                    // обратная связь юзеру
                    try await sendUserFeedback(errorMessage)
                    return
                }
                await state.setMaxHistory(chatID: chatID, thread_id: thread_id, newMax: newMax)
                // обратная связь юзеру
                try await sendUserFeedback("Длина истории: \(newMax) сообщений")
                
            case .mention:
                print(text)
                // обрабатываем сообщение с промптом
                try await processMention(msg: msg, cleanText: parsedCommand.argument, chatID: chatID, thread_id: thread_id)
                
            case .provider:
                var feedback: String
//                switch parsedCommand.argument {
//                case "deepseek":
//                    feedback = await state.changeProvider(newProvider: .deepseek)
//                case "openrouter":
//                    feedback = await state.changeProvider(newProvider: .openrouter)
//                case "yandex":
//                    feedback = await state.changeProvider(newProvider: .yandex)
//                default:
//                    feedback = "Invalid provider name. Available: deepseek, openrouter, yandex."
//                }
                if let provider = ServiceProvider(rawValue: parsedCommand.argument.capitalized) {
                    feedback = await state.changeProvider(chatID: chatID, thread_id: thread_id, newProvider: provider) + " ----> \(parsedCommand.argument)"
                } else {
                    feedback = "Invalid provider name. Available: deepseek, openrouter, yandex."
                }
                try await sendUserFeedback(feedback)
                
            case .unknown:
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
            func formatTokenValue(_ value: Double) -> String {
                if value.rounded(.towardZero) == value {
                    return String(Int(value))
                }
                return String(format: "%.3f", value)
            }

            func formatFooter(meta: StreamMeta?, fallbackModel: String, showTokens: Bool, showCost: Bool, showModel: Bool) -> String? {
                guard showTokens || showCost || showModel else { return nil }

                var lines: [String] = ["", "━━━━━━━━━━━━━"]
                let usage = meta?.usage

                if showTokens {
                    var hasAnyTokenData = false

                    if let prompt = usage?.promptTokens {
                        lines.append("• Prompt: \(formatTokenValue(prompt))")
                        hasAnyTokenData = true
                    }
                    if let cacheHit = usage?.cacheHitTokens {
                        lines.append("  • cache hit: \(formatTokenValue(cacheHit))")
                        hasAnyTokenData = true
                    }
                    if let cacheWrite = usage?.cacheWriteTokens {
                        lines.append("  • cache write: \(formatTokenValue(cacheWrite))")
                        hasAnyTokenData = true
                    }
                    if let cacheMiss = usage?.cacheMissTokens {
                        lines.append("  • cache miss: \(formatTokenValue(cacheMiss))")
                        hasAnyTokenData = true
                    }
                    if let completion = usage?.completionTokens {
                        lines.append("• Completion: \(formatTokenValue(completion))")
                        hasAnyTokenData = true
                    }
                    if let reasoning = usage?.reasoningTokens {
                        lines.append("  • reasoning: \(formatTokenValue(reasoning))")
                        hasAnyTokenData = true
                    }
                    if let total = usage?.totalTokens {
                        lines.append("• Total: \(formatTokenValue(total))")
                        hasAnyTokenData = true
                    }

                    if !hasAnyTokenData {
                        lines.append("• Токены: н/д")
                    }
                }

                if showCost {
                    if let cost = usage?.cost {
                        lines.append("• Стоимость: $\(String(format: "%.6f", cost))")
                    } else {
                        lines.append("• Стоимость: н/д")
                    }
                }

                if showModel {
                    lines.append("Модель: \(meta?.model ?? fallbackModel)")
                }

                return lines.count > 2 ? lines.joined(separator: "\n") : nil
            }

            // текст промпта для дипсика
            let promptText: String = {
                if let u = msg.from?.username { return "Тебе пишет @\(u): \(cleanText)" }
                return cleanText
            }()

            // атомарно обновляем контекст и получаем снимок параметров генерации
            let snapshot = await state.prepareGeneration(
                chatID: chatID,
                thread_id: thread_id,
                userContent: promptText,
                username: msg.from?.username
            )

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
            let temp = snapshot.temperature
            let showStats = snapshot.showStats
            let showCost = snapshot.showCost
            let showModel = snapshot.showModel
            let messages = snapshot.messages

            let provider = snapshot.provider
            let streamRequest: ProviderStreamRequest
            let fallbackModel: String

            switch provider {
            case .openrouter:
                streamRequest = .openrouter(RouterRequestBody(
                    messages: messages,
                    model: snapshot.model,
                    stream: true,
                    stream_options: showStats || showCost ? .init(include_usage: true) : nil,
                    temperature: temp))
                fallbackModel = snapshot.model
            case .deepseek:
                streamRequest = .deepseek(Prompt(
                    model: "deepseek-chat",
                    messages: messages,
                    stream: true,
                    temperature: temp,
                    showStats: showStats
                ))
                fallbackModel = "deepseek-chat"
            case .yandex:
                streamRequest = .openrouter(RouterRequestBody(
                    messages: messages,
                    model: snapshot.model,
                    stream: true,
                    stream_options: showStats || showCost ? .init(include_usage: true) : nil,
                    temperature: temp))
                fallbackModel = snapshot.model
            }

            let key = StreamKey(chatID: chatID, threadID: thread_id)
            print("[Bot] starting stream key=\(key), provider=\(provider.rawValue), showStats=\(showStats)")

            let streamingTask = Task {
                var accumulator = ""
                var streamMeta: StreamMeta?
                var lastLength = 0
                let clock = ContinuousClock()
                var lastEdit = clock.now // по идее теперь локально

                var isCancelled = false

                do {
                    let responseStream = streamRequest.makeStream(
                        routerApiKey: routerApiKey,
                        deepseekKey: deepseekKey
                    )

                    for try await event in responseStream {
                        // Проверяем отмену в начале каждой итерации
                        if Task.isCancelled {
                            isCancelled = true
                            print("[Bot] stream cancelled flag observed in \(streamRequest.provider.rawValue) loop")
                            break
                        }

                        switch event {
                        case .text(let chunk):
                            accumulator += chunk
                            // интервал обновление тг сообщения
                            if clock.now - lastEdit > .seconds(3) || (accumulator.count - lastLength) > 300 {
                                do {
                                    try await TelegramAPI.editTelegramMessage(
                                        telegramUrl: telegramUrl,
                                        chat_id: msg.chat.id,
                                        message_id: placeholder.message_id,
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
                        case .meta(let meta):
                            streamMeta = meta
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
                        message_id: placeholder.message_id,
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
                    let footer = formatFooter(
                        meta: streamMeta,
                        fallbackModel: fallbackModel,
                        showTokens: showStats,
                        showCost: showCost,
                        showModel: showModel
                    ) ?? ""

                    finalText = accumulator.isEmpty ?
                    "Пустой ответ.\(footer)\n\n✅ <b>Ответ завершен.</b>" :
                    accumulator + footer + "\n\n✅ <b>Ответ завершен.</b>"
                    finalMarkup = InlineKeyboardMarkup(inline_keyboard: [])
                }

                try? await TelegramAPI.editTelegramMessage(
                    telegramUrl: telegramUrl,
                    chat_id: chatID,
                    message_id: placeholder.message_id,
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
    
}
