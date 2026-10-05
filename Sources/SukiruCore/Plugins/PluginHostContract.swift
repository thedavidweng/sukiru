import Foundation

/// The verified host interface a reported version maps to. A release at or
/// above a verified baseline within the same major version is accepted; each
/// command's `--help` flag check still fails closed if a later release
/// changes the interface.
enum PluginHostContract: Equatable {
    case claude
    case codex
    case openCodeV1
    case openCodeV2

    private struct Baseline {
        let host: PluginHost
        let version: [Int]
        let contract: PluginHostContract
    }

    private static let baselines = [
        Baseline(host: .claude, version: [2, 1, 288], contract: .claude),
        Baseline(host: .codex, version: [0, 160, 0], contract: .codex),
        Baseline(host: .opencode, version: [1, 18, 34], contract: .openCodeV1),
        Baseline(host: .opencode, version: [2, 0, 22], contract: .openCodeV2)
    ]

    init?(host: PluginHost, version: String) {
        guard let reported = Self.components(version),
            let match = Self.baselines.first(where: { baseline in
                baseline.host == host && baseline.version[0] == reported[0]
                    && !reported.lexicographicallyPrecedes(baseline.version)
            })
        else { return nil }
        self = match.contract
    }

    static func unverified(host: PluginHost, version: String, name: String) -> String {
        let verified = baselines.filter { $0.host == host }
            .map { $0.version.map(String.init).joined(separator: ".") + "+" }
            .joined(separator: " or ")
        return "\(name) \(version) has no verified lifecycle contract "
            + "(verified: \(verified) within the same major); use the host."
    }

    private static func components(_ version: String) -> [Int]? {
        let core = (version.hasPrefix("v") ? version.dropFirst() : version[...])
            .prefix { $0.isNumber || $0 == "." }
        let parts = core.split(separator: ".").compactMap { Int($0) }
        return parts.count == 3 ? parts : nil
    }
}
