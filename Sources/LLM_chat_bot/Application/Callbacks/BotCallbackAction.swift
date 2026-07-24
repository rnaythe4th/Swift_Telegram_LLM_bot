import Foundation

enum BotCallbackAction: Equatable, Sendable {
    case stop(GenerationID)
    case menu(action: String)
    case faq
    /// Onboarding example prompt tapped in the greeting (roadmap step 9).
    /// Unlike the others this one starts a generation, so the orchestrator
    /// routes it through the per-chat queue instead of the callback fast path.
    case example(id: String)

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
        case "faq":
            self = .faq
        case "ex":
            guard parts.count == 2, !parts[1].isEmpty else { return nil }
            self = .example(id: String(parts[1]))
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
        case .faq:
            return "faq"
        case .example(let id):
            return "ex:\(id)"
        }
    }
}
