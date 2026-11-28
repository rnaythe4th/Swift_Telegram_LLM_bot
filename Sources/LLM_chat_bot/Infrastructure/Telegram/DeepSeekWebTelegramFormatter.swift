import Foundation

/// Converts DeepSeek Web's Telegram HTML and code fences into Bot API entities.
/// Entity offsets and lengths refer to the visible text, in UTF-16 code units.
enum DeepSeekWebTelegramFormatter {
    struct Part: Equatable, Sendable {
        let text: String
        var entities: [TelegramTextEntity] = []
    }

    private struct Style {
        let type: String
        var url: String? = nil
        var language: String? = nil
        var emojiID: String? = nil

        var isInlineStyle: Bool {
            ["bold", "italic", "underline", "strikethrough", "spoiler"].contains(type)
        }

        var isCode: Bool { type == "code" || type == "pre" }
    }

    private struct Tag {
        let name: String
        let start: Int
        var style: Style?
    }

    private struct Span {
        let style: Style
        let range: Range<Int>
    }

    private static let types = [
        "b": "bold", "strong": "bold", "i": "italic", "em": "italic",
        "u": "underline", "ins": "underline", "s": "strikethrough", "strike": "strikethrough",
        "del": "strikethrough", "span": "spoiler", "tg-spoiler": "spoiler",
        "a": "text_link", "code": "code", "pre": "pre", "blockquote": "blockquote",
        "tg-emoji": "custom_emoji",
    ]

