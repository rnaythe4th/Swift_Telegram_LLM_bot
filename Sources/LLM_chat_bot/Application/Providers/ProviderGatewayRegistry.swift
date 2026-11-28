import Foundation

enum ProviderGatewayRegistryError: LocalizedError {
    case missingAdapter(ServiceProvider)
    
    var errorDescription: String? {
        switch self {
        case .missingAdapter(let provider):
            return "Сервис \(provider.rawValue) отключён. Выберите доступный через /provider или /menu."
        }
    }
}

struct ProviderGatewayRegistry {
    private let providers: [ServiceProvider: ProviderGatewayPort]
    
    let web: (any DeepSeekWebGateway)?

    init(providers: [ServiceProvider: ProviderGatewayPort], web: (any DeepSeekWebGateway)? = nil) {
        self.providers = providers
        self.web = web
    }

    var available: [ServiceProvider] {
        ServiceProvider.allCases.filter { capabilities(for: $0) != nil }
    }

    func capabilities(for provider: ServiceProvider) -> ProviderCapabilities? {
        if provider == .deepseekWeb {
            guard web != nil else { return nil }
            return .init(
                supportsImageInput: true, supportsAudioInput: false, supportsVideoInput: false,
                supportsReasoning: true, supportsDocumentInput: true
            )
        }
        return providers[provider]?.capabilities
    }
    
    func gateway(for provider: ServiceProvider) throws -> ProviderGatewayPort {
        guard let gateway = providers[provider] else {
            throw ProviderGatewayRegistryError.missingAdapter(provider)
        }
        
        return gateway
    }
}
