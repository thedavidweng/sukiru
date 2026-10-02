/// `missing-shared-copy` (action): the Vercel lock claims a skill and some
/// agent still sees it, but the scope's shared skills folder holds no copy.
/// Every remaining placement is a copy an agent made itself or a link into
/// another manager's folder, so `npx skills update` has nothing to refresh
/// and the lock no longer describes the disk.
///
/// A copy-mode install also leaves the shared folder empty, but its host
/// copies are the installer's own (not agent-managed), so it never
/// qualifies. A name with no healthy placement at all is
/// `lock-without-files`, not this rule.
enum MissingSharedCopyRule {
    static let ruleID = "missing-shared-copy"

    static func finding(for group: SkillGroup, claim: ScopeLockClaim?) -> Finding? {
        guard let claim, let entry = claim.vercelClaim(for: group) else { return nil }
        let healthy = group.members.filter { $0.placement.kind != .brokenSymlink }
        guard !healthy.isEmpty,
            !healthy.contains(where: { $0.workspaceID == group.scopeGroup }),
            healthy.allSatisfy({
                $0.placement.kind == .symlink || $0.placement.managingAgent != nil
            })
        else { return nil }
        var evidence: [Evidence] = []
        if let lockPath = claim.lockPath {
            evidence.append(Evidence(kind: "lockPath", detail: lockPath))
        }
        evidence.append(Evidence(kind: "entryKey", detail: group.name))
        if let source = entry.source, !source.isEmpty {
            evidence.append(Evidence(kind: "source", detail: source))
        }
        evidence += healthy.map { Evidence(kind: "placementPath", detail: $0.placement.path) }
        return Finding(
            ruleID: ruleID, severity: .action, skillName: group.name,
            workspaceID: group.scopeGroup, evidence: evidence)
    }
}
