import Foundation

// telegram delivers photo albums as separate messages...
struct TelegramPhotoAlbumBuffer {
    private struct AlbumKey: Hashable {
        let chatKey: ChatKey
        let mediaGroupID: String
    }
    
    private struct PendingAlbum {
        var updatesByMessageID: [Int: TelegramUpdate]
        var lastSeenAt: Date
        
        var orderedUpdates: [TelegramUpdate] {
            updatesByMessageID.values.sorted { $0.update_id < $1.update_id }
        }
    }
    
    private let holdbackInterval: TimeInterval
    private var pendingAlbums: [AlbumKey: PendingAlbum] = [:]
    private var pendingAlbumCountsByChat: [ChatKey: Int] = [:]
    private var blockedUpdates: [ChatKey: [TelegramUpdate]] = [:]
    
    init(holdbackInterval: TimeInterval = 0.75) {
        self.holdbackInterval = holdbackInterval
    }
    
    mutating func ingest(_ updates: [TelegramUpdate], now: Date = Date()) -> [TelegramUpdate] {
        var released: [TelegramUpdate] = []
        
        for update in updates.sorted(by: { $0.update_id < $1.update_id }) {
            if let albumKey = photoAlbumKey(for: update) {
                bufferAlbumUpdate(update, for: albumKey, now: now)
                continue
            }
            
            guard let chatKey = chatKeyIfPresent(for: update.message) else {
                released.append(update)
                continue
            }
            
            if hasPendingAlbums(in: chatKey) {
                blockedUpdates[chatKey, default: []].append(update)
            } else {
                released.append(update)
            }
        }
        
        released.append(contentsOf: releaseReadyAlbums(now: now))
        return released.sorted { $0.update_id < $1.update_id }
    }
    
    static func selectPrimaryPhoto(from photos: [PhotoSize]) -> PhotoSize? {
        photos.max {
            let lhsSize = $0.file_size ?? ($0.width * $0.height)
            let rhsSize = $1.file_size ?? ($1.width * $1.height)
            return lhsSize < rhsSize
        }
    }
    
    private func photoAlbumKey(for update: TelegramUpdate) -> AlbumKey? {
        guard
            let message = update.message,
            let mediaGroupID = message.media_group_id,
            let photos = message.photo,
            !photos.isEmpty
        else {
            return nil
        }
        
        return AlbumKey(chatKey: chatKey(for: message), mediaGroupID: mediaGroupID)
    }
    
    private func chatKey(for message: TelegramMessage) -> ChatKey {
        ChatKey(chatID: message.chat.id, threadID: message.message_thread_id ?? 0)
    }
    
    private func chatKeyIfPresent(for message: TelegramMessage?) -> ChatKey? {
        guard let message else {
            return nil
        }
        
        return chatKey(for: message)
    }
    
    private func hasPendingAlbums(in chatKey: ChatKey) -> Bool {
        (pendingAlbumCountsByChat[chatKey] ?? 0) > 0
    }
    
    private mutating func bufferAlbumUpdate(_ update: TelegramUpdate, for key: AlbumKey, now: Date) {
        if pendingAlbums[key] == nil {
            pendingAlbumCountsByChat[key.chatKey, default: 0] += 1
        }
        
        var album = pendingAlbums[key] ?? PendingAlbum(updatesByMessageID: [:], lastSeenAt: now)
        if let messageID = update.message?.message_id {
            album.updatesByMessageID[messageID] = update
        }
        album.lastSeenAt = now
        pendingAlbums[key] = album
    }
    
    private mutating func releaseReadyAlbums(now: Date) -> [TelegramUpdate] {
        let threshold = now.addingTimeInterval(-holdbackInterval)
        let readyKeys = pendingAlbums.compactMap { key, album in
            album.lastSeenAt <= threshold ? key : nil
        }
        
        guard !readyKeys.isEmpty else {
            return []
        }
        
        let keysByChat = Dictionary(grouping: readyKeys, by: \.chatKey)
        var released: [TelegramUpdate] = []
        
        for (chatKey, chatAlbumKeys) in keysByChat {
            let mergedAlbums = chatAlbumKeys.compactMap { key -> TelegramUpdate? in
                guard let album = pendingAlbums.removeValue(forKey: key) else {
                    return nil
                }
                
                decrementPendingAlbumCount(in: chatKey)
                return Self.mergeAlbum(album.orderedUpdates)
            }
                .sorted { $0.update_id < $1.update_id }
            
            released.append(contentsOf: mergedAlbums)
            
            if !hasPendingAlbums(in: chatKey) {
                let blocked = (blockedUpdates.removeValue(forKey: chatKey) ?? [])
                    .sorted { $0.update_id < $1.update_id }
                released.append(contentsOf: blocked)
            }
        }
        
        return released
    }
    
    private mutating func decrementPendingAlbumCount(in chatKey: ChatKey) {
        guard let currentCount = pendingAlbumCountsByChat[chatKey] else {
            return
        }
        
        if currentCount <= 1 {
            pendingAlbumCountsByChat.removeValue(forKey: chatKey)
        } else {
            pendingAlbumCountsByChat[chatKey] = currentCount - 1
        }
    }
    
    private static func mergeAlbum(_ updates: [TelegramUpdate]) -> TelegramUpdate {
        let sortedUpdates = updates.sorted { $0.update_id < $1.update_id }
        let firstUpdate = sortedUpdates[0]
        let firstMessage = firstUpdate.message!
        let albumPhotos = sortedUpdates.compactMap { update in
            update.message?.photo.flatMap(selectPrimaryPhoto(from:))
        }
        
        let mergedMessage = TelegramMessage(
            message_id: firstMessage.message_id,
            from: firstMessage.from,
            chat: firstMessage.chat,
            date: firstMessage.date,
            text: firstMessage.text,
            caption: sortedUpdates.compactMap { update -> String? in
                guard let caption = update.message?.caption?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !caption.isEmpty else {
                    return nil
                }
                return caption
            }.first,
            voice: firstMessage.voice,
            video: firstMessage.video,
            message_thread_id: firstMessage.message_thread_id,
            media_group_id: firstMessage.media_group_id,
            // telegram can place reply metadata on any album item
            // the first non-nil reply across the whole media group
            reply_to_message: sortedUpdates.compactMap { $0.message?.reply_to_message }.first,
            photo: albumPhotos.isEmpty ? firstMessage.photo : albumPhotos,
            album_photos: albumPhotos
        )
        
        return TelegramUpdate(update_id: firstUpdate.update_id, message: mergedMessage, callback_query: nil)
    }
}
