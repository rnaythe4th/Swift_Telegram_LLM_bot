import Foundation

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
}

struct ChatMessageContentPart: Codable, Sendable {
    let type: String
    let text: String?
    let inputAudio: ChatMessageInputAudio?
    let inputImage: ChatMessageInputImage?
    let inputVideo: ChatMessageInputVideo?
    
    init(
        type: String,
        text: String? = nil,
        inputAudio: ChatMessageInputAudio? = nil,
        inputImage: ChatMessageInputImage? = nil,
        inputVideo: ChatMessageInputVideo? = nil
    ) {
        self.type = type
        self.text = text
        self.inputAudio = inputAudio
        self.inputImage = inputImage
        self.inputVideo = inputVideo
    }
    
    static func text(_ text: String) -> Self {
        .init(type: "text", text: text)
    }
    
    static func inputAudio(data: String, format: String) -> Self {
        .init(type: "input_audio", inputAudio: .init(data: data, format: format))
    }
    
    static func inputImage(dataURL: String) -> Self {
        .init(type: "image_url", inputImage: .init(url: dataURL))
    }
    
    static func inputVideo(data: String, format: String) -> Self {
        .init(type: "input_video", inputVideo: .init(data: data, format: format))
    }
    
    enum CodingKeys: String, CodingKey {
        case type
        case text
        case inputAudio = "input_audio"
        case inputImage = "image_url"
        case inputVideo = "input_video"
    }
}

struct ChatMessageInputAudio: Codable, Sendable {
    let data: String
    let format: String
}

struct ChatMessageInputImage: Codable, Sendable {
    let url: String
}

struct ChatMessageInputVideo: Codable, Sendable {
    let data: String
    let format: String
}

struct ChatMessage: Codable, Sendable {
    let role: String
    let content: ChatMessageContent
    var name: String?
    
    init(role: String, content: ChatMessageContent, name: String? = nil) {
        self.role = role
        self.content = content
        self.name = name
    }
    
    init(role: String, content: String, name: String? = nil) {
        self.init(role: role, content: .text(content), name: name)
    }
    
    static func userContent(_ input: UserInputContent, username: String?) -> ChatMessage {
        if input.attachments.isEmpty {
            return .init(role: "user", content: .text(input.text ?? ""), name: username)
        }
        
        var parts: [ChatMessageContentPart] = []
        if let text = input.text, !text.isEmpty {
            parts.append(.text(text))
        }
        
        for item in input.attachments {
            switch item {
            case .imageDataURL(let dataURL):
                parts.append(.inputImage(dataURL: dataURL))
            case .audioBase64(let data, let format):
                parts.append(.inputAudio(data: data, format: format))
            case .videoBase64(let data, let format):
                parts.append(.inputVideo(data: data, format: format))
            }
        }
        
        return .init(role: "user", content: .parts(parts), name: username)
    }

    /// What keeping this message costs, in the units both the wire and the
    /// `jsonb` column charge for. Used by the history budget
    /// (`ChatContext.historyByteBudget`); `utf8.count` is a stored property of
    /// a native string, so measuring the whole conversation stays cheap.
    var byteCount: Int {
        content.byteCount
    }
}

extension ChatMessageContent {
    var byteCount: Int {
        switch self {
        case .text(let text):
            return text.utf8.count
        case .parts(let parts):
            return parts.reduce(0) { $0 + $1.byteCount }
        }
    }
}

extension ChatMessageContentPart {
    /// Attachments never reach the history (the coordinator strips them before
    /// the turn is stored), but a part-shaped message can still arrive from a
    /// row written by an older build — and a base64 payload is exactly the size
    /// this budget exists to catch.
    var byteCount: Int {
        (text?.utf8.count ?? 0)
            + (inputAudio?.data.utf8.count ?? 0)
            + (inputImage?.url.utf8.count ?? 0)
            + (inputVideo?.data.utf8.count ?? 0)
    }
}
