import Foundation

private struct SupabaseRow: Codable {
    let data: BotStateSnapshot
}

private struct SupabasePayload: Encodable {
    let id: Int
    let data: BotStateSnapshot
}

final class SupabaseStatePersistence: StatePersistencePort, @unchecked Sendable {
    private let network: NetworkClient
    private let baseURL: String
    private let apiKey: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(network: NetworkClient, baseURL: String, apiKey: String) {
        self.network = network
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    func saveState(_ snapshot: BotStateSnapshot) async throws {
        let payload = SupabasePayload(id: 1, data: snapshot)
        var headers = authHeaders
        headers["Prefer"] = "resolution=merge-duplicates"
        let spec = HTTPRequestSpec(
            url: "\(baseURL)/rest/v1/bot_state",
            method: .post,
            headers: headers,
            body: .json(AnyEncodable(payload)),
            timeoutSeconds: 15,
            validStatusCodes: 200..<300
        )
        _ = try await network.perform(spec)
    }

    func loadState() async throws -> BotStateSnapshot? {
        let spec = HTTPRequestSpec(
            url: "\(baseURL)/rest/v1/bot_state?select=data&id=eq.1",
            method: .get,
            headers: authHeaders,
            timeoutSeconds: 15,
            validStatusCodes: 200..<300
        )
        let rows = try await network.send(spec, as: [SupabaseRow].self, decoder: decoder)
        return rows.first?.data
    }

    private var authHeaders: [String: String] {
        [
            "apikey": apiKey,
            "Authorization": "Bearer \(apiKey)",
        ]
    }
}
