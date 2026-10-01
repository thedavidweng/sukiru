import SukiruCore
import SwiftUI

/// Localized labels for the scan and diff vocabularies, whose raw values are
/// stable wire tokens rather than UI copy. Free-form parser and diff details
/// stay verbatim beside these labels as technical detail.
extension Severity {
    var title: LocalizedStringResource {
        switch self {
        case .action: "Action Needed"
        case .warning: "Warning"
        case .info: "Info"
        }
    }
}

enum IssuePresentation {
    static func title(forKind kind: String) -> String {
        switch kind {
        case IssueKind.skillMDInvalid: String(localized: "Invalid SKILL.md")
        case IssueKind.skillMDUnreadable: String(localized: "Unreadable SKILL.md")
        case IssueKind.ledgerUnreadable: String(localized: "Unreadable lock file")
        case IssueKind.lockVersionUnsupported: String(localized: "Unsupported lock file version")
        case IssueKind.contentHashUnreadable: String(localized: "Unreadable skill content")
        case IssueKind.brokenSymlink: String(localized: "Broken link")
        case IssueKind.directoryUnreadable: String(localized: "Unreadable folder")
        case IssueKind.canonicalPathUnreadable: String(localized: "Unresolvable path")
        default: kind
        }
    }
}

enum EvidencePresentation {
    private static let labels: [String: LocalizedStringResource] = [
        "actualHash": "Actual hash",
        "expectedHash": "Expected hash",
        "contentHash": "Content hash",
        "canonicalPath": "Resolved path",
        "entryKey": "Lock entry",
        "foundVersion": "Found version",
        "supportedVersion": "Supported version",
        "githubRepo": "GitHub repository",
        "hostPath": "Agent folder",
        "hosts": "Agents",
        "linkCount": "Links",
        "skillsDir": "Skills folder",
        "impostorPath": "Conflicting copy",
        "linkPath": "Link",
        "linkTarget": "Link target",
        "lockPath": "Lock file",
        "memberPath": "Copy",
        "placementPath": "Location",
        "skillName": "Skill",
        "ownership": "Owner",
        "source": "Source",
        "sourceIdentity": "Source",
        "subtype": "Kind"
    ]

    /// Unknown kinds (and `skillMdPath`, a file name) show as-is.
    static func label(forKind kind: String) -> String {
        labels[kind].map { String(localized: $0) } ?? (kind == "skillMdPath" ? "SKILL.md" : kind)
    }

    /// Ownership verdicts are wire tokens and show as their Library label;
    /// every other detail (paths, hashes, names) shows as-is.
    static func detail(of evidence: Evidence) -> String {
        guard evidence.kind == "ownership", let ownership = Ownership(rawValue: evidence.detail)
        else { return evidence.detail }
        return String(localized: ownership.title)
    }
}

extension DiffEntry.Kind {
    var title: LocalizedStringResource {
        switch self {
        case .placementAdded: "Skill folder added"
        case .placementRemoved: "Skill folder removed"
        case .placementChanged: "Skill folder changed"
        case .fileAdded: "File added"
        case .fileRemoved: "File removed"
        case .fileChanged: "File changed"
        case .lockEntryAdded: "Lock entry added"
        case .lockEntryRemoved: "Lock entry removed"
        case .lockEntryChanged: "Lock entry changed"
        }
    }

    var symbol: String {
        switch self {
        case .placementAdded, .fileAdded, .lockEntryAdded: "plus.circle"
        case .placementRemoved, .fileRemoved, .lockEntryRemoved: "minus.circle"
        case .placementChanged, .fileChanged, .lockEntryChanged: "pencil.circle"
        }
    }
}
