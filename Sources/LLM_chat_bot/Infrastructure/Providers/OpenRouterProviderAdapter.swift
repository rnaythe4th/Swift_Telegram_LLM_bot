import Foundation

final class OpenRouterProviderAdapter: ProviderGatewayPort, @unchecked Sendable {
    let provider: ServiceProvider = .openrouter
    let capabilities = ProviderCapabilities(
        supportsImageInput: true,
        supportsAudioInput: true,
        supportsVideoInput: true,
        supportsReasoning: true
    )
    
    private let network: NetworkClient
    private let apiKey: String
    
    init(network: NetworkClient, apiKey: String) {
        self.network = network
        self.apiKey = apiKey
    }
    
    func makeRequest(_ plan: ProviderGenerationPlan) -> ProviderGatewayRequest {
        .openrouter(
            OpenRouterRequestBody(
                messages: plan.messages,
                model: plan.model,
                stream: true,
                stream_options: plan.includeUsage ? .init(include_usage: true) : nil,
                stop: nil,
                max_tokens: nil,
                temperature: plan.temperature,
                reasoning: OpenRouterReasoning(
                    effort: plan.reasoningEffort?.rawValue ?? "high",
                    summary: "concise",
                    enabled: plan.reasoningEffort != nil
                ),
                provider: plan.providerRouting.map {
                    OpenRouterProviderRouting(order: [$0], only: [$0], allow_fallbacks: false)
                }
            )
        )
    }
    
    func fallbackModel(for plan: ProviderGenerationPlan) -> String {
        plan.model
    }
    
    func stream(_ request: ProviderGatewayRequest) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        guard case .openrouter(let body) = request else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: ProviderAdapterError.invalidRequestType(.openrouter))
            }
        }
        
        let spec = HTTPRequestSpec(
            url: "https://openrouter.ai/api/v1/chat/completions",
            method: .post,
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Content-Type": "application/json",
                "Accept": "text/event-stream",
                "X-Title": "LLM Telegram Bot Blueprint"
            ],
            body: .json(.init(body)),
            timeoutSeconds: 300,
            maxBodyBytes: 1 << 20
        )
        
        return AsyncThrowingStream { continuation in
            let producer = Task {
                var capturedUsage: OpenRouterResponseUsage?
                var didYieldMeta = false
                let modelName = body.model ?? "unknown-model"
                
                let yieldMetaIfNeeded: () -> Void = {
                    guard !didYieldMeta else { return }
                    didYieldMeta = true
                    
                    let usageSummary = capturedUsage.map { u in
                        StreamUsageSummary(
                            promptTokens: Double(u.prompt_tokens),
                            completionTokens: Double(u.completion_tokens),
                            totalTokens: Double(u.total_tokens),
                            cacheHitTokens: u.prompt_tokens_details?.cachedTokens.map(Double.init),
                            cacheWriteTokens: u.prompt_tokens_details?.cacheWriteTokens.map(Double.init),
                            cacheMissTokens: nil,
                            reasoningTokens: u.completion_tokens_details?.reasoning_tokens.map(Double.init),
                            cost: u.cost ?? u.cost_details?.upstream_inference_cost
                        )
                    }
                    
                    continuation.yield(.meta(.init(model: modelName, usage: usageSummary)))
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
    
    private func parseUsage(jsonData: Data) -> OpenRouterResponseUsage? {
        (try? JSONDecoder().decode(OpenRouterStreamChunk.self, from: jsonData))?.usage
    }
    
    private func parseDelta(jsonData: Data) -> String? {
        guard let chunk = try? JSONDecoder().decode(OpenRouterStreamChunk.self, from: jsonData),
              let choices = chunk.choices else {
            return nil
        }
        let pieces = choices.compactMap { $0.delta?.content }.filter { !$0.isEmpty }
        guard !pieces.isEmpty else { return nil }
        return pieces.joined()
    }
}
