import Foundation

final class OpenRouterProviderAdapter: ProviderGatewayPort, Sendable {
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
                // OpenRouter reports rate limits, exhausted credit, moderation
                // and "no endpoints" inside the stream with HTTP 200 — the
                // accumulator turns those into a thrown error rather than an
                // empty answer.
                var accumulator = OpenAIStreamAccumulator<OpenRouterStreamChunk>()
                let modelName = body.model ?? "unknown-model"

                do {
                    for try await event in network.ssePayloads(spec) {
                        if Task.isCancelled { break }
                        guard case .payload(let payload) = event else {
                            // The connection spoke; nothing to show for it.
                            continuation.yield(.keepAlive)
                            continue
                        }
                        switch try accumulator.accept(payload, from: .openrouter) {
                        case .text(let text):
                            continuation.yield(.text(text))
                        case .finished:
                            continuation.yield(.meta(accumulator.meta(model: modelName)))
                            continuation.finish()
                            return
                        case .ignore:
                            // A role-only chunk, a reasoning delta, a shape
                            // this version does not decode: still a live model.
                            continuation.yield(.keepAlive)
                        }
                    }

                    continuation.yield(.meta(accumulator.meta(model: modelName)))
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
}
