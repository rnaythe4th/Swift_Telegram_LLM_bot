import Foundation

/// `application/x-www-form-urlencoded` in both directions.
///
/// Payment aggregators speak forms, not JSON: the checkout link is a query
/// string we sign, and the notification arrives as a form body (some vendors
/// put it in the query instead, which is why the caller merges both).
enum URLForm {
    /// Parses `a=1&b=hello+world` into a dictionary. Later keys win, blank
    /// names are dropped, and `+` decodes to a space — a callback amount that
    /// lost its decoding would fail the signature check for the wrong reason.
    static func parse(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in raw.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawName = parts.first else { continue }
            let name = decode(String(rawName))
            guard !name.isEmpty else { continue }
            result[name] = parts.count > 1 ? decode(String(parts[1])) : ""
        }
        return result
    }

    /// Builds a query string in the order given — signatures are computed over
    /// a fixed field order, so the caller's order is preserved rather than
    /// sorted behind its back.
    static func encode(_ items: [(name: String, value: String)]) -> String {
        items
            .map { "\(escape($0.name))=\(escape($0.value))" }
            .joined(separator: "&")
    }

    private static func decode(_ value: String) -> String {
        value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
            ?? value.replacingOccurrences(of: "+", with: " ")
    }

    /// Everything outside the unreserved set is escaped, `+` and `&` included:
    /// an order id or a method code that slipped a separator into the query
    /// would silently change which fields the vendor sees.
    private static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static let allowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
