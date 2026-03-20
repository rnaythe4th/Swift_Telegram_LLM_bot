import Foundation

enum BotCallbackAction: Equatable, Sendable {
    case stop(GenerationID)

    init?(rawData: String) {
        let parts = rawData.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return nil
        }

        switch String(parts[0]) {
        case "stop":
            guard let uuid = UUID(uuidString: String(parts[1])) else {
                return nil
            }
            self = .stop(GenerationID(raw: uuid))
        default:
            return nil
        }
    }

    var rawData: String {
        switch self {
        case .stop(let generationID):
            return "stop:\(generationID.raw.uuidString)"
        }
    }
}
