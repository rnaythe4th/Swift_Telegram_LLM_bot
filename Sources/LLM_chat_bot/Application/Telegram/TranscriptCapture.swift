import Foundation

// Turning a Telegram message into a line of transcript.
//
// Pure and separate from the router because the same mapping is needed in two
// places that must not drift: what goes into the buffer on the way in, and what
// the reply marker on a question says on the way out.

enum TranscriptCapture {
    /// Short tags standing in for what a message carried instead of words.
    /// Pictures are not stored — the ask is a *conversation* buffer, and a
    /// base64 image is three orders of magnitude larger than the sentence next
    /// to it — but "Аня прислала фото" is part of the conversation, and a
    /// transcript that silently skips it makes the next five messages
    /// unintelligible.
    private static let photoTag = "[фото]"
    private static let voiceTag = "[голосовое]"
    private static let videoTag = "[видео]"

    /// What this message contributes, or nil when there is nothing to overhear.
    ///
    /// A caption counts as text. A media message with no caption contributes
    /// only its tag, which is one short line and keeps the order honest.
    /// Service messages (a join, a pin, a migration) contribute nothing.
    static func overheardText(from message: TelegramMessage) -> String? {
        let body = (message.text ?? message.caption)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var tags: [String] = []
        if message.photo?.isEmpty == false || message.album_photos?.isEmpty == false {
            tags.append(photoTag)
        }
        if message.voice != nil { tags.append(voiceTag) }
        if message.video != nil { tags.append(videoTag) }

        var parts: [String] = []
        if let body, !body.isEmpty { parts.append(body) }
        parts.append(contentsOf: tags)

        let joined = parts.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    /// What this message was answering, when it was a reply.
    ///
    /// The quote is taken from the update rather than looked up in the buffer:
    /// Telegram hands us the whole replied-to message, and it is the only thing
    /// that still describes a target which has already scrolled out of the
    /// buffer (or was never in it — a message from before listening began).
    static func reply(from message: TelegramMessage, botUsername: String) -> TranscriptReply? {
        guard let target = message.reply_to_message else { return nil }

        let author: TranscriptAuthor?
        if let from = target.from {
            let isBot = from.is_bot
                && (from.username?.caseInsensitiveCompare(botUsername) == .orderedSame || botUsername.isEmpty)
            author = isBot ? .bot : .member(UserKey.identified(from.id))
        } else {
            author = nil
        }

        return TranscriptReply(
            messageID: target.message_id,
            author: author,
            quote: overheardText(from: target) ?? ""
        )
    }

    /// Whether a message is worth filing at all: a real person said something
    /// in a group. The bot's own messages are recorded where they are produced
    /// (with their id), not read back off the wire.
    static func author(of message: TelegramMessage) -> TranscriptAuthor? {
        guard let from = message.from, !from.is_bot else { return nil }
        return .member(UserKey.identified(from.id))
    }

    /// The moment Telegram says the message was sent, not the moment we got
    /// round to it: an update redelivered after an outage would otherwise
    /// timestamp an hour-old message as new.
    static func sentAt(_ message: TelegramMessage) -> Date {
        Date(timeIntervalSince1970: TimeInterval(message.date))
    }
}
