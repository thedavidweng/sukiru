import SukiruCore
import SwiftUI

/// Plain-language names for the scan's detection rules, whose `ruleID`s are
/// stable wire tokens rather than UI copy.
extension Finding {
    var title: String {
        switch ruleID {
        case "lock-without-files": String(localized: "Lock entry without a skill folder")
        case "missing-shared-copy": String(localized: "Shared copy is missing")
        case "versioned-link-target": String(localized: "Link into a versioned folder")
        case "broken-symlink": String(localized: "Dead link")
        case "symlink-authenticity": String(localized: "Copy where a link belongs")
        case "canonical-host-divergence": String(localized: "Copies differ from the shared copy")
        case "vercel-lock-drift": String(localized: "Changed since it was installed")
        case "leftover-host-dir": String(localized: "Leftover folder of an uninstalled agent")
        case "files-without-lock": String(localized: "No known source")
        case "double-booked": String(localized: "Claimed by two installers")
        case "ambiguous-name": String(localized: "Different skills share this name")
        case HostNameCollisionRule.ruleID:
            String(localized: "Agent discovers this name more than once")
        case "lock-version-unsupported": String(localized: "Lock from a newer installer")
        case "dangerous-removal-surface": String(localized: "Removable by name")
        case LockWithoutFilesRule.companionRecordRuleID:
            String(localized: "gh record in the Vercel global lock")
        case "cross-host-duplicate": duplicateTitle
        default: ruleID
        }
    }

    private var duplicateTitle: String {
        switch evidence.first(where: { $0.kind == "subtype" })?.detail {
        case "exact": String(localized: "Identical copies instead of links")
        case "divergent": String(localized: "Copies disagree")
        default: String(localized: "Shared by several agents")
        }
    }

    /// What a note warns about. The Finding model has no message field, so
    /// the caution is spelled out here. A removal advisory names the skill
    /// twice: in the command and as what it would delete.
    var caution: String? {
        guard let name = skillName else { return nil }
        switch ruleID {
        case "dangerous-removal-surface":
            return String(localized: "danger.removal.advisory \(name) \(name)")
        case LockWithoutFilesRule.companionRecordRuleID:
            return String(localized: "note.githubCompanionRecord \(name)")
        default:
            return nil
        }
    }

    /// The severity the UI shows: a note never reads as needing action,
    /// whatever severity its rule carries on the wire.
    var displaySeverity: Severity {
        ProblemKind.of(self).isProblem ? severity : .info
    }
}
