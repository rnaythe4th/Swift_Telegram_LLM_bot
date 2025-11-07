import Foundation

// любой ответ от телеграма
struct TelegramResponse<T: Decodable>: Decodable {
    let ok: Bool
    let result: T
    let description: String?
    let error_code: Int?
}

// обновления, которые возвращает сервер тг
struct TelegramUpdate: Codable {
    let update_id: Int
    let message: TelegramMessage?
}

// сообщение в телеграме
struct TelegramMessage: Codable {
    let message_id: Int
    let from: TelegramUser?
    let chat: TelegramChat
    let date: Int
    let text: String?
    let message_thread_id: Int64?
}

struct TelegramUser: Codable {
    let id: Int
    let is_bot: Bool
    let first_name: String
    let username: String?
}

struct TelegramChat: Codable {
    let id: Int
    let type: String
}

// для ответа на сообщение с идентификатором message_id
struct ReplyParameters: Codable {
    let message_id: Int
}

// тело запроса при отправке тг сообщения
struct TelegramSendMessageBody: Codable {
    let chat_id: Int
    let text: String
    let reply_parameters: ReplyParameters?
    let message_thread_id: Int64?
    let parse_mode: String?
}

// тело запроса при редактировании тг сообщения
struct TelegramEditMessageTextBody: Codable {
    let chat_id: Int
    let message_id: Int
    let text: String
    let parse_mode: String?
}

// тут пошло для дипсика
// сообщение в чате (в истории)
struct ChatMessage: Codable {
    let role: String
    let content: String
    var name: String? = nil
}
// тело запроса при отправке промпта
struct Prompt: Codable {
    // чтобы приходила статистика по токенам
    struct StreamOptions: Codable {
        let include_usage: Bool
    }
    
    let model: String
    let messages: [ChatMessage]
    let stream: Bool
    let temperature: Float
    let stream_options: StreamOptions?
    
    // требуется, т.к. изменен инициализатор (наверное, надо глянуть потом)
    enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature, stream_options
    }
    
    init(model: String, messages: [ChatMessage], stream: Bool, temperature: Float, showStats: Bool) {
        self.model = model
        self.messages = messages
        self.stream = stream
        self.temperature = temperature
        // если stream = true, то будем использовать, а если false, то будет nil (не используем)
        if stream {
            self.stream_options = showStats ? StreamOptions(include_usage: true) : nil
        } else {
            self.stream_options = nil
        }
    }
}

// для ответа без стрима
struct DSChoice: Codable {
    struct DSMessage: Codable {
        let role: String
        let content: String
    }
    let message: DSMessage
}
// ответ без стрима
struct DSChatResponse: Codable {
    let choices: [DSChoice]
}
// для ответа со стримом
struct Choice: Decodable {
    struct Delta: Decodable {
        let role: String?
        let content: String?
    }
    let index: Int?
    let delta: Delta?
    let finish_reason: String?
}
// чанки, которые приходят при включенном стриме
struct StreamChunk: Decodable {
    let choices: [Choice]
    let usage: Usage?
}

// объект с инфой об использованных токенах
struct Usage: Decodable {
    struct CompletionTokenDetails: Decodable {
        let reasoning_tokens: Int
    }
    
    let completion_tokens: Int
    let prompt_tokens: Int
    let prompt_cache_hit_tokens: Int
    let prompt_cache_miss_tokens: Int
    let total_tokens: Int
    let completion_details: CompletionTokenDetails?
}
