import Foundation

// Stage 1 of the sanitizer: reading. Turns a string into a flat token stream
// and decides nothing about policy — which tags are allowed, which attributes
// survive and what stays open is stage 2's problem.
//
// Everything here is about the *shape* of the input: where a tag ends, whether
// `<` starts one at all, which `&…;` is a real entity. That is also where the
// input is hostile: a model emits half-written tags, unbalanced quotes and
// stray angle brackets constantly.

extension TelegramHTMLFormatter {

    enum Token: Equatable {
        /// Characters to append to the output verbatim. Already escaped where
        /// escaping was needed, so the renderer never has to look inside.
        case chunk(String)
        case open(name: String, attributes: String, selfClosing: Bool)
        case close(name: String)
    }

    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var plain = ""
        var i = text.startIndex

        /// Ordinary characters are buffered so the renderer appends runs rather
        /// than one character at a time.
        func flush() {
            guard !plain.isEmpty else { return }
            tokens.append(.chunk(plain))
            plain = ""
        }
        func emit(_ token: Token) {
            flush()
            tokens.append(token)
        }

        /// Character after `idx`, or nil at the end of the string. The bound to
        /// check is the *next* index, not this one: with `idx` on the last
        /// character `index(after:)` is `endIndex`, and reading it traps. A
        /// message ending in "<" — a truncated code block is enough — used to
        /// crash the process instead of escaping the character.
        func nextChar(after idx: String.Index) -> Character? {
            let next = text.index(after: idx)
            return next < text.endIndex ? text[next] : nil
        }

        while i < text.endIndex {
            let ch = text[i]

            if ch == "<" {
                guard let nextCh = nextChar(after: i) else {
                    plain.append("&lt;")
                    i = text.index(after: i)
                    continue
                }
                // `<!-- … -->`, `<!DOCTYPE …>`, `<?xml …?>` — dropped whole.
                // Without a closing ">" there is no construct, only a literal.
                if nextCh == "!" || nextCh == "?" {
                    if let endIdx = text[i...].firstIndex(of: ">") {
                        i = text.index(after: endIdx)
                    } else {
                        plain.append("&lt;")
                        i = text.index(after: i)
                    }
                    continue
                }
                if nextCh == "/" {
                    guard let endIdx = text[i...].firstIndex(of: ">") else {
                        plain.append("&lt;")
                        i = text.index(after: i)
                        continue
                    }
                    let tagContent = text[text.index(i, offsetBy: 2) ..< endIdx]
                    let tagName = tagContent.split(separator: " ", maxSplits: 1).first?.lowercased() ?? ""
                    emit(.close(name: tagName))
                    i = text.index(after: endIdx)
                    continue
                }
                // A tag name starts with a letter; "<3" and "< b" are text.
                guard nextCh.isLetter, let tagCloseIdx = text[i...].firstIndex(of: ">") else {
                    plain.append("&lt;")
                    i = text.index(after: i)
                    continue
                }

                var tagContent = String(text[text.index(after: i) ..< tagCloseIdx])
                let isSelfClosing = tagContent.hasSuffix("/")
                if isSelfClosing {
                    tagContent = String(tagContent.dropLast().trimmingCharacters(in: .whitespacesAndNewlines))
                }
                let parts = tagContent.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                let tagName = parts.first?.lowercased() ?? ""
                let attrString = parts.count > 1 ? String(parts[1]) : ""

                // `<script>`/`<style>` are dropped *with their contents*: their
                // body is code, and escaping it would print the code instead.
                if tagName == "script" || tagName == "style" {
                    if let range = text[tagCloseIdx...].range(of: "</\(tagName)>", options: .caseInsensitive) {
                        i = range.upperBound
                    } else {
                        i = text.index(after: tagCloseIdx)
                    }
                    continue
                }

                emit(.open(name: tagName, attributes: attrString, selfClosing: isSelfClosing))
                i = text.index(after: tagCloseIdx)
                continue
            }

            if ch == "&" {
                if let entity = entity(in: text, at: i) {
                    plain.append(entity)
                    i = text.index(i, offsetBy: entity.count)
                    continue
                }
                plain.append("&amp;")
                i = text.index(after: i)
                continue
            }

            if ch == ">" {
                plain.append("&gt;")
                i = text.index(after: i)
                continue
            }

            plain.append(ch)
            i = text.index(after: i)
        }

        flush()
        return tokens
    }

    /// The `&…;` starting at `start`, if it is one Telegram accepts: the four
    /// named entities it knows plus any numeric reference. Anything else is a
    /// literal ampersand and gets escaped by the caller.
    private static func entity(in text: String, at start: String.Index) -> String? {
        guard let semiIdx = text[text.index(after: start)...].firstIndex(of: ";") else { return nil }
        let entity = String(text[start...semiIdx])
        if entity == "&lt;" || entity == "&gt;" || entity == "&amp;" || entity == "&quot;" {
            return entity
        }
        guard entity.hasPrefix("&#") else { return nil }
        let numString = entity.dropFirst(2).dropLast()
        if numString.first == "x" || numString.first == "X" {
            let hexPart = numString.dropFirst()
            return !hexPart.isEmpty && hexPart.allSatisfy(\.isHexDigit) ? entity : nil
        }
        return !numString.isEmpty && numString.allSatisfy(\.isNumber) ? entity : nil
    }
}
