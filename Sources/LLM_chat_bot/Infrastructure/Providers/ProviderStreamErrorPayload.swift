import Foundation

/// An error an OpenAI-compatible provider delivers *inside* a 200 OK SSE stream
/// (`{"error":{"code":429,"message":"rate limited"}}`): rate limits, exhausted
/// credit, moderation blocks, "no endpoints found".
///
/// Without this the payload parses as neither usage nor delta, the stream ends
/// empty, and the user gets "Пустой ответ." — the actual reason reaching neither
/// them nor the logs.
struct ProviderStreamErrorPayload: Decodable {
    let code: Int?
    let message: String?

    private enum CodingKeys: String, CodingKey {
        case code, message, metadata
    }

    private struct Metadata: Decodable {
        let raw: String?
        let reasons: [String]?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Providers are inconsistent: the code arrives as a number ("429") or as
        // a string ("insufficient_quota").
        if let intCode = try? container.decodeIfPresent(Int.self, forKey: .code) {
            code = intCode
        } else if let stringCode = try? container.decodeIfPresent(String.self, forKey: .code) {
            code = Int(stringCode)
        } else {
            code = nil
        }

        let text = (try? container.decodeIfPresent(String.self, forKey: .message)) ?? nil
        let metadata = (try? container.decodeIfPresent(Metadata.self, forKey: .metadata)) ?? nil
        let details = [metadata?.raw, metadata?.reasons?.joined(separator: ", ")]
            .compactMap { $0 }
            .filter { !$0.isEmpty }

        let parts = ([text].compactMap { $0 } + details).filter { !$0.isEmpty }
        message = parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
