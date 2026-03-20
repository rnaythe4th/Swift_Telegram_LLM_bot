import Foundation
import AsyncHTTPClient
import NIOFoundationCompat

enum RequestMethod {
    case get
    case post
}

struct AnyEncodable: Encodable, @unchecked Sendable {
    private let encodeImpl: (Encoder) throws -> Void
    
    init<T: Encodable>(_ value: T) {
        self.encodeImpl = value.encode(to:)
    }
    
    func encode(to encoder: Encoder) throws {
        try encodeImpl(encoder)
    }
}

enum HTTPBody: @unchecked Sendable {
    case none
    case json(AnyEncodable)
}

struct HTTPRequestSpec: @unchecked Sendable {
    var url: String
    var method: RequestMethod = .get
    var headers: [String: String] = [:]
    var body: HTTPBody = .none
    var timeoutSeconds: Int64 = 30
    var maxBodyBytes: Int = 1 << 22
    var validStatusCodes: Range<Int> = 200..<300
}

struct HTTPResponseRaw: Sendable {
    let statusCode: Int
    let statusText: String
    let data: Data
}

enum NetworkTransportError: Error, LocalizedError {
    case invalidStatus(HTTPResponseRaw)
    case decodeFailure(typeName: String, bodyPreview: String, underlying: Error)
    case encodeFailure(Error)
    
    var errorDescription: String? {
        switch self {
        case .invalidStatus(let response):
            let body = String(data: response.data, encoding: .utf8) ?? "<non-utf8>"
            return "HTTP \(response.statusCode) \(response.statusText). Body: \(body)"
        case .decodeFailure(let typeName, let bodyPreview, let underlying):
            return "Failed to decode \(typeName). Body: \(bodyPreview). Underlying: \(underlying)"
        case .encodeFailure(let underlying):
            return "Failed to encode request body: \(underlying)"
        }
    }
}

enum SharedHTTPClient {
    static let instance = HTTPClient(eventLoopGroupProvider: .singleton)
}

final class NetworkClient: @unchecked Sendable {
    private let httpClient: HTTPClient
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    
    init(
        httpClient: HTTPClient = SharedHTTPClient.instance,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.httpClient = httpClient
        self.encoder = encoder
        self.decoder = decoder
    }
    
    func send<Response: Decodable>(
        _ spec: HTTPRequestSpec,
        as type: Response.Type = Response.self,
        decoder customDecoder: JSONDecoder? = nil
    ) async throws -> Response {
        let raw = try await perform(spec)
        do {
            return try (customDecoder ?? decoder).decode(type, from: raw.data)
        } catch {
            throw NetworkTransportError.decodeFailure(
                typeName: String(describing: type),
                bodyPreview: String(data: raw.data, encoding: .utf8) ?? "<non-utf8>",
                underlying: error
            )
        }
    }
    
    func perform(_ spec: HTTPRequestSpec) async throws -> HTTPResponseRaw {
        let request = try buildRequest(spec)
        let response = try await httpClient.execute(request, timeout: .seconds(spec.timeoutSeconds))
        var bodyBuffer = try await response.body.collect(upTo: spec.maxBodyBytes)
        let bodyData = bodyBuffer.readData(length: bodyBuffer.readableBytes) ?? Data()
        
        let raw = HTTPResponseRaw(
            statusCode: Int(response.status.code),
            statusText: String(describing: response.status),
            data: bodyData
        )
        
        guard spec.validStatusCodes.contains(raw.statusCode) else {
            throw NetworkTransportError.invalidStatus(raw)
        }
        
        return raw
    }
    
    func ssePayloads(_ spec: HTTPRequestSpec) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = try buildRequest(spec)
                    if request.headers["Accept"].isEmpty {
                        request.headers.add(name: "Accept", value: "text/event-stream")
                    }
                    
                    let response = try await httpClient.execute(request, timeout: .seconds(spec.timeoutSeconds))
                    guard spec.validStatusCodes.contains(Int(response.status.code)) else {
                        var err = try await response.body.collect(upTo: spec.maxBodyBytes)
                        let data = err.readData(length: err.readableBytes) ?? Data()
                        throw NetworkTransportError.invalidStatus(
                            .init(
                                statusCode: Int(response.status.code),
                                statusText: String(describing: response.status),
                                data: data
                            )
                        )
                    }
                    
                    var accumulator = Data()
                    var eventDataLines: [String] = []
                    
                    let flush: () -> Void = {
                        guard !eventDataLines.isEmpty else { return }
                        let payload = eventDataLines.joined(separator: "\n")
                        eventDataLines.removeAll(keepingCapacity: true)
                        continuation.yield(payload)
                    }
                    
                    for try await var part in response.body {
                        if Task.isCancelled { break }
                        if let bytes = part.readBytes(length: part.readableBytes) {
                            accumulator.append(contentsOf: bytes)
                        }
                        
                        while let lineEnd = accumulator.firstRange(of: Data([0x0A])) {
                            var lineData = accumulator.subdata(in: 0..<lineEnd.lowerBound)
                            accumulator.removeSubrange(0..<lineEnd.upperBound)
                            
                            if lineData.last == 0x0D {
                                lineData.removeLast()
                            }
                            
                            guard let line = String(data: lineData, encoding: .utf8) else { continue }
                            if line.isEmpty {
                                flush()
                                continue
                            }
                            
                            guard line.hasPrefix("data:") else { continue }
                            let payloadLine = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            eventDataLines.append(payloadLine)
                        }
                    }
                    
                    if !accumulator.isEmpty,
                       var tail = String(data: accumulator, encoding: .utf8) {
                        if tail.hasSuffix("\r") { tail.removeLast() }
                        if tail.hasPrefix("data:") {
                            let payloadLine = tail.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            eventDataLines.append(payloadLine)
                        }
                    }
                    
                    flush()
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
    
    private func buildRequest(_ spec: HTTPRequestSpec) throws -> HTTPClientRequest {
        var request = HTTPClientRequest(url: spec.url)
        switch spec.method {
        case .get:
            request.method = .GET
        case .post:
            request.method = .POST
        }
        
        for (name, value) in spec.headers {
            request.headers.add(name: name, value: value)
        }
        
        switch spec.body {
        case .none:
            break
        case .json(let encodable):
            do {
                let data = try encoder.encode(encodable)
                if request.headers["Content-Type"].isEmpty {
                    request.headers.add(name: "Content-Type", value: "application/json")
                }
                request.body = .bytes(data)
            } catch {
                throw NetworkTransportError.encodeFailure(error)
            }
        }
        
        return request
    }
}
