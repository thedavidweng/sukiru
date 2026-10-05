import Foundation

/// One host and one concrete scope; names are frozen when the user queues it.
public struct HostRemovalRequest: Identifiable, Equatable, Sendable {
    public static let ruleID = "library-host-removal"
    public let hostID: String
    public let bucket: String
    public let names: [String]

    public init(hostID: String, bucket: String, names: [String]) {
        self.hostID = hostID
        self.bucket = bucket
        self.names = Array(Set(names)).sorted()
    }

    public var id: String { ([Self.ruleID, bucket, hostID] + names).joined(separator: "|") }
}

/// One discovery entry, kept separate even when several entries load one skill.
public struct HostRemovalEntry: Codable, Equatable, Sendable {
    public let name: String
    public let path: String
    public let sourceFolder: String

    init(name: String, path: String) {
        self.name = name
        self.path = path
        self.sourceFolder = URL(fileURLWithPath: path).deletingLastPathComponent().path
    }
}

public enum HostRemovalReason: String, Codable, Equatable, Sendable {
    case ownerless, githubLedger, agentManaged, ambiguous, sharedFolder, unofficialEntry

    public var text: String {
        switch self {
        case .ownerless: return "Ownerless Skill; queue its deletion from Health."
        case .githubLedger: return "GitHub Ledger skill; uninstall it individually."
        case .agentManaged: return "Agent-managed Skill; manage it in the host."
        case .ambiguous:
            return "Double-booked or ambiguous name; resolve ownership in Health first."
        case .sharedFolder:
            return
                "This folder is shared with other hosts; it cannot be cleared for this host alone."
        case .unofficialEntry:
            return "This entry was not installed by npx skills; resolve its placement in Health."
        }
    }
}

public struct HostRemovalKeptEntry: Codable, Equatable, Sendable {
    public let entry: HostRemovalEntry
    public let reason: HostRemovalReason
}

/// The same ordered preview serves CLI output and the Library confirmation.
public struct HostRemovalPlan: Codable, Equatable, Sendable {
    public let hostID: String
    public let bucket: String
    public let removed: [HostRemovalEntry]
    public let leftInPlace: [HostRemovalKeptEntry]
    public let stillVisible: [HostRemovalEntry]
    public let sharedCopyDeletions: [String]
    public let predictionUncertain: Bool
    public let settingHint: String?
    public let problems: [String]

    public var request: HostRemovalRequest {
        HostRemovalRequest(hostID: hostID, bucket: bucket, names: removed.map(\.name))
    }
}
