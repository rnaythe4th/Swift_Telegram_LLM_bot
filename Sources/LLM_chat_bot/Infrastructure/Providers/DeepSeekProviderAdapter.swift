import Foundation

final class DeepSeekProviderAdapter: ProviderGatewayPort, @unchecked Sendable {
    let provider: ServiceProvider = .deepseek
    let capabilities = ProviderCapabilities(
        supportsImageInput: false,
        supportsAudioInput: false,
        supportsVideoInput: false,
        supportsReasoning: false
    )
    
    private let network: NetworkClient
    private let apiKey: String
    
    init(network: NetworkClient, apiKey: String) {
        self.network = network
        self.apiKey = apiKey
    }
    
    func makeRequest(_ plan: ProviderGenerationPlan) -> ProviderGatewayRequest {
        .deepseek(
            DeepSeekRequestBody(
                model: "deepseek-chat",
                messages: plan.messages,
                stream: true,
                temperature: plan.temperature,
                includeUsage: plan.includeUsage
            )
        )
    }
    
    func fallbackModel(for _: ProviderGenerationPlan) -> String {
        return "deepseek-chat"
    }
    
    func stream(_ request: ProviderGatewayRequest) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        guard case .deepseek(let body) = request else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: ProviderAdapterError.invalidRequestType(.deepseek))
            }
        }
        
        let spec = HTTPRequestSpec(
            url: "https://api.deepseek.com/v1/chat/completions",
            method: .post,
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Content-Type": "application/json",
                "Accept": "text/event-stream"
            ],
            body: .json(.init(body)),
            timeoutSeconds: 300,
            maxBodyBytes: 1 << 20
        )
        
        return AsyncThrowingStream { continuation in
            let producer = Task {
                var capturedUsage: DeepSeekUsage?
                var didYieldMeta = false
                
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
                    
                    continuation.yield(.meta(.init(model: body.model, usage: usageSummary)))
                }
                
                do {
                    for try await payload in network.ssePayloads(spec) {
                        if Task.isCancelled { break }
                        if payload == "[DONE]" {
                            yieldMetaIfNeeded()
                            continuation.finish()
                            return
                        }
                        
                        guard let json = payload.data(using: .utf8) else { continue }
                        // Same as OpenRouter: an in-stream error payload must
                        // end the generation, not fall through as empty text.
                        if let failure = parseError(jsonData: json) {
                            continuation.finish(
                                throwing: ProviderAdapterError.upstream(
                                    provider: .deepseek,
                                    code: failure.code,
                                    message: failure.message
                                )
                            )
                            return
                        }
                        if let usage = parseUsage(jsonData: json) {
                            capturedUsage = usage
                        }
                        
                        if let text = parseDelta(jsonData: json), !text.isEmpty {
                            continuation.yield(.text(text))
                        }
                    }
                    
                    yieldMetaIfNeeded()
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            
            continuation.onTermination = { @Sendable _ in
                producer.cancel()
            }
        }
    }
    
    private func parseUsage(jsonData: Data) -> DeepSeekUsage? {
        (try? JSONDecoder().decode(DeepSeekStreamChunk.self, from: jsonData))?.usage
    }
    
    private func parseError(jsonData: Data) -> ProviderStreamErrorPayload? {
        (try? JSONDecoder().decode(DeepSeekStreamChunk.self, from: jsonData))?.error
    }

    private func parseDelta(jsonData: Data) -> String? {
        (try? JSONDecoder().decode(DeepSeekStreamChunk.self, from: jsonData))?.choices?.first?.delta?.content
    }
}
