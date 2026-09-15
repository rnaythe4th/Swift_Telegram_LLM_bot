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
    /// Silence on an open connection before it is dropped. Generous next to
    /// anything a request here does (the webhook only enqueues), tight enough
    /// that abandoned sockets do not accumulate for the life of the process.
    static let idleTimeout: TimeAmount = .seconds(120)

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
                // Built on the event loop the handlers will run on: NIO's
                // handlers are loop-confined, not `Sendable`, and the
                // synchronous API is where that is expressible.
                channel.eventLoop.makeCompletedFuture {
                    let pipeline = channel.pipeline.syncOperations
                    try pipeline.configureHTTPServerPipeline()
                    // A connection nobody speaks on is a file descriptor nobody
                    // gets back: Telegram, the platform's health prober and any
                    // stranger who finds the port all keep sockets alive, and
                    // this process has no other bound on how many.
                    try pipeline.addHandler(IdleStateHandler(readTimeout: Self.idleTimeout))
                    try pipeline.addHandler(HTTPRouteChannelHandler(handler: handler))
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

/// Safety is provided by NIO's confinement: a channel handler is only ever
/// touched on its own event loop, which is the guarantee `ChannelInboundHandler`
/// is written against (§5.5).
private final class HTTPRouteChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private static let maxBodyBytes = 1 << 20

    private let handler: AppHTTPRouteHandler
    private var requestHead: HTTPRequestHead?
    private var bodyData = Data()
    private var bodyTooLarge = false
    /// Set while a handler is running. The idle timer must not close the
    /// connection out from under a request that is about to be answered.
    private var isResponding = false

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
            // HEAD asks for the headers of what GET would return — a body here
            // is a protocol violation the next response on the connection pays
            // for, because the client reads it as the head of that response.
            let omitBody = head.method == .HEAD
            isResponding = true

            Task {
                let response: AppHTTPResponse
                if tooLarge {
                    response = AppHTTPResponse(status: .payloadTooLarge, body: "payload too large")
                } else {
                    response = await handler(head, body)
                }
                self.write(response, to: channel, keepAlive: keepAlive, omitBody: omitBody)
            }
        }
    }

    /// Closes a connection that has gone quiet — but never one whose answer is
    /// still being written.
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard event is IdleStateHandler.IdleStateEvent else {
            context.fireUserInboundEventTriggered(event)
            return
        }
        if !isResponding {
            context.close(promise: nil)
        }
    }

    private func write(_ response: AppHTTPResponse, to channel: Channel, keepAlive: Bool, omitBody: Bool) {
        channel.eventLoop.execute {
            self.isResponding = false
            let bodyBytes = Array(response.body.utf8)
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: response.contentType)
            headers.add(name: "Content-Length", value: "\(bodyBytes.count)")
            if !keepAlive {
                headers.add(name: "Connection", value: "close")
            }

            let head = HTTPResponseHead(version: .http1_1, status: response.status, headers: headers)
            channel.write(HTTPServerResponsePart.head(head), promise: nil)

            if !omitBody {
                var buffer = channel.allocator.buffer(capacity: bodyBytes.count)
                buffer.writeBytes(bodyBytes)
                channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
            }

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
