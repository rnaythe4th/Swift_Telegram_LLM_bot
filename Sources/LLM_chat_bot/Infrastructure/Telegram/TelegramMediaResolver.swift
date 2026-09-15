import Foundation

enum TelegramMediaResolverError: LocalizedError {
    case missingFilePath(String)
    /// One turn asked for more bytes than a turn is allowed to download.
    case attachmentsTooHeavy(limitBytes: Int)

    var errorDescription: String? {
        switch self {
        case .missingFilePath(let fileID):
            return "Telegram returned nil file_path for file_id=\(fileID)"
        case .attachmentsTooHeavy(let limitBytes):
            return "Attachments exceed the \(limitBytes)-byte budget for one turn"
        }
    }
}

final class TelegramMediaResolver: MediaResolverPort, Sendable {
    private let telegram: TelegramGatewayPort

    /// Everything one turn may pull out of Telegram, in bytes.
    ///
    /// Every file is read into memory whole, base64-encoded (×4/3) and copied
    /// again into the provider request, so the peak is several times what is
    /// downloaded. Telegram's own ceiling is *per file* (20 MiB) and bounds a
    /// single photo, nothing else: an album delivers up to sixteen of them at
    /// once, and media is resolved **before** `GenerationLimiter` has any say
    /// (the provider's capabilities decide whether the turn can run at all), so
    /// nothing else in the pipeline caps the total either.
    static let turnByteBudget = 20 << 20

    init(telegram: TelegramGatewayPort) {
        self.telegram = telegram
    }

    func resolveMedia(_ refs: [InboundMediaRef]) async throws -> [ResolvedMedia] {
        if refs.isEmpty { return [] }
        let budget = DownloadBudget(bytes: Self.turnByteBudget)

        return try await withThrowingTaskGroup(of: (Int, ResolvedMedia).self) { group in
            for (index, ref) in refs.enumerated() {
                group.addTask {
                    (index, try await self.resolveMedia(ref, budget: budget))
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

    /// Bytes the current turn may still download, shared by the parallel
    /// downloads. A budget checked after the fact is a budget every one of them
    /// passes, so the size is claimed before the file is fetched.
    private final class DownloadBudget: Sendable {
        private let remaining: LockedValue<Int>

        init(bytes: Int) {
            remaining = LockedValue(bytes)
        }

        func take(_ bytes: Int) -> Bool {
            remaining.withLock { left in
                guard bytes <= left else { return false }
                left -= bytes
                return true
            }
        }
    }

    private func download(fileID: String, budget: DownloadBudget) async throws -> Data {
        let file = try await telegram.getFile(fileID: fileID)
        guard let filePath = file.file_path else {
            throw TelegramMediaResolverError.missingFilePath(fileID)
        }
        let declared = max(0, file.file_size ?? 0)
        guard budget.take(declared) else {
            throw TelegramMediaResolverError.attachmentsTooHeavy(limitBytes: Self.turnByteBudget)
        }
        let data = try await telegram.downloadFile(filePath: filePath)
        // `file_size` is optional in the Bot API and advisory when present; the
        // bytes that actually arrived are neither, so the difference is settled
        // against the same budget.
        guard budget.take(max(0, data.count - declared)) else {
            throw TelegramMediaResolverError.attachmentsTooHeavy(limitBytes: Self.turnByteBudget)
        }
        return data
    }

    private func resolveMedia(_ ref: InboundMediaRef, budget: DownloadBudget) async throws -> ResolvedMedia {
        switch ref {
        case .photo(let fileID):
            let data = try await download(fileID: fileID, budget: budget)
            return .imageDataURL("data:image/jpeg;base64,\(data.base64EncodedString())")

        case .voice(let fileID, _):
            let data = try await download(fileID: fileID, budget: budget)
            return .audioBase64(data: data.base64EncodedString(), format: "ogg")

        case .video(let fileID, let mimeType):
            let data = try await download(fileID: fileID, budget: budget)
            let format = mimeType?.split(separator: "/").last.map(String.init) ?? "mp4"
            return .videoBase64(data: data.base64EncodedString(), format: format)
        }
    }
}
