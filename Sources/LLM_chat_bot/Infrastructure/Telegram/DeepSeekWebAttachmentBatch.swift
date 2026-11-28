import Foundation

/// Private staging shared with the loopback Firefox worker. Telegram file
/// IDs, rather than file bytes, are kept in the durable queue.
struct DeepSeekWebAttachmentBatch: Sendable {
    enum Failure: Error {
        case tooManyFiles
        case fileTooLarge
        case downloadFailed

        var message: String {
            switch self {
            case .tooManyFiles: return "Прикрепите до 10 файлов к одному запросу."
            case .fileTooLarge: return "Telegram позволяет боту скачать файлы размером до 20 МБ каждый."
            case .downloadFailed: return "Не удалось скачать все вложения из Telegram. Отправьте их ещё раз."
            }
        }
    }

    let id: UUID
    let names: [String]
    private let directory: URL
    private static let prefix = "llmchat-attachments-"
    private static let fileLimit = 20 << 20

    static func stage(
        _ refs: [InboundMediaRef], telegram: any TelegramGatewayPort
    ) async throws -> Self {
        guard refs.count <= 10 else { throw Failure.tooManyFiles }
        let id = UUID()
        let temporary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp", isDirectory: true)
        let files = FileManager.default
        // Reclaim staging from interrupted processes. A worker turn takes
        // at most minutes, and each live batch has its own random directory.
        if let entries = try? files.contentsOfDirectory(
            at: temporary, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]
        ) {
            for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
                guard UUID(uuidString: String(entry.lastPathComponent.dropFirst(prefix.count))) != nil,
                      let info = try? entry.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]),
                      info.isDirectory == true, let modified = info.contentModificationDate,
                      Date().timeIntervalSince(modified) > 3_600 else { continue }
                try? files.removeItem(at: entry)
            }
        }
        let directory = temporary.appendingPathComponent(prefix + id.uuidString.lowercased(), isDirectory: true)
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            var names: [String] = []
            for (index, ref) in refs.enumerated() {
                try Task.checkCancellation()
                let fileID: String
                let filename: String?
                switch ref {
                case .photo(let id):
                    fileID = id
                    filename = "photo-\(index + 1).jpg"
                case .document(let id, let name, let size):
                    guard (size ?? 0) <= fileLimit else { throw Failure.fileTooLarge }
                    fileID = id
                    filename = name
                case .voice, .video:
                    throw Failure.downloadFailed
                }

                let remote = try await telegram.getFile(fileID: fileID)
                guard let path = remote.file_path else { throw Failure.downloadFailed }
                guard (remote.file_size ?? 0) <= fileLimit else { throw Failure.fileTooLarge }
                let fallback = (path as NSString).lastPathComponent
                let name = safeName(filename, fallback: fallback, index: index)
                let slot = directory.appendingPathComponent(String(index), isDirectory: true)
                try files.createDirectory(at: slot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let data = try await telegram.downloadFile(filePath: path)
                guard data.count <= fileLimit else { throw Failure.fileTooLarge }
                guard !data.isEmpty else { throw Failure.downloadFailed }
                let target = slot.appendingPathComponent(name)
                try data.write(to: target, options: .withoutOverwriting)
                try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                names.append(name)
            }
            return Self(id: id, names: names, directory: directory)
        } catch {
            try? files.removeItem(at: directory)
            throw error
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func safeName(_ name: String?, fallback: String, index: Int) -> String {
        let invalid = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\"))
        let clean = (name ?? fallback).precomposedStringWithCanonicalMapping
            .components(separatedBy: invalid).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != ".", clean != ".." else { return "file-\(index + 1)" }
        guard clean.utf8.count > 200 else { return clean }
        let ext = (clean as NSString).pathExtension
        let suffix = ext.utf8.count <= 48 && !ext.isEmpty ? "." + ext : ""
        let stem = (clean as NSString).deletingPathExtension
        var clipped = ""
        for character in stem {
            guard clipped.utf8.count + String(character).utf8.count + suffix.utf8.count <= 200 else { break }
            clipped.append(character)
        }
        return (clipped.isEmpty ? "file-\(index + 1)" : clipped) + suffix
    }
}
