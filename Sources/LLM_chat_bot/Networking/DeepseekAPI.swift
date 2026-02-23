import Foundation
import AsyncHTTPClient
import NIOFoundationCompat

enum DeepseekAPI {
    private static func log(_ message: String) {
        print("[DeepseekAPI] \(message)")
    }

    private static func preview(_ text: String, limit: Int = 80) -> String {
        let normalized = text.replacingOccurrences(of: "\n", with: "\\n")
        if normalized.count <= limit { return normalized }
        return String(normalized.prefix(limit)) + "..."
    }

    // просто ответ без стрима
    static func getDeepseekResponse(apiKey: String, reqParams: Prompt) async throws -> String {
        var req = HTTPClientRequest(url: "https://api.deepseek.com/v1/chat/completions")
        req.method = .POST
        req.headers.add(name: "Authorization", value: "Bearer \(apiKey)")
        req.headers.add(name: "Content-Type", value: "application/json")
        let data = try JSONEncoder().encode(reqParams)
        req.body = .bytes(data)
        
        let response = try await HTTPClient.shared.execute(req, timeout: .seconds(60))
        guard response.status == .ok else {
            return "error getting deepseek response: \(response.status)"
        }
        
        var buf = try await response.body.collect(upTo: 1 << 22)
        let responseData = buf.readData(length: buf.readableBytes) ?? Data()
        let decoded = try JSONDecoder().decode(DSChatResponse.self, from: responseData)
        let answer = decoded.choices.first?.message.content ?? "(пусто)"
        return answer
    }
    // ответ со стримом
    static func deepseekStream(apiKey: String, reqParams: Prompt) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    log("stream start: model=\(reqParams.model)")
                    var req = HTTPClientRequest(url: "https://api.deepseek.com/v1/chat/completions")
                    req.method = .POST
                    req.headers.add(name: "Authorization", value: "Bearer \(apiKey)")
                    req.headers.add(name: "Content-Type", value: "application/json")
                    let data = try JSONEncoder().encode(reqParams)
                    req.body = .bytes(data)
                    
                    log("request encoded, bytes=\(data.count). sending...")
                    let response = try await HTTPClient.shared.execute(req, timeout: .seconds(300))
                    log("response status=\(response.status.code)")
                    guard (200..<300).contains(response.status.code) else {
                        var buf = try await response.body.collect(upTo: 1 << 20)
                        let errText = String(data: buf.readData(length: buf.readableBytes) ?? Data(), encoding: .utf8) ?? ""
                        log("non-2xx response, body=\(preview(errText, limit: 240))")
                        throw NSError(domain: "DeepSeek", code: Int(response.status.code), userInfo: [NSLocalizedDescriptionKey: "HTTP \(response.status.code) \n\(errText)"])
                    }
                    var capturedUsage: Usage?
                    var didYieldMeta = false
                    var accumulator = Data()
                    var yieldedChunks = 0

                    let yieldMetaIfNeeded: () -> Void = {
                        guard !didYieldMeta else { return }
                        didYieldMeta = true

                        let usageSummary = capturedUsage.map { u in
                            StreamUsageSummary(
                                promptTokens: Double(u.prompt_tokens),
                                completionTokens: Double(u.completion_tokens),
                                totalTokens: Double(u.total_tokens),
                                cacheHitTokens: Double(u.prompt_cache_hit_tokens),
                                cacheWriteTokens: nil,
                                cacheMissTokens: Double(u.prompt_cache_miss_tokens),
                                reasoningTokens: u.completion_details.map { Double($0.reasoning_tokens) },
                                cost: nil
                            )
                        }

                        continuation.yield(.meta(.init(model: reqParams.model, usage: usageSummary)))
                    }

                    for try await var part in response.body {
                        if Task.isCancelled { break }
                        if let bytes = part.readBytes(length: part.readableBytes) {
                            accumulator.append(contentsOf: bytes)
                        }
                        // читаем по строкам (SSE — строки, начинаются с "data: ")
                        while let r = accumulator.firstRange(of: Data("\n".utf8)) {
                            let lineData = accumulator.subdata(in: 0..<r.lowerBound)
                            accumulator.removeSubrange(0..<(r.upperBound))
                            guard !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8) else { continue }
                            guard line.hasPrefix("data:") else { continue }
                            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            if payload == "[DONE]" {
                                log("received [DONE], yieldedChunks=\(yieldedChunks)")
                                yieldMetaIfNeeded()
                                continuation.finish()
                                log("stream finished")
                                return
                            }
                            guard let json = payload.data(using: .utf8) else { continue }
                            
                            if let u = parseUsage(jsonData: json) {
                                capturedUsage = u
                                log("usage chunk received: prompt=\(u.prompt_tokens), completion=\(u.completion_tokens), total=\(u.total_tokens)")
                            }
                            
                            if let piece = parseDelta(jsonData: json), !piece.isEmpty {
                                yieldedChunks += 1
                                log("delta chunk #\(yieldedChunks), chars=\(piece.count), preview=\(preview(piece))")
                                continuation.yield(.text(piece))
                            }
                        }
                    }
                    if Task.isCancelled {
                        log("producer task cancelled before normal finish")
                    }
                    yieldMetaIfNeeded()
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
        }
    }
    
    // пробуем распарсит usage-чанка
    private static func parseUsage(jsonData: Data) -> Usage? {
        let chunk = try? JSONDecoder().decode(StreamChunk.self, from: jsonData)
        return chunk?.usage
    }
    // парсинг обычного дельта-чанка
    private static func parseDelta(jsonData: Data) -> String? {
        (try? JSONDecoder().decode(StreamChunk.self, from: jsonData))?.choices.first?.delta?.content
    }
}
