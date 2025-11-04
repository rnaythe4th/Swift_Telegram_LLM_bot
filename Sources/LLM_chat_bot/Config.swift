import Foundation

enum EnvironmentKeys: String {
    case telegramToken = "TG_BOT_TOKEN"
    case deepseekKey   = "DEEPSEEK_API_KEY"
}

enum Config {
    static func env(_ key: EnvironmentKeys) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[key.rawValue], !value.isEmpty else {
            throw NSError(domain: "Config", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing env: \(key.rawValue)"])
        }
        return value
    }

    static var telegramBaseURL: String {
        (try? env(.telegramToken)).map { "https://api.telegram.org/bot\($0)" } ?? ""
    }
}
