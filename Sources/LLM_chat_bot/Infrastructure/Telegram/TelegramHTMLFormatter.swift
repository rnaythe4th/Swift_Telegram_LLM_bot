import Foundation

/// Sanitizer for everything the bot sends: keeps the tags Telegram renders,
/// escapes the rest, and closes whatever the model left open.
///
/// Three stages, one per file:
/// 1. `tokenize` (+Tokenizer) — reading. Where does a tag end, is this `<` a
///    tag at all, is this `&…;` an entity.
/// 2. `sanitize` (+Sanitizer) — policy. Does this tag survive, with which
///    attributes.
/// 3. `render` (below) — assembly. Keeps the tag stack, so a close tag matches
///    its open one and nothing is left hanging at the end.
///
/// It used to be one 375-line function holding all three at once, which is why
/// a bounds bug in the reader (a message ending in "<" crashed the process)
/// could sit in the middle of the attribute policy unnoticed.
///
/// The allow-list is mirrored by `MessageSplitter.renderedTags`, which decides
/// which tags are worth re-opening at the head of a continuation message; keep
/// the two in step when adding a tag.
struct TelegramHTMLFormatter {
    /// Schemes a link may point at. Everything the bot sends carries the bot's
    /// authority, and the text of an `<a>` is free-form — so an unrestricted
    /// `href` turns any string the bot echoes (a model answer, a display name)
    /// into a clickable link the reader has no reason to distrust.
    /// `javascript:` and `data:` are refused outright; anything unrecognised is
    /// dropped rather than guessed at.
    private static let allowedURLSchemes: Set<String> = [
        "http", "https", "tg", "mailto", "tel"
    ]

    /// Escapes a value for use inside a double-quoted HTML attribute.
    ///
    /// `"` matters as much as `<`: without it a value like `x" onclick="y`
    /// closes the attribute and injects a second one. Telegram then rejects the
    /// whole message ("can't parse entities") and the answer never arrives —
    /// one crafted string is enough to silence a reply.
    static func escapeAttributeValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// True when a URL is safe to hand to a Telegram client. A value with no
    /// scheme at all is relative and harmless; a value with one must name a
    /// scheme we recognise.
    static func isAllowedURL(_ raw: String) -> Bool {
        // Control characters and whitespace inside a URL exist only to smuggle a
        // scheme past a naive check (`java\nscript:`).
        let stripped = raw.unicodeScalars
            .filter { !$0.properties.isWhitespace && $0.value > 0x20 && $0.value != 0x7F }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
        guard !stripped.isEmpty else { return false }
        guard let colon = stripped.firstIndex(of: ":") else {
            // No scheme: a relative link or a bare domain. Reject a leading
            // `//` (protocol-relative — it inherits whatever the client uses).
            return !stripped.hasPrefix("//")
        }
        // A `:` that appears after a `/`, `?` or `#` belongs to the path, not to
        // a scheme (`/a:b`), so there is no scheme to validate.
        let scheme = stripped[stripped.startIndex..<colon].lowercased()
        if scheme.contains("/") || scheme.contains("?") || scheme.contains("#") {
            return true
        }
        return allowedURLSchemes.contains(scheme)
    }

    /// Takes HTML-ish text and returns a string containing only the tags
    /// Telegram supports, with everything else escaped.
    static func helper(text: String) -> String {
        render(tokenize(text))
    }

    // MARK: - Stage 3: assembly

    /// Walks the token stream keeping the stack of open tags.
    ///
    /// The stack holds tags that were *not* allowed too. It has to: a dropped
    /// `<div>` still gets a `</div>` later, and without the placeholder that
    /// close would pop — and close — the `<b>` around it instead.
    private static func render(_ tokens: [Token]) -> String {
        var result = ""
        var stack: [(tag: String, allowed: Bool)] = []

        for token in tokens {
            switch token {
            case .chunk(let text):
                result += text

            case .close(let name):
                guard !stack.isEmpty else { continue }
                let (openTag, wasAllowed) = stack.removeLast()
                // A close tag that does not match what is open is the model
                // crossing its tags (`<b><i></b></i>`). Dropping it beats
                // emitting markup Telegram will reject outright.
                if name == openTag, wasAllowed {
                    result += "</\(name)>"
                }

            case .open(let name, let attributes, let selfClosing):
                // `<br>` is not in the allow-list but carries meaning: it is
                // the newline the model was trying to write.
                if name == "br", allowedTags[name] == nil {
                    result += "\n"
                    continue
                }
                let insidePre = stack.contains { $0.tag == "pre" && $0.allowed }
                let rendered = sanitize(
                    openTag: name,
                    attributes: attributes,
                    selfClosing: selfClosing,
                    insidePre: insidePre
                )
                if !selfClosing {
                    stack.append((tag: name, allowed: rendered != nil))
                }
                if let rendered {
                    result += rendered
                }
            }
        }

        // Close what the model left open, so the message is valid markup.
        while let (openTag, wasAllowed) = stack.popLast() {
            if wasAllowed { result += "</\(openTag)>" }
        }
        return result
    }
}
