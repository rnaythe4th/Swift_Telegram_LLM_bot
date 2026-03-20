import Foundation

enum ProviderGatewayRegistryError: LocalizedError {
    case missingAdapter(ServiceProvider)
    
    var errorDescription: String? {
        switch self {
        case .missingAdapter(let provider):
            return "Provider adapter not found: \(provider.rawValue)"
        }
    }
}

struct ProviderGatewayRegistry {
    private let providers: [ServiceProvider: ProviderGatewayPort]
    
    init(providers: [ServiceProvider: ProviderGatewayPort]) {
        self.providers = providers
    }
    
    func gateway(for provider: ServiceProvider) throws -> ProviderGatewayPort {
        guard let gateway = providers[provider] else {
            throw ProviderGatewayRegistryError.missingAdapter(provider)
        }
        
        return gateway
    }
}
