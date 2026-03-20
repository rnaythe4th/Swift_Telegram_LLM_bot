import Foundation

enum InboundMediaKind: Sendable, Equatable {
    case image
    case audio
    case video
    
    var displayName: String {
        switch self {
        case .image:
            return "изображения"
        case .audio:
            return "голосовое сообщение"
        case .video:
            return "видео"
        }
    }
}

enum InboundMediaRef: Sendable {
    case photo(fileID: String)
    case voice(fileID: String, mimeType: String?)
    case video(fileID: String, mimeType: String?)
    
    var kind: InboundMediaKind {
        switch self {
        case .photo:
            return .image
        case .voice:
            return .audio
        case .video:
            return .video
        }
    }
}

enum ResolvedMedia: Sendable {
    case imageDataURL(String)
    case audioBase64(data: String, format: String)
    case videoBase64(data: String, format: String)
}
