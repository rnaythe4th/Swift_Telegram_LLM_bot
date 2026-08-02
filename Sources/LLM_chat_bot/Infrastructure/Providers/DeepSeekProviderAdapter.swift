import Foundation

final class DeepSeekProviderAdapter: ProviderGatewayPort, Sendable {
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
                // Same dialect as OpenRouter, same failure mode: an error
                // delivered inside a 200 OK stream must end the generation
                // rather than fall through as empty text.
                var accumulator = OpenAIStreamAccumulator<DeepSeekStreamChunk>()

                do {
                    for try await event in network.ssePayloads(spec) {
                        if Task.isCancelled { break }
                        guard case .payload(let payload) = event else {
                            // The connection spoke; nothing to show for it.
                            continuation.yield(.keepAlive)
                            continue
                        }
                        switch try accumulator.accept(payload, from: .deepseek) {
                        case .text(let text):
                            continuation.yield(.text(text))
                        case .finished:
                            continuation.yield(.meta(accumulator.meta(model: body.model)))
                            continuation.finish()
                            return
                        case .ignore:
                            // A role-only chunk, a reasoning delta, a shape
                            // this version does not decode: still a live model.
                            continuation.yield(.keepAlive)
                        }
                    }

                    continuation.yield(.meta(accumulator.meta(model: body.model)))
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
