import Foundation

protocol MediaResolverPort: Sendable {
    func resolveMedia(_ refs: [InboundMediaRef]) async throws -> [ResolvedMedia]
}