    private static let reference = #"&(?:amp|lt|gt|quot|#[0-9]{1,8}|#[xX][0-9A-Fa-f]{1,6});"#
    private static let references = try! NSRegularExpression(pattern: reference)
    // Fences and inline code take precedence over tags and entities inside them.
    private static let tokens = try! NSRegularExpression(pattern: #"""
    (?m:^[ \t]{0,3}(?<fence>`{3,}|~{3,})(?<lang>[^\r\n]*)\r?\n(?<block>[\s\S]*?)(?:^[ \t]{0,3}\k<fence>`*~*[ \t]*(?=\r?$)|\z))
    |(?<!`)(?<ticks>`+)(?!`)(?<inline>[^`\r\n]+)\k<ticks>(?!`)
    |<(?<close>/)?(?<tag>\#(types.keys.sorted().joined(separator: "|"))|br)(?<attrs>(?:\s(?:[^<>"']|"[^"]*"|'[^']*')*)?)/?>
    |\#(reference)
    """#.replacingOccurrences(of: "\n|", with: "|"), options: [.caseInsensitive])

    static func parts(_ source: String) -> [Part] {
        var text = ""
        var offset = 0
        var tags: [Tag] = []
        var spans: [Span] = []
        var cursor = source.startIndex

        func append(_ value: String) {
            text += value
            offset += value.utf16.count
        }
        func finish(_ tag: Tag) {
            if let style = tag.style, tag.start < offset {
                spans.append(Span(style: style, range: tag.start..<offset))
            }
        }

        for match in tokens.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let range = Range(match.range, in: source) else { continue }
            func group(_ name: String) -> String? {
                Range(match.range(withName: name), in: source).map { String(source[$0]) }
            }
            append(String(source[cursor..<range.lowerBound]))
            cursor = range.upperBound
            let token = String(source[range])
            let name = group("tag")?.lowercased()
            let closing = group("close") != nil

            if token.hasPrefix("&") {
                append(decodedReference(token))
            } else if let protected = tags.last, protected.name == "code" || protected.name == "pre" {
                if closing, let name,
                   name == protected.name || (name == "pre" && tags.dropLast().last?.name == "pre") {
                    if name != protected.name { finish(tags.removeLast()) }
                    finish(tags.removeLast())
                } else if protected.name == "pre", name == "code", !closing, protected.start == offset {
                    tags[tags.count - 1].style?.language = codeLanguage(group("attrs") ?? "")
                    tags.append(Tag(name: "code", start: offset, style: nil))
                } else {
                    append(token)
                }
            } else if let block = group("block") ?? group("inline") {
                let style = group("block") == nil
                    ? Style(type: "code")
                    : Style(type: "pre", language: language(group("lang") ?? ""))
                let tag = Tag(name: style.type, start: offset, style: permitted(style, inside: tags))
                append(block)
                finish(tag)
            } else if let name {
                if name == "br" {
                    if !closing { append("\n") }
                } else if closing {
                    if let index = tags.lastIndex(where: { $0.name == name }) {
                        while tags.count > index { finish(tags.removeLast()) }
                    }
                } else if !token.hasSuffix("/>") {
                    let style = style(for: name, attributes: group("attrs") ?? "")
                        .flatMap { permitted($0, inside: tags) }
                    tags.append(Tag(name: name, start: offset, style: style))
                }
            }
        }
        append(String(source[cursor...]))
        while let tag = tags.popLast() { finish(tag) }

        // Whitespace-only markup still has a readable fallback for a generated answer.
        guard text.contains(where: { !$0.isWhitespace }) else { return plainParts(source) }
        var start = 0
        return plainParts(text).compactMap { part -> Part? in
            let end = start + part.text.utf16.count
            defer { start = end }
            guard part.text.contains(where: { !$0.isWhitespace }) else { return nil }
            let entities = spans.compactMap { span -> TelegramTextEntity? in
                let lower = max(span.range.lowerBound, start)
                let upper = min(span.range.upperBound, end)
                guard lower < upper else { return nil }
                if span.style.emojiID != nil, lower != span.range.lowerBound || upper != span.range.upperBound {
                    return nil
                }
                return TelegramTextEntity(
                    type: span.style.type, offset: lower - start, length: upper - lower,
                    url: span.style.url, language: span.style.language, customEmojiID: span.style.emojiID
                )
            }.sorted { ($0.offset, -$0.length, $0.type) < ($1.offset, -$1.length, $1.type) }
            return Part(text: part.text, entities: entities)
        }
    }

    /// Also used for deliveries that started before entity formatting was enabled.
    static func plainParts(_ text: String) -> [Part] {
        var parts: [Part] = []
        var part = ""
        var units = 0
        for scalar in text.unicodeScalars {
            let width = scalar.value > 0xFFFF ? 2 : 1
            if units + width > MessageSplitter.telegramMaxChars {
                parts.append(Part(text: part))
                part = ""
                units = 0
            }
            part.unicodeScalars.append(scalar)
            units += width
        }
        if !part.isEmpty { parts.append(Part(text: part)) }
        return parts
    }

    private static func permitted(_ style: Style, inside tags: [Tag]) -> Style? {
        for parent in tags.compactMap(\.style) {
            if parent.type == style.type || parent.isCode || style.isCode { return nil }
            if !parent.isInlineStyle && !style.isInlineStyle { return nil }
        }
        return style
    }

    private static func style(for name: String, attributes raw: String) -> Style? {
        guard let type = types[name] else { return nil }
        switch name {
        case "a":
            guard let value = attribute("href", in: raw).map(decodeReferences),
                  TelegramHTMLFormatter.isAllowedURL(value),
                  let url = URLComponents(string: value), let scheme = url.scheme?.lowercased(),
                  (scheme != "http" && scheme != "https") || url.host?.isEmpty == false
            else { return nil }
            return Style(type: type, url: value)
        case "span":
            return attribute("class", in: raw) == "tg-spoiler" ? Style(type: type) : nil
        case "blockquote":
            let expandable = TelegramHTMLFormatter.parseAttributes(raw).contains { $0.name == "expandable" }
            return Style(type: expandable ? "expandable_blockquote" : type)
        case "tg-emoji":
            guard let value = attribute("emoji-id", in: raw), let id = Int64(value), id > 0 else { return nil }
            return Style(type: type, emojiID: String(id))
        default:
            return Style(type: type)
        }
    }

    private static func attribute(_ name: String, in raw: String) -> String? {
        TelegramHTMLFormatter.parseAttributes(raw).first { $0.name == name }?.value
    }

    private static func codeLanguage(_ raw: String) -> String? {
        guard let value = attribute("class", in: raw), value.hasPrefix("language-") else { return nil }
        return language(String(value.dropFirst("language-".count)))
    }

    private static func language(_ value: String) -> String? {
        guard let name = value.split(whereSeparator: \.isWhitespace).first,
              name.utf8.count <= 32, name.range(of: #"^[a-zA-Z0-9_+#.-]+$"#, options: .regularExpression) != nil
        else { return nil }
        return String(name)
    }

    private static func decodeReferences(_ raw: String) -> String {
        var result = ""
        var start = raw.startIndex
        for match in references.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
            guard let range = Range(match.range, in: raw) else { continue }
            result += raw[start..<range.lowerBound]
            result += decodedReference(String(raw[range]))
            start = range.upperBound
        }
        return result + raw[start...]
    }

    private static func decodedReference(_ token: String) -> String {
        switch token {
        case "&amp;": return "&"
        case "&lt;": return "<"
        case "&gt;": return ">"
        case "&quot;": return "\""
        default:
            let digits = token.dropFirst(2).dropLast()
            let hex = digits.first == "x" || digits.first == "X"
            guard let value = UInt32(hex ? digits.dropFirst() : digits, radix: hex ? 16 : 10),
                  value > 0, let scalar = Unicode.Scalar(value) else { return token }
            return String(scalar)
        }
    }
}
