import Foundation
import NIOCore
import NIOHTTP1
@testable import LLM_chat_bot

/// One captured Bot API call. The body is kept as raw JSON text (that is what
/// crosses actor boundaries safely); the accessors parse it on the test side.
struct TelegramCall: Sendable {
    let method: String
    let body: String

    private var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
    }

    var text: String? { json["text"] as? String }
    var chatID: Int? {
        if let value = json["chat_id"] as? Int { return value }
        if let value = json["chat_id"] as? String { return Int(value) }
        return nil
    }
    var parseMode: String? { json["parse_mode"] as? String }

    /// callback_data of every button, in row order.
    var buttonActions: [String] { buttons.compactMap { $0["callback_data"] as? String } }
    var buttonLabels: [String] { buttons.compactMap { $0["text"] as? String } }

    private var buttons: [[String: Any]] {
        guard let markup = json["reply_markup"] as? [String: Any],
              let rows = markup["inline_keyboard"] as? [[[String: Any]]] else { return [] }
        return rows.flatMap { $0 }
    }

    func contains(_ needle: String) -> Bool { body.contains(needle) }
}

/// A local stand-in for the Bot API.
///
/// The gateway's base URL is overridable (`TELEGRAM_API_BASE`) exactly so this
/// can exist: the end-to-end tests point the real `TelegramHTTPGateway` here and
/// then assert **what the bot sent** — text, keyboard, parse mode — instead of
/// only that some call happened. No token, no network, no phone.
final class FakeTelegram: @unchecked Sendable {
    private let recorder = CallRecorder()
    private var server: AppHTTPServer?

    /// Boots on a free port and returns the base URL to hand to the gateway.
    func start() async throws -> String {
        let port = Self.freePort()
        let recorder = self.recorder
        let server = AppHTTPServer(port: port) { head, body in
            await recorder.record(head: head, body: body)
        }
        try await server.start()
        self.server = server
        return "http://127.0.0.1:\(port)"
    }

    func stop() async {
        try? await server?.shutdown()
        server = nil
    }

    func calls(_ method: String) async -> [TelegramCall] { await recorder.calls(method) }
    func lastCall(_ method: String) async -> TelegramCall? { await recorder.calls(method).last }
    func allCalls() async -> [TelegramCall] { await recorder.all() }
    func reset() async { await recorder.reset() }

    /// Waits for a call to show up — the bot answers on its own tasks.
    func waitForCall(_ method: String, timeout: TimeInterval = 5) async -> TelegramCall? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let call = await recorder.calls(method).last { return call }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

    /// Waits for a call to `method` whose body contains `needle` — a private
    /// chat gets a "💭 Думаю…" control message before the answer, so "the last
    /// call" is not the interesting one.
    func waitForCall(_ method: String, containing needle: String, timeout: TimeInterval = 5) async -> TelegramCall? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let call = await recorder.calls(method).last(where: { $0.contains(needle) }) { return call }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

    /// Waits until `method` has been called at least `count` times.
    func waitForCalls(_ method: String, count: Int, timeout: TimeInterval = 5) async -> [TelegramCall] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let calls = await recorder.calls(method)
            if calls.count >= count { return calls }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await recorder.calls(method)
    }

    private static func freePort() -> Int {
        // Ask the OS for an ephemeral port: parallel test suites must not fight
        // over a hardcoded one.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        withUnsafePointer(to: &addr) {
            _ = $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) {
            _ = $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        return Int(UInt16(bigEndian: bound.sin_port))
    }
}

/// Records calls and answers them the way the Bot API would.
private actor CallRecorder {
    private var recorded: [TelegramCall] = []
    private var nextMessageID = 1_000

    func all() -> [TelegramCall] { recorded }
    func calls(_ method: String) -> [TelegramCall] { recorded.filter { $0.method == method } }
    func reset() { recorded.removeAll() }

    func record(head: HTTPRequestHead, body: Data) -> AppHTTPResponse {
        // The path is `/bot<token>/<method>`.
        let method = String(head.uri.split(separator: "/").last ?? "")
            .split(separator: "?").first.map(String.init) ?? ""
        let text = String(data: body, encoding: .utf8) ?? "{}"
        recorded.append(TelegramCall(method: method, body: text))

        switch method {
        case "getMe":
            return .json(#"{"ok":true,"result":{"id":1,"is_bot":true,"first_name":"Test","username":"testbot"}}"#)
        case "getUpdates":
            return .json(#"{"ok":true,"result":[]}"#)
        case "sendMessage", "editMessageText", "sendInvoice":
            nextMessageID += 1
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            let chatID = (json["chat_id"] as? Int) ?? 0
            return .json("""
            {"ok":true,"result":{"message_id":\(nextMessageID),"date":0,
             "chat":{"id":\(chatID),"type":"private"}}}
            """)
        default:
            // answerCallbackQuery, sendChatAction, deleteWebhook, setWebhook,
            // answerPreCheckoutQuery … all answer with a bare `true`.
            return .json(#"{"ok":true,"result":true}"#)
        }
    }
}

// MARK: - The other ports the orchestrator needs

/// Answers with a canned reply instead of calling a real model.
struct FakeProviderGateway: ProviderGatewayPort {
    let provider: ServiceProvider
    let reply: String

    var capabilities: ProviderCapabilities {
        ProviderCapabilities(
            supportsImageInput: true,
            supportsAudioInput: true,
            supportsVideoInput: true,
            supportsReasoning: false
        )
    }

    init(provider: ServiceProvider = .openrouter, reply: String = "тестовый ответ") {
        self.provider = provider
        self.reply = reply
    }

    func makeRequest(_ plan: ProviderGenerationPlan) -> ProviderGatewayRequest {
        .openrouter(OpenRouterRequestBody(
            messages: plan.messages,
            model: plan.model,
            stream: true,
            temperature: plan.temperature,
            reasoning: nil
        ))
    }

    func stream(_ request: ProviderGatewayRequest) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        let reply = self.reply
        return AsyncThrowingStream { continuation in
            continuation.yield(.text(reply))
            continuation.yield(.meta(StreamMeta(model: "fake/model", usage: nil)))
            continuation.finish()
        }
    }

    func fallbackModel(for plan: ProviderGenerationPlan) -> String { plan.model }
}

struct FakeMediaResolver: MediaResolverPort {
    func resolveMedia(_ refs: [InboundMediaRef]) async throws -> [ResolvedMedia] { [] }
}

/// Keeps test output readable; failures still surface through assertions.
struct SilentLogger: LoggerPort {
    func info(_ message: String) {}
    func warning(_ message: String) {}
    func error(_ message: String) {}
}
