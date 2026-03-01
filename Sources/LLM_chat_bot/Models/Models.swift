import Foundation

public struct StreamKey: Hashable, Codable, Sendable {
    public let chatID: Int
    public let threadID: Int64  // 0 = без треда (обычное сообщение)

    public init(chatID: Int, threadID: Int64) {
        self.chatID = chatID
        self.threadID = threadID
    }
}

struct TelegramError: Codable {
    let ok: Bool
    let error_code: Int?
    let description: String?
    let parameters: TelegramErrorParameters?
}

struct TelegramErrorParameters: Codable {
    let migrate_to_chat_id: Int64?
    let retry_after: Int?
}

// любой ответ от телеграма
struct TelegramResponse<T: Decodable>: Decodable {
    let ok: Bool
    let result: T?
    let description: String?
    let error_code: Int?
    let parameters: TelegramErrorParameters?
}

// обновления, которые возвращает сервер тг
struct TelegramUpdate: Codable {
    let update_id: Int
    let message: TelegramMessage?
    let callback_query: CallbackQuery?
}

// сообщение в телеграме
class TelegramMessage: Codable {
    let message_id: Int
    let from: TelegramUser?
    let chat: TelegramChat
    let date: Int
    let text: String?
    let audio: TelegramAudio?
    let voice: TelegramVoice?
    let message_thread_id: Int64?
    let reply_to_message: TelegramMessage?
}

struct TelegramVoice: Codable {
    let file_id: String
    let file_unique_id: String
    let duration: Int
    let mime_type: String?
    let file_size: Int?
}

struct TelegramAudio: Codable {
        let fileId: String
        let fileUniqueId: String
        let duration: Int
        let performer: String?
        let title: String?
        let fileName: String?
        let mimeType: String?
        let fileSize: Int?
        let thumbnail: PhotoSize?
}

struct PhotoSize: Codable {
        let fileId: String
        let fileUniqueId: String
        let width: Int
        let height: Int
        let fileSize: Int?
}

struct TelegramFile: Codable {
    let file_id: String
    let file_unique_id: String
    let file_size: Int?
    let file_path: String?
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
    let reply_markup: InlineKeyboardMarkup?
}

// тело запроса при редактировании тг сообщения
struct TelegramEditMessageTextBody: Codable {
    let chat_id: Int
    let message_id: Int
    let text: String
    let parse_mode: String?
    let reply_markup: InlineKeyboardMarkup? 
}

struct InlineKeyboardButton: Codable {
    let text: String
    let callback_data: String
}

struct InlineKeyboardMarkup: Codable {
    let inline_keyboard: [[InlineKeyboardButton]]
}

struct CallbackQuery: Codable {
    let id: String
    let from: TelegramUser
    let data: String?
    let message: MaybeInaccessibleMessage?
}

struct MaybeInaccessibleMessage: Codable {
    let chat: TelegramChat
    let message_id: Int
    let date: Int
    let text: String?
}

struct AnswerCallbackQueryBody: Codable {
    let callback_query_id: String
    let text: String?
    let show_alert: Bool?
}

// тут пошло для дипсика
enum ChatMessageContent: Codable, Sendable {
    case text(String)
    case parts([ChatMessageContentPart])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
            return
        }
        self = .parts(try container.decode([ChatMessageContentPart].self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text):
            try container.encode(text)
        case .parts(let parts):
            try container.encode(parts)
        }
    }

    static func audio(data: String, format: String) -> ChatMessageContent {
        .parts([.inputAudio(data: data, format: format)])
    }
}

struct ChatMessageContentPart: Codable, Sendable {
    let type: String
    let text: String?
    let inputAudio: ChatMessageInputAudio?

    init(type: String, text: String? = nil, inputAudio: ChatMessageInputAudio? = nil) {
        self.type = type
        self.text = text
        self.inputAudio = inputAudio
    }

    static func text(_ text: String) -> Self {
        .init(type: "text", text: text)
    }

    static func inputAudio(data: String, format: String) -> Self {
        .init(type: "input_audio", inputAudio: .init(data: data, format: format))
    }

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case inputAudio = "input_audio"
    }
}

struct ChatMessageInputAudio: Codable, Sendable {
    let data: String
    let format: String
}

// сообщение в чате (в истории)
struct ChatMessage: Codable, Sendable {
    let role: String
    let content: ChatMessageContent
    var name: String? = nil

    init(role: String, content: ChatMessageContent, name: String? = nil) {
        self.role = role
        self.content = content
        self.name = name
    }

    init(role: String, content: String, name: String? = nil) {
        self.init(role: role, content: .text(content), name: name)
    }

    init(role: String, audioBase64: String, audioFormat: String, name: String? = nil) {
        self.init(role: role, content: .audio(data: audioBase64, format: audioFormat), name: name)
    }
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

enum ContentToProcess {
    case voice(base64: String, format: String)
    case text(String)
}
