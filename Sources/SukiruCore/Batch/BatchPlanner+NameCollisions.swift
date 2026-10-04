import Foundation

/// `host-name-collision` repairs (ADR 0009): deleting redundant aliases a
/// host reports, and keeping one of several different folders.
extension CommandBatchBuilder {
    /// Deletes the links the rule marked redundant. Each resolves to an
    /// entry the same host still reads, so no definition is lost.
    func redundantEntryCommands(
        entry: DecisionEntry, finding: Finding
    ) throws -> [BatchCommand] {
        let paths = finding.evidence.filter { $0.kind == "redundantPath" }.map(\.detail)
        guard !paths.isEmpty else {
            throw DecisionProblem(
                message: "finding '\(entry.findingID)' (\(finding.ruleID)) has no redundant "
                    + "link to remove; choose which entry to keep instead")
        }
        let name = finding.skillName ?? finding.ruleID
        return paths.map { path in
            BatchCommandFactory.deleteLink(
                name: name, path: path,
                intent: "Delete the redundant link '\(path)' (finding \(finding.ruleID)): "
                    + "the agent also reads the folder it points to.")
        }
    }

    /// Keeps the chosen entry and deletes every entry backed by another
    /// folder. Entries resolving to the kept folder stay: other agents may
    /// load the skill through them.
    func keepEntryCommands(
        entry: DecisionEntry, finding: Finding, report: ScanReport
    ) throws -> [BatchCommand] {
        guard case .keepEntry(let kept) = entry.choice else {
            throw DecisionProblem(
                message: "arbitrate on finding '\(entry.findingID)' (\(finding.ruleID)) "
                    + "requires choice {\"keep\": \"<entry path>\"}")
        }
        guard HostNameCollisionRule.subtype(of: finding) == .distinct else {
            throw DecisionProblem(
                message: "finding '\(entry.findingID)': every entry is the same folder, so "
                    + "there is nothing to choose")
        }
        let members = finding.evidence.filter { $0.kind == "memberPath" }.map(\.detail)
        guard members.contains(kept) else {
            throw DecisionProblem(
                message: "'\(kept)' is not an entry of finding '\(entry.findingID)'")
        }
        let located = try members.map { try locate($0, report: report, entry: entry) }
        let keptTarget = located.first { $0.placement.path == kept }.map(Self.target)
        let removed = located.filter { Self.target($0) != keptTarget }
        try requireNoDanglingLinks(after: removed, report: report)
        let links = removed.filter { $0.placement.kind == .symlink }
        let folders = removed.filter { $0.placement.kind == .directory }
        return try (links + folders).map { try removal(of: $0, keeping: kept, finding: finding) }
    }

    private typealias Located = (skill: Skill, placement: Placement)

    private static func target(_ located: Located) -> String {
        located.placement.canonicalPath ?? located.placement.path
    }

    private func locate(
        _ path: String, report: ScanReport, entry: DecisionEntry
    ) throws -> Located {
        for skill in report.skills {
            if let placement = skill.placements.first(where: { $0.path == path }) {
                return (skill, placement)
            }
        }
        throw DecisionProblem(
            message: "entry '\(path)' (finding '\(entry.findingID)') is no longer in the scan")
    }

    /// A link elsewhere into a deleted folder would turn into a dead link.
    private func requireNoDanglingLinks(after removed: [Located], report: ScanReport) throws {
        let removedPaths = Set(removed.map(\.placement.path))
        let folders = Set(removed.filter { $0.placement.kind == .directory }.map(Self.target))
        for skill in report.skills {
            for placement in skill.placements
            where placement.kind == .symlink && !removedPaths.contains(placement.path) {
                guard let target = placement.canonicalPath, folders.contains(target) else {
                    continue
                }
                throw DecisionProblem(
                    message: "'\(placement.path)' links to '\(target)'; deleting that folder "
                        + "would leave a dead link")
            }
        }
    }

    private func removal(
        of located: Located, keeping kept: String, finding: Finding
    ) throws -> BatchCommand {
        let (skill, placement) = located
        let intent =
            "Delete '\(placement.path)' and keep '\(kept)' (finding \(finding.ruleID)): the "
            + "agent loads only one definition of '\(skill.name)'."
        if placement.kind == .symlink {
            return BatchCommandFactory.deleteLink(
                name: skill.name, path: placement.path, intent: intent)
        }
        if let agent = placement.managingAgent ?? skill.managingAgent {
            throw DecisionProblem(
                message: "'\(placement.path)' is managed by \(agent) through its own ledger; "
                    + "remove it in that agent")
        }
        switch skill.ownership {
        case .ownerless:
            return BatchCommandFactory.ownerlessCleanups(
                name: skill.name, paths: [placement.path], finding: finding)[0]
        case .github:
            return BatchCommandFactory.deleteGitHubSkillDirectory(
                name: skill.name, path: placement.path, intent: intent)
        case .vercel, .doubleBooked, .agent:
            // npx skills removes by name, which would delete the kept entry too.
            throw DecisionProblem(
                message: "'\(placement.path)' belongs to '\(skill.name)', which the "
                    + "\(skill.ownership.rawValue) ledger owns; remove it with its installer")
        }
    }
}
