import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

enum WebhookEndpoint {
    static let path = "/telegram/webhook"
    static let secretHeader = "X-Telegram-Bot-Api-Secret-Token"
}

struct AppHTTPResponse: Sendable {
    var status: HTTPResponseStatus
    var contentType: String = "text/plain; charset=utf-8"
    var body: String = ""

    static func ok(_ body: String = "OK") -> AppHTTPResponse {
        AppHTTPResponse(status: .ok, body: body)
    }

    static func json(_ body: String) -> AppHTTPResponse {
        AppHTTPResponse(status: .ok, contentType: "application/json; charset=utf-8", body: body)
    }
}

typealias AppHTTPRouteHandler = @Sendable (_ head: HTTPRequestHead, _ body: Data) async -> AppHTTPResponse

/// Small NIO HTTP/1.1 server serving liveness/readiness/metrics endpoints and
/// the Telegram webhook. One shared handler closure routes by method + path.
final class AppHTTPServer {
    private let group: MultiThreadedEventLoopGroup
    private let port: Int
    private let handler: AppHTTPRouteHandler
    private var channel: Channel?

    init(port: Int, handler: @escaping AppHTTPRouteHandler) {
        self.port = port
        self.handler = handler
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    }

    func start() async throws {
        let handler = self.handler
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socket(.init(SOL_SOCKET), .init(SO_REUSEADDR)), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(HTTPRouteChannelHandler(handler: handler))
                }
            }

        let boundChannel = try await bootstrap.bind(host: "0.0.0.0", port: port).get()
        self.channel = boundChannel
    }

    func shutdown() async throws {
        try await channel?.close().get()
        try await group.shutdownGracefully()
    }
}

private final class HTTPRouteChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private static let maxBodyBytes = 1 << 20

    private let handler: AppHTTPRouteHandler
    private var requestHead: HTTPRequestHead?
    private var bodyData = Data()
    private var bodyTooLarge = false

    init(handler: @escaping AppHTTPRouteHandler) {
        self.handler = handler
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            requestHead = head
            bodyData = Data()
            bodyTooLarge = false

        case .body(var buffer):
            guard !bodyTooLarge else { return }
            if bodyData.count + buffer.readableBytes > Self.maxBodyBytes {
                bodyTooLarge = true
                bodyData = Data()
                return
            }
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                bodyData.append(contentsOf: bytes)
            }

        case .end:
            guard let head = requestHead else {
                context.close(promise: nil)
                return
            }
            let body = bodyData
            let tooLarge = bodyTooLarge
            requestHead = nil
            bodyData = Data()

            let keepAlive = head.isKeepAlive
            let channel = context.channel
            let handler = self.handler

            Task {
                let response: AppHTTPResponse
                if tooLarge {
                    response = AppHTTPResponse(status: .payloadTooLarge, body: "payload too large")
                } else {
                    response = await handler(head, body)
                }
                Self.write(response, to: channel, keepAlive: keepAlive)
            }
        }
    }

    private static func write(_ response: AppHTTPResponse, to channel: Channel, keepAlive: Bool) {
        channel.eventLoop.execute {
            let bodyBytes = Array(response.body.utf8)
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: response.contentType)
            headers.add(name: "Content-Length", value: "\(bodyBytes.count)")
            if !keepAlive {
                headers.add(name: "Connection", value: "close")
            }

            let head = HTTPResponseHead(version: .http1_1, status: response.status, headers: headers)
            channel.write(HTTPServerResponsePart.head(head), promise: nil)

            var buffer = channel.allocator.buffer(capacity: bodyBytes.count)
            buffer.writeBytes(bodyBytes)
            channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)

            let endPromise = channel.eventLoop.makePromise(of: Void.self)
            channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: endPromise)
            if !keepAlive {
                endPromise.futureResult.whenComplete { _ in
                    channel.close(promise: nil)
                }
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
