import Foundation

@testable import SukiruCore

/// Offline marketplace test transport: answers URL fetches from a fixed
/// table keyed by absolute URL string, throwing for anything else. The
/// search network surface stays testable without the network (tests stay
/// offline and deterministic).
struct StubMarketplaceTransport: MarketplaceTransport {
    let responses: [String: Result<Data, MarketplaceError>]

    init(responses: [String: Result<Data, MarketplaceError>] = [:]) {
        self.responses = responses
    }

    func fetch(_ url: URL) async throws -> Data {
        guard let response = responses[url.absoluteString] else {
            throw MarketplaceError.transport("no stub for \(url.absoluteString)")
        }
        return try response.get()
    }
}
