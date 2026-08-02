import Foundation
import AsyncHTTPClient
import NIOFoundationCompat

enum RequestMethod {
    case get
    case post
    case patch
    case delete
}

/// Type-erased request body.
///
/// The initialiser takes `Encodable & Sendable`, not just `Encodable`: the
/// closure it stores captures the value and the whole spec is handed to another
/// task, so a non-`Sendable` payload here was a genuine data race wearing an
/// `@unchecked` badge. Narrowing the requirement lets the compiler check it,
/// and makes `HTTPBody` and `HTTPRequestSpec` plain `Sendable` in turn.
struct AnyEncodable: Encodable, Sendable {
    private let encodeImpl: @Sendable (Encoder) throws -> Void

    init<T: Encodable & Sendable>(_ value: T) {
        self.encodeImpl = { encoder in try value.encode(to: encoder) }
    }

    func encode(to encoder: Encoder) throws {
        try encodeImpl(encoder)
    }
}

enum HTTPBody: Sendable {
    case none
    case json(AnyEncodable)
}

struct HTTPRequestSpec: Sendable {
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
    /// An event stream sent more than `limit` bytes without ever ending a line.
    case streamOverflow(limit: Int)

    var errorDescription: String? {
        switch self {
        case .invalidStatus(let response):
            let body = String(data: response.data, encoding: .utf8) ?? "<non-utf8>"
            return "HTTP \(response.statusCode) \(response.statusText). Body: \(body)"
        case .decodeFailure(let typeName, let bodyPreview, let underlying):
            return "Failed to decode \(typeName). Body: \(bodyPreview). Underlying: \(underlying)"
        case .encodeFailure(let underlying):
            return "Failed to encode request body: \(underlying)"
        case .streamOverflow(let limit):
            return "Event stream exceeded \(limit) bytes without a line break"
        }
    }
}

enum SharedHTTPClient {
    static let instance = HTTPClient(eventLoopGroupProvider: .singleton)
}

final class NetworkClient: Sendable {
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
    
    /// The event stream of `spec`, framed.
    ///
    /// Carries keep-alives as well as payloads: a caller that measures silence
    /// has to be able to tell "nothing is being sent" from "nothing worth
    /// decoding is being sent", and those look identical once the comments are
    /// thrown away.
    func ssePayloads(_ spec: HTTPRequestSpec) -> AsyncThrowingStream<ServerSentEventParser.Event, Error> {
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
                    
                    // Framing lives in its own type (and its own tests): a
                    // chunk boundary inside a line, inside a UTF-8 sequence or
                    // between `\r` and `\n` is what silently eats tokens.
                    var parser = ServerSentEventParser(bufferLimit: spec.maxBodyBytes)

                    for try await var part in response.body {
                        if Task.isCancelled { break }
                        guard let bytes = part.readBytes(length: part.readableBytes) else { continue }
                        do {
                            for payload in try parser.consume(Data(bytes)) {
                                continuation.yield(payload)
                            }
                        } catch let overflow as ServerSentEventParser.BufferOverflow {
                            throw NetworkTransportError.streamOverflow(limit: overflow.limit)
                        }
                    }

                    for payload in parser.finish() {
                        continuation.yield(payload)
                    }
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
        case .patch:
            request.method = .PATCH
        case .delete:
            request.method = .DELETE
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
