import Foundation

protocol StatePersistencePort: Sendable {
    func saveState(_ snapshot: BotStateSnapshot) async throws
    func loadState() async throws -> BotStateSnapshot?
}
