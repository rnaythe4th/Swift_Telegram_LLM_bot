import Foundation

struct DeepSeekWebWorkerRequest: Encodable, Sendable {
    let version = 1
    let operationID: UUID
    let accountEpoch: UUID
    let accountMarker: UUID?
    let remoteChatID: String?
    let remoteTail: String?
    let prompt: String?
    let deepThink: Bool?
    var candidateRemoteChatID: String?
}

enum DeepSeekWebWorkerStatus: String, Decodable, Sendable {
    case ready, maintenance, prepared, completed, cancelled, quota, busy, loginRequired
    case inputTooLong, chatUnavailable, unknownUI, uncertain, unavailable, notAccepted, inProgress, moderated
}

struct DeepSeekWebWorkerResponse: Decodable, Sendable {
    let version: Int
    let operationID: UUID
    let status: DeepSeekWebWorkerStatus
    let accepted: Bool
    let remoteChatID: String?
    let remoteTail: String?
    let text: String?
    let retryAfterSeconds: Int?
    var mayHaveSent: Bool?
    var partialText: String?
}

struct DeepSeekWebWorkerHealth: Decodable, Sendable {
    let version: Int
    let status: DeepSeekWebWorkerStatus
    let accountMarker: UUID?
}

enum DeepSeekWebWorkerAction: String {
    case prepare, send, status, reconcile, cancel
}

protocol DeepSeekWebGateway: Sendable {
    func health() async throws -> DeepSeekWebWorkerHealth
    func perform(_ action: DeepSeekWebWorkerAction, _ request: DeepSeekWebWorkerRequest) async throws -> DeepSeekWebWorkerResponse
}

struct DeepSeekWebProviderAdapter: DeepSeekWebGateway {
    let network: NetworkClient
    let port: Int
    let token: String

    func health() async throws -> DeepSeekWebWorkerHealth {
        let result = try await network.perform(.init(
            url: "http://127.0.0.1:\(port)/v1/health",
            headers: ["Authorization": "Bearer \(token)"], timeoutSeconds: 4, maxBodyBytes: 4096,
            validStatusCodes: 200..<504
        ))
        let health = try JSONDecoder().decode(DeepSeekWebWorkerHealth.self, from: result.data)
        guard health.version == 1 else { throw DeepSeekWebProtocolError.invalidResponse }
        return health
    }

    func perform(_ action: DeepSeekWebWorkerAction, _ request: DeepSeekWebWorkerRequest) async throws -> DeepSeekWebWorkerResponse {
        let timeout: Int64 = switch action {
        case .prepare, .reconcile: 65
        case .send: 560
        case .status, .cancel: 6
        }
        let result = try await network.perform(.init(
            url: "http://127.0.0.1:\(port)/v1/\(action.rawValue)",
            method: .post,
            headers: ["Authorization": "Bearer \(token)"],
            body: .json(AnyEncodable(request)),
            timeoutSeconds: timeout, maxBodyBytes: 512 * 1024,
            validStatusCodes: 200..<504
        ))
        let response = try JSONDecoder().decode(DeepSeekWebWorkerResponse.self, from: result.data)
        guard response.version == 1, response.operationID == request.operationID else {
            throw DeepSeekWebProtocolError.invalidResponse
        }
        return response
    }
}

enum DeepSeekWebProtocolError: Error {
    case invalidResponse
}
