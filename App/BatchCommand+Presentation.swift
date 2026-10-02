import Foundation
import SukiruCore

/// Localized review copy for batch commands. Core keeps English prose for
/// batch files and the CLI; the app renders the same facts from the
/// command's structure (argv, danger flags, consequence kind) instead.
extension BatchCommand {
    /// The danger and consequence notes the user reviews before running.
    var reviewNotes: [String] {
        var notes: [String] = []
        if let warning = localizedWarning ?? warning {
            notes.append(warning)
        }
        if let consequence = consequenceKind.map(\.localizedText) ?? consequence {
            notes.append(consequence)
        }
        return notes
    }

    private var localizedWarning: String? {
        if dangerFlags.contains(.dangerousDeletion), argv.count > 3 {
            let name = argv[3]
            return atRiskSkills.isEmpty
                ? String(localized: "command.warning.removeByName \(name)")
                : String(localized: "command.warning.removeByNameAtRisk \(name)")
        }
        switch fileOperation {
        case .deleteDirectory:
            return dangerFlags.contains(.ownerlessCleanup)
                ? String(localized: "command.warning.deleteOwnerless")
                : String(localized: "command.warning.deleteGitHubSkill")
        case .deleteLink:
            return String(localized: "command.warning.deleteLink")
        case .relink:
            return dangerFlags.contains(.discardsLocalChanges)
                ? String(localized: "command.warning.relinkDiverged")
                : String(localized: "command.warning.relink")
        case .materialize:
            return String(localized: "command.warning.materialize")
        case .removeLeftoverSkillsDir:
            return String(localized: "command.warning.removeLeftover")
        case nil:
            return nil
        }
    }

    /// The at-risk skills as a locale-formatted list ("a (GitHub) and b
    /// (Ownerless)").
    var atRiskList: String {
        atRiskSkills.map { skill in
            let owner = Ownership(rawValue: skill.ownership).map { String(localized: $0.title) }
            return owner.map { String(localized: "\(skill.skill) (\($0))") } ?? skill.skill
        }
        .formatted(.list(type: .and))
    }
}

extension FileOperation {
    /// A plain-language line for the operation; CLI commands show their
    /// exact command line instead.
    var localizedSummary: String {
        switch self {
        case .deleteDirectory(let path):
            return String(localized: "Delete the folder \(Self.display(path))")
        case .deleteLink(let path):
            return String(localized: "Delete the link \(Self.display(path))")
        case .relink(let path, let target):
            return String(
                localized: "Link \(Self.display(path)) to \(Self.display(target))",
                comment: "Direct file operation: the first path becomes a link to the second.")
        case .materialize(let path):
            return String(localized: "Replace the link \(Self.display(path)) with a copy")
        case .removeLeftoverSkillsDir(let path):
            return String(localized: "Remove the leftover folder \(Self.display(path))")
        }
    }

    private static func display(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

extension CommandConsequence {
    var localizedText: String {
        switch self {
        case .resetsToUpstream:
            return String(localized: "consequence.resetsToUpstream")
        case .resetsToUpstreamErasingGitHubProvenance:
            return String(localized: "consequence.resetsToUpstreamErasingGitHubProvenance")
        case .resetsToGitHubRef:
            return String(localized: "consequence.resetsToGitHubRef")
        case .mergeOverwritesCollidingFiles:
            return String(localized: "consequence.mergeOverwritesCollidingFiles")
        case .replacesCopiesWithSharedLinks:
            return String(localized: "consequence.replacesCopiesWithSharedLinks")
        case .removesOnlyStaleLockEntry(let skill):
            return String(localized: "consequence.removesOnlyStaleLockEntry \(skill)")
        case .restoresSharedCopy(let paths):
            return String(localized: "consequence.restoresSharedCopy \(Self.list(paths))")
        case .removesLockedSkill(let skill, let paths):
            return String(localized: "consequence.removesLockedSkill \(skill) \(Self.list(paths))")
        case .entersVercelLedger:
            return String(localized: "consequence.entersVercelLedger")
        case .writesGitHubProvenance(let agent, let pinRef):
            if let pinRef, !pinRef.isEmpty {
                return String(
                    localized: "consequence.writesGitHubProvenancePinned \(agent) \(pinRef)")
            }
            return String(localized: "consequence.writesGitHubProvenance \(agent)")
        }
    }

    private static func list(_ paths: [String]) -> String {
        paths.map { ($0 as NSString).abbreviatingWithTildeInPath }.formatted(.list(type: .and))
    }
}
