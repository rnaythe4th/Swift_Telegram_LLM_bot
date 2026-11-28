import Foundation

enum InboundMediaKind: Sendable, Equatable {
    case image
    case audio
    case video
    case document
    
    var displayName: String {
        switch self {
        case .image:
            return "изображения"
        case .audio:
            return "голосовое сообщение"
        case .video:
            return "видео"
        case .document:
            return "документы"
        }
    }
}

enum InboundMediaRef: Codable, Sendable {
    case photo(fileID: String)
    case voice(fileID: String, mimeType: String?)
    case video(fileID: String, mimeType: String?)
    case document(fileID: String, fileName: String?, fileSize: Int?)
    
    var kind: InboundMediaKind {
        switch self {
        case .photo:
            return .image
        case .voice:
            return .audio
        case .video:
            return .video
        case .document:
            return .document
        }
    }
}

enum ResolvedMedia: Sendable {
    case imageDataURL(String)
    case audioBase64(data: String, format: String)
    case videoBase64(data: String, format: String)
}
