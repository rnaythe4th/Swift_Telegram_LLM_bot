import Foundation
import AsyncHTTPClient
import NIOFoundationCompat

enum DeepseekAPI {
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
    static func deepseekStream(apiKey: String, reqParams: Prompt, showStats: Bool) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var req = HTTPClientRequest(url: "https://api.deepseek.com/v1/chat/completions")
                    req.method = .POST
                    req.headers.add(name: "Authorization", value: "Bearer \(apiKey)")
                    req.headers.add(name: "Content-Type", value: "application/json")
                    let data = try JSONEncoder().encode(reqParams)
                    req.body = .bytes(data)
                    
                    let response = try await HTTPClient.shared.execute(req, timeout: .seconds(300))
                    guard (200..<300).contains(response.status.code) else {
                        var buf = try await response.body.collect(upTo: 1 << 20)
                        let errText = String(data: buf.readData(length: buf.readableBytes) ?? Data(), encoding: .utf8) ?? ""
                        throw NSError(domain: "DeepSeek", code: Int(response.status.code), userInfo: [NSLocalizedDescriptionKey: "HTTP \(response.status.code) \n\(errText)"])
                    }
                    var capturedUsage: Usage?
                    var accumulator = Data()
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
                                // финальный доброс Usage (если был)
                                if let u = capturedUsage {
                                    continuation.yield(formatUsage(u))
                                }
                                continuation.finish()
                                return
                            }
                            guard let json = payload.data(using: .utf8) else { continue }
                            
                            // 1) Сначала попробуем поймать usage-чанк
                            if showStats, let u = parseUsage(jsonData: json) {
                                capturedUsage = u
                                continue
                            }
                            
                            if let piece = parseDelta(jsonData: json), !piece.isEmpty {
                                continuation.yield(piece)
                            }
                        }
                    }
                    continuation.finish()
                    
                } catch {
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
    // текст с использованными токенами в конце сообщения
    private static func formatUsage(_ u: Usage) -> String {
        
        var reasoning_tokens = ""
        
        if let r = u.completion_details?.reasoning_tokens {
            reasoning_tokens = "\n• Reasoning: \(r)"
        }
        
        return """
        
        ———
        • Prompt: \(u.prompt_tokens)
           • cache hit: \(u.prompt_cache_hit_tokens)
           • cache miss: \(u.prompt_cache_miss_tokens)\(reasoning_tokens)
        • Completion: \(u.completion_tokens)
        • Total: \(u.total_tokens)
        """
    }
}
