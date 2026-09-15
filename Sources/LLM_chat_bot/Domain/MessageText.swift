import Foundation

/// Escaping for text a *person* typed that the bot later prints into a Telegram
/// message.
///
/// The rule it serves (CLAUDE.md §17): such text is stored raw — a preset value
/// is a model id or a role the model is given, a rail name is what the payer
/// should read — and it is escaped at the point where it turns into markup, not
/// on the way in. A button caption is not markup and takes the raw text.
///
/// One implementation rather than one per type: an unescaped `<` does not
/// corrupt a message, it makes Telegram reject the whole send, so the page or
/// the receipt simply never arrives.
enum MessageText {
    static func escaped(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
