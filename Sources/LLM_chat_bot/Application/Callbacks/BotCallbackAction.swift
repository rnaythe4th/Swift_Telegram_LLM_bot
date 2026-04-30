import Foundation

enum BotCallbackAction: Equatable, Sendable {
    case stop(GenerationID)
    case menu(action: String)

    init?(rawData: String) {
        let parts = rawData.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count >= 1 else {
            return nil
        }

        switch String(parts[0]) {
        case "stop":
            guard parts.count == 2,
                  let uuid = UUID(uuidString: String(parts[1])) else {
                return nil
            }
            self = .stop(GenerationID(raw: uuid))
        case "menu":
            self = .menu(action: parts.count > 1 ? String(parts[1]) : "")
        default:
            return nil
        }
    }

    var rawData: String {
        switch self {
        case .stop(let generationID):
            return "stop:\(generationID.raw.uuidString)"
        case .menu(let action):
            return action.isEmpty ? "menu" : "menu:\(action)"
        }
    }
}
