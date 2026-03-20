import Foundation

struct MessageRoutingPolicy: Equatable {
    let shouldHandle: Bool
    let normalizedText: String?
    let isReplyToBot: Bool
    let mentionsBot: Bool
    
    // Group messages should start processing as soon as at least one trigger matches:
    // reply to the bot OR mention of the bot in text/caption. Private chats always pass through.
    static func evaluate(message: TelegramMessage, botUsername: String) -> MessageRoutingPolicy {
        let bodyText = trimmedBodyText(from: message)
        let isPrivateChat = message.chat.type == "private"
        let isReplyToBot = isReplyToBot(message, botUsername: botUsername)
        let mentionsBot = bodyText.map { containsBotMention(in: $0, botUsername: botUsername) } ?? false
        
        let normalizedText: String?
        if mentionsBot, let bodyText {
            normalizedText = sanitizeMention(in: bodyText, botUsername: botUsername)
        } else {
            normalizedText = bodyText
        }
        
        return MessageRoutingPolicy(
            shouldHandle: isPrivateChat || isReplyToBot || mentionsBot,
            normalizedText: normalizedText,
            isReplyToBot: isReplyToBot,
            mentionsBot: mentionsBot
        )
    }
    
    private static func trimmedBodyText(from message: TelegramMessage) -> String? {
        let rawText = message.text ?? message.caption
        guard let rawText else {
            return nil
        }
        
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    
    private static func isReplyToBot(_ message: TelegramMessage, botUsername: String) -> Bool {
        guard let username = message.reply_to_message?.from?.username else {
            return false
        }
        
        return username.caseInsensitiveCompare(botUsername) == .orderedSame
    }
    
    private static func containsBotMention(in text: String, botUsername: String) -> Bool {
        text.range(of: "@\(botUsername)", options: [.caseInsensitive]) != nil
    }
    
    private static func sanitizeMention(in text: String, botUsername: String) -> String? {
        let sanitized = text
            .replacingOccurrences(of: "@\(botUsername)", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        return sanitized.isEmpty ? nil : sanitized
    }
}
