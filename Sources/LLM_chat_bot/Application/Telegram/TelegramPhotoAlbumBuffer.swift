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
        /// When this album started collecting. `lastSeenAt` slides forward with
        /// every new part, so it alone cannot bound how long an album is held.
        var firstSeenAt: Date

        var orderedUpdates: [TelegramUpdate] {
            updatesByMessageID.values.sorted { $0.update_id < $1.update_id }
        }
    }

    // Everything here is memory held on behalf of whoever is sending, so all of
    // it is bounded. Without these caps a client that keeps posting parts under
    // one `media_group_id` holds its album open indefinitely (each part pushes
    // `lastSeenAt` forward) and every other message in that chat piles up behind
    // it in `blockedUpdates` — an out-of-memory kill reachable from a phone.

    /// Telegram itself caps an album at 10 items; the slack is for redelivery.
    private static let maxPartsPerAlbum = 16
    /// Hard ceiling on how long one album may hold its chat, however many parts
    /// keep arriving. Well past the holdback, short enough to bound the queue.
    private static let maxAlbumLifetime: TimeInterval = 10
    /// Updates that may queue behind a chat's pending albums before we give up
    /// on ordering and let them through.
    private static let maxBlockedUpdatesPerChat = 64
    /// Albums held across all chats at once. Past this the oldest are released
    /// early rather than accumulating.
    private static let maxPendingAlbums = 256

    private let holdbackInterval: TimeInterval
    private var pendingAlbums: [AlbumKey: PendingAlbum] = [:]
    private var pendingAlbumCountsByChat: [ChatKey: Int] = [:]
    private var blockedUpdates: [ChatKey: [TelegramUpdate]] = [:]

    /// True while album parts (or updates blocked behind them) are held back
    /// and a future `ingest([])` tick is required to release them.
    var hasBufferedUpdates: Bool {
        !pendingAlbums.isEmpty || !blockedUpdates.isEmpty
    }
    
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
            
            // Ordering behind an album is a nicety; unbounded memory is not.
            // Past the cap the update goes straight through — slightly out of
            // order beats never answering at all.
            if hasPendingAlbums(in: chatKey),
               (blockedUpdates[chatKey]?.count ?? 0) < Self.maxBlockedUpdatesPerChat {
                blockedUpdates[chatKey, default: []].append(update)
            } else {
                released.append(update)
            }
        }

        released.append(contentsOf: releaseReadyAlbums(now: now))
        released.append(contentsOf: releaseOverflowAlbums())
        return released.sorted { $0.update_id < $1.update_id }
    }

    /// Releases the longest-waiting albums once too many are open at once, so a
    /// spray of distinct `media_group_id`s cannot grow the buffer without limit.
    private mutating func releaseOverflowAlbums() -> [TelegramUpdate] {
        guard pendingAlbums.count > Self.maxPendingAlbums else { return [] }
        let overflow = pendingAlbums.count - Self.maxPendingAlbums
        let oldest = pendingAlbums
            .sorted { $0.value.firstSeenAt < $1.value.firstSeenAt }
            .prefix(overflow)
            .map(\.key)
        var released: [TelegramUpdate] = []
        for key in oldest {
            guard let album = pendingAlbums.removeValue(forKey: key) else { continue }
            decrementPendingAlbumCount(in: key.chatKey)
            if let merged = Self.mergeAlbum(album.orderedUpdates) { released.append(merged) }
            if !hasPendingAlbums(in: key.chatKey) {
                released.append(contentsOf: blockedUpdates.removeValue(forKey: key.chatKey) ?? [])
            }
        }
        return released
    }
    
    /// Releases everything held back right now, holdback window or not.
    ///
    /// Used by graceful shutdown: these updates were already acknowledged to
    /// Telegram with a 200, so they will never be redelivered — dropping them
    /// loses the user's message without a trace. An album cut short here is
    /// still better than no album at all.
    mutating func flushAll() -> [TelegramUpdate] {
        var released: [TelegramUpdate] = []
        for (key, album) in pendingAlbums {
            pendingAlbums.removeValue(forKey: key)
            if let merged = Self.mergeAlbum(album.orderedUpdates) { released.append(merged) }
        }
        for updates in blockedUpdates.values { released.append(contentsOf: updates) }
        blockedUpdates.removeAll()
        pendingAlbumCountsByChat.removeAll()
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

        var album = pendingAlbums[key]
            ?? PendingAlbum(updatesByMessageID: [:], lastSeenAt: now, firstSeenAt: now)
        if let messageID = update.message?.message_id,
           album.updatesByMessageID[messageID] != nil || album.updatesByMessageID.count < Self.maxPartsPerAlbum {
            // Past the cap, extra parts are dropped rather than buffered: a real
            // album never has that many, and each one carries a photo we would
            // otherwise download and base64 into the model request.
            album.updatesByMessageID[messageID] = update
        }
        album.lastSeenAt = now
        pendingAlbums[key] = album
    }

    private mutating func releaseReadyAlbums(now: Date) -> [TelegramUpdate] {
        let threshold = now.addingTimeInterval(-holdbackInterval)
        let lifetimeThreshold = now.addingTimeInterval(-Self.maxAlbumLifetime)
        let readyKeys = pendingAlbums.compactMap { key, album -> AlbumKey? in
            // Quiet for a holdback, complete, or simply held too long — the last
            // one is what stops a steady drip of parts from pinning the chat.
            let quiet = album.lastSeenAt <= threshold
            let full = album.updatesByMessageID.count >= Self.maxPartsPerAlbum
            let expired = album.firstSeenAt <= lifetimeThreshold
            return (quiet || full || expired) ? key : nil
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
    
    private static func mergeAlbum(_ updates: [TelegramUpdate]) -> TelegramUpdate? {
        let sortedUpdates = updates.sorted { $0.update_id < $1.update_id }
        guard let firstUpdate = sortedUpdates.first,
              let firstMessage = firstUpdate.message else {
            return nil
        }
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
        
        return TelegramUpdate(update_id: firstUpdate.update_id, message: mergedMessage, callback_query: nil, pre_checkout_query: nil, my_chat_member: nil)
    }
}
