import Foundation

// Stage 2 of the sanitizer: policy. Given one tag as the tokenizer read it,
// decide whether it survives and in what form. Nothing here looks at the
// surrounding text — that is stage 3.

extension TelegramHTMLFormatter {

    /// Tags Telegram renders, and what each may carry.
    ///
    /// - `.none` — the tag takes no attributes.
    /// - `.any` — any value (only `href`, whose scheme is checked separately).
    /// - `.flag` — presence is the value (`<blockquote expandable>`).
    /// - `.language` — `class`, and only `language-…` (code highlighting).
    /// - `.oneOf` — an explicit list of accepted values.
    enum AttributeRule {
        case any
        case flag
        case language
        case oneOf([String])
    }

    static let allowedTags: [String: [String: AttributeRule]] = [
        "b": [:], "strong": [:],
        "i": [:], "em": [:],
        "u": [:], "ins": [:],
        "s": [:], "strike": [:], "del": [:],
        "span": ["class": .oneOf(["tg-spoiler"])],
        "tg-spoiler": [:],
        "a": ["href": .any],
        "code": ["class": .language],
        "pre": [:],
        "blockquote": ["expandable": .flag],
        "tg-emoji": ["emoji-id": .any],
    ]

    /// The opening tag to emit, or nil when the tag does not survive.
    ///
    /// `insidePre` is the one piece of context policy needs: a language class
    /// on `<code>` means nothing outside a `<pre>` block, so it is dropped
    /// there rather than passed to the client.
    static func sanitize(
        openTag name: String,
        attributes attrString: String,
        selfClosing: Bool,
        insidePre: Bool
    ) -> String? {
        guard let allowedAttrs = allowedTags[name] else { return nil }

        var outputAttrs: [String] = []
        for attr in parseAttributes(attrString) {
            guard let rule = allowedAttrs[attr.name] else { continue }
            switch rule {
            case .any:
                guard let value = attr.value else {
                    // A boolean attribute written without a value.
                    outputAttrs.append(attr.name)
                    continue
                }
                // `href` is the only attribute a client *acts* on, so its
                // scheme goes through the allow-list; an unrecognised one drops
                // the attribute, and with it (below) the whole tag.
                guard !(name == "a" && attr.name == "href") || isAllowedURL(value) else { continue }
                outputAttrs.append("\(attr.name)=\"\(escapeAttributeValue(value))\"")
            case .flag:
                outputAttrs.append(attr.name)
            case .language:
                guard let value = attr.value, value.starts(with: "language-") else { continue }
                outputAttrs.append("\(attr.name)=\"\(escapeAttributeValue(value))\"")
            case .oneOf(let values):
                guard let value = attr.value, values.contains(value) else { continue }
                outputAttrs.append("\(attr.name)=\"\(escapeAttributeValue(value))\"")
            }
        }

        // Tags that are meaningless without their attribute: a `<span>` is
        // only a spoiler, a link without a target is not a link, and a custom
        // emoji without an id has nothing to show.
        switch name {
        case "span":
            guard outputAttrs.contains(where: { $0.lowercased().hasPrefix("class=") && $0.lowercased().contains("tg-spoiler") })
            else { return nil }
        case "a":
            guard outputAttrs.contains(where: { $0.lowercased().hasPrefix("href=") }) else { return nil }
        case "tg-emoji":
            guard outputAttrs.contains(where: { $0.lowercased().hasPrefix("emoji-id=") }) else { return nil }
        case "code":
            if !insidePre {
                outputAttrs.removeAll { $0.lowercased().hasPrefix("class=") }
            }
        default:
            break
        }

        var tag = "<\(name)"
        if !outputAttrs.isEmpty {
            tag += " " + outputAttrs.joined(separator: " ")
        }
        tag += selfClosing ? " />" : ">"
        return tag
    }

    /// Splits an attribute string into name/value pairs.
    ///
    /// Hand-rolled rather than regex because every shape here is malformed
    /// somewhere: no value at all, `=` with spaces around it, an unquoted
    /// value, a quote that never closes. Each is read to the end of what is
    /// there rather than rejected — a half-written attribute should cost that
    /// attribute, not the message.
    static func parseAttributes(_ attrString: String) -> [(name: String, value: String?)] {
        var result: [(name: String, value: String?)] = []
        var j = attrString.startIndex

        while j < attrString.endIndex {
            if attrString[j].isWhitespace {
                j = attrString.index(after: j)
                continue
            }
            var k = j
            while k < attrString.endIndex, !attrString[k].isWhitespace, attrString[k] != "=" {
                k = attrString.index(after: k)
            }
            let name = attrString[j..<k].lowercased()
            while k < attrString.endIndex, attrString[k].isWhitespace {
                k = attrString.index(after: k)
            }

            var value: String?
            if k < attrString.endIndex, attrString[k] == "=" {
                k = attrString.index(after: k)
                while k < attrString.endIndex, attrString[k].isWhitespace {
                    k = attrString.index(after: k)
                }
                if k >= attrString.endIndex {
                    value = ""            // trailing `=` with nothing after it
                } else if attrString[k] == "\"" || attrString[k] == "'" {
                    let quote = attrString[k]
                    var q = attrString.index(after: k)
                    while q < attrString.endIndex, attrString[q] != quote {
                        q = attrString.index(after: q)
                    }
                    value = String(attrString[attrString.index(after: k) ..< min(q, attrString.endIndex)])
                    k = q < attrString.endIndex ? attrString.index(after: q) : attrString.endIndex
                } else {
                    var q = k
                    while q < attrString.endIndex, !attrString[q].isWhitespace {
                        q = attrString.index(after: q)
                    }
                    value = String(attrString[k..<q])
                    k = q
                }
            }

            result.append((name: name, value: value))
            j = k
        }
        return result
    }
}
