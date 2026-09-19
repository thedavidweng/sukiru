import Foundation

/// HTTP capabilities needed by the Search milestone (stories 22/24).
///
/// The scan/repair core is offline-deterministic by contract; search is the
/// ONE network surface (§8: "may fetch remote metadata"), and it is
/// strictly read-only — a marketplace query or a raw SKILL.md fetch never
/// writes anything. The transport is injectable so core tests stay fully
/// offline (stub transports return fixture payloads).
public protocol MarketplaceTransport: Sendable {
    /// Fetches the URL and returns the body. Throws on any transport error
    /// (unreachable, non-2xx, malformed body). Never returns partial data.
    func fetch(_ url: URL) async throws -> Data
}

/// The real URLSession-backed transport: `GET`, `Accept: application/json`,
/// a bounded timeout, and CI/telemetry hygiene matching the CLI probes.
public struct URLSessionMarketplaceTransport: MarketplaceTransport {
    /// Seconds before a marketplace fetch is abandoned. Search should feel
    /// responsive; the app renders a failure state, never a hang.
    public static let defaultTimeout: TimeInterval = 20

    private let session: URLSession
    private let timeout: TimeInterval

    public init(
        session: URLSession = .shared,
        timeout: TimeInterval = URLSessionMarketplaceTransport.defaultTimeout
    ) {
        self.session = session
        self.timeout = timeout
    }

    public func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Probes stay hermetic and non-interactive (same discipline as the
        // CLI child environment).
        request.setValue("sukiru/1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MarketplaceError.transport("not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MarketplaceError.transport("HTTP \(http.statusCode)")
        }
        return data
    }
}

/// Search/preview failures, always surfaced to the user, never swallowed
/// (malformed data is a reported issue, never a crash — §2).
public enum MarketplaceError: Error, Equatable, Sendable {
    case transport(String)
    /// The response body did not decode into the expected shape.
    case malformed(String)

    /// Human-readable refusal/diagnostic (English by design, like stderr).
    public var message: String {
        switch self {
        case .transport(let detail):
            return "marketplace request failed: \(detail)"
        case .malformed(let detail):
            return "marketplace response was malformed: \(detail)"
        }
    }
}
