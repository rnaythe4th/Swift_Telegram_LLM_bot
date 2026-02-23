import Foundation
import AsyncHTTPClient
import NIOFoundationCompat

enum OpenRouterAPI {
    private static func log(_ message: String) {
        print("[OpenRouterAPI] \(message)")
    }

    private static func preview(_ text: String, limit: Int = 80) -> String {
        let normalized = text.replacingOccurrences(of: "\n", with: "\\n")
        if normalized.count <= limit { return normalized }
        return String(normalized.prefix(limit)) + "..."
    }

    // просто ответ без стрима
    static func getResponse(apiKey: String, reqParams: Prompt) async throws -> String {
        var req = HTTPClientRequest(url: "https://openrouter.ai/api/v1/chat/completions")
        req.method = .POST
        req.headers.add(name: "Authorization", value: "Bearer \(apiKey)")
        req.headers.add(name: "Content-Type", value: "application/json")
        // Рекомендуется по доке указывать источник
        req.headers.add(name: "X-Title", value: "LLM Telegram Bot")
        let data = try JSONEncoder().encode(reqParams)
        req.body = .bytes(data)

        let response = try await HTTPClient.shared.execute(req, timeout: .seconds(60))
        guard response.status == .ok else {
            return "error getting openrouter response: \(response.status)"
        }

        var buf = try await response.body.collect(upTo: 1 << 22)
        let responseData = buf.readData(length: buf.readableBytes) ?? Data()
        let decoded = try JSONDecoder().decode(DSChatResponse.self, from: responseData)
        let answer = decoded.choices.first?.message.content ?? "(пусто)"
        return answer
    }
    // ответ со стримом
    static func stream(apiKey: String, reqBody: RouterRequestBody, showStats: Bool) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let requestTask = Task {
                do {
                    log("stream start: model=\(reqBody.model ?? "nil"), showStats=\(showStats)")
                    var req = HTTPClientRequest(url: "https://openrouter.ai/api/v1/chat/completions")
                    req.method = .POST
                    req.headers.add(name: "Authorization", value: "Bearer \(apiKey)")
                    req.headers.add(name: "Content-Type", value: "application/json")
                    req.headers.add(name: "Accept", value: "text/event-stream")
                    //req.headers.add(name: "Cache-Control", value: "no-cache")
                    req.headers.add(name: "X-Title", value: "LLM Telegram Bot")
                    let data = try JSONEncoder().encode(reqBody)
                    req.body = .bytes(data)

                    log("request encoded, bytes=\(data.count). sending...")
                    let response = try await HTTPClient.shared.execute(req, timeout: .seconds(300))
                    log("response status=\(response.status.code)")
                    guard (200..<300).contains(response.status.code) else {
                        var buf = try await response.body.collect(upTo: 1 << 20)
                        let errText = String(data: buf.readData(length: buf.readableBytes) ?? Data(), encoding: .utf8) ?? ""
                        log("non-2xx response, body=\(preview(errText, limit: 240))")
                        throw NSError(
                            domain: "OpenRouter",
                            code: Int(response.status.code),
                            userInfo: [NSLocalizedDescriptionKey: "HTTP \(response.status.code)\n\(errText)"]
                        )
                    }

                    var capturedUsage: RouterResponseUsage?
                    var accumulator = Data()
                    var eventDataLines: [String] = []
                    var yieldedChunks = 0

                    let processPayload: (String) -> Bool = { payload in
                        if payload == "[DONE]" {
                            log("received [DONE], yieldedChunks=\(yieldedChunks)")
                            if showStats, let u = capturedUsage {
                                log("yield final usage block")
                                continuation.yield(formatUsage(u, reqBody.model!))
                            }
                            continuation.finish()
                            log("stream finished")
                            return true
                        }

                        guard let json = payload.data(using: .utf8) else { return false }

                        if showStats, let u = parseUsage(jsonData: json) {
                            capturedUsage = u
                            log("usage chunk received: prompt=\(u.prompt_tokens), completion=\(u.completion_tokens), total=\(u.total_tokens)")
                        }

                        if let piece = parseDelta(jsonData: json), !piece.isEmpty {
                            yieldedChunks += 1
                            log("delta chunk #\(yieldedChunks), chars=\(piece.count), preview=\(preview(piece))")
                            continuation.yield(piece)
                        }

                        return false
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
                                guard !eventDataLines.isEmpty else { continue }
                                let payload = eventDataLines.joined(separator: "\n")
                                eventDataLines.removeAll(keepingCapacity: true)

                                if processPayload(payload) {
                                    return
                                }
                                continue
                            }

                            guard line.hasPrefix("data:") else { continue }
                            let payloadLine = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            eventDataLines.append(payloadLine)
                        }
                    }

                    if !accumulator.isEmpty {
                        var tailLine = String(data: accumulator, encoding: .utf8) ?? ""
                        if tailLine.hasSuffix("\r") {
                            tailLine.removeLast()
                        }
                        if tailLine.hasPrefix("data:") {
                            let payloadLine = tailLine.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            eventDataLines.append(payloadLine)
                        }
                    }

                    if !eventDataLines.isEmpty {
                        let payload = eventDataLines.joined(separator: "\n")
                        if processPayload(payload) {
                            return
                        }
                    }

                    if Task.isCancelled {
                        log("producer task cancelled before normal finish")
                    }
                    if showStats, let u = capturedUsage {
                        log("stream ended without [DONE], yielding captured usage")
                        continuation.yield(formatUsage(u, reqBody.model!))
                    }
                    continuation.finish()
                    log("stream finished (eof)")

                } catch is CancellationError {
                    log("stream cancelled")
                    continuation.finish()
                } catch {
                    log("stream failed: \(error)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                log("continuation terminated -> cancel request task")
                requestTask.cancel()
            }
        }
    }

    // пробуем распарсит usage-чанка
    private static func parseUsage(jsonData: Data) -> RouterResponseUsage? {
        (try? JSONDecoder().decode(RouterStreamChunk.self, from: jsonData))?.usage
    }
    // парсинг обычного дельта-чанка
    private static func parseDelta(jsonData: Data) -> String? {
        guard let chunk = try? JSONDecoder().decode(RouterStreamChunk.self, from: jsonData),
              let choices = chunk.choices else {
            return nil
        }
        let pieces = choices.compactMap { $0.delta?.content }.filter { !$0.isEmpty }
        guard !pieces.isEmpty else { return nil }
        return pieces.joined()
    }
    // текст с использованными токенами в конце сообщения
    private static func formatUsage(_ u: RouterResponseUsage, _ model: String) -> String {
        let cacheHitLine = u.prompt_tokens_details?.cachedTokens.map { "\n   • cache hit: \($0)" } ?? ""
        let cacheWriteLine = u.prompt_tokens_details?.cacheWriteTokens.map { "\n   • cache write: \($0)" } ?? ""
        let reasoningLine = u.completion_tokens_details?.reasoning_tokens.map { "\n   • reasoning: \($0)" } ?? ""
        
        let cost = u.cost.map { String(format: "%.6f", $0) } ?? ""

        return """

        ———
        Model: \(model)
        • Prompt: \(u.prompt_tokens)\(cacheHitLine)\(cacheWriteLine)
        • Completion: \(u.completion_tokens)\(reasoningLine)
        • Total: \(u.total_tokens)
        • COST: $\(cost)
        """
    }
}
