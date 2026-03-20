import Foundation

enum TelegramMediaResolverError: LocalizedError {
    case missingFilePath(String)

    var errorDescription: String? {
        switch self {
        case .missingFilePath(let fileID):
            return "Telegram returned nil file_path for file_id=\(fileID)"
        }
    }
}

final class TelegramMediaResolver: MediaResolverPort, @unchecked Sendable {
    private let telegram: TelegramGatewayPort

    init(telegram: TelegramGatewayPort) {
        self.telegram = telegram
    }

    func resolveMedia(_ refs: [InboundMediaRef]) async throws -> [ResolvedMedia] {
        if refs.isEmpty { return [] }

        return try await withThrowingTaskGroup(of: (Int, ResolvedMedia).self) { group in
            for (index, ref) in refs.enumerated() {
                group.addTask {
                    (index, try await self.resolveMedia(ref))
                }
            }

            var resolved = Array<ResolvedMedia?>(repeating: nil, count: refs.count)

            do {
                for try await (index, media) in group {
                    resolved[index] = media
                }
            } catch {
                group.cancelAll()
                throw error
            }

            return resolved.compactMap { $0 }
        }
    }

    private func resolvePath(fileID: String) async throws -> String {
        let file = try await telegram.getFile(fileID: fileID)
        guard let filePath = file.file_path else {
            throw TelegramMediaResolverError.missingFilePath(fileID)
        }
        return filePath
    }

    private func resolveMedia(_ ref: InboundMediaRef) async throws -> ResolvedMedia {
        switch ref {
        case .photo(let fileID):
            let path = try await resolvePath(fileID: fileID)
            let data = try await telegram.downloadFile(filePath: path)
            return .imageDataURL("data:image/jpeg;base64,\(data.base64EncodedString())")

        case .voice(let fileID, _):
            let path = try await resolvePath(fileID: fileID)
            let data = try await telegram.downloadFile(filePath: path)
            return .audioBase64(data: data.base64EncodedString(), format: "ogg")

        case .video(let fileID, let mimeType):
            let path = try await resolvePath(fileID: fileID)
            let data = try await telegram.downloadFile(filePath: path)
            let format = mimeType?.split(separator: "/").last.map(String.init) ?? "mp4"
            return .videoBase64(data: data.base64EncodedString(), format: format)
        }
    }
}
