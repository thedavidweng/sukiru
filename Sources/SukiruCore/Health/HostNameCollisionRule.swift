/// Same-name discovery entries in one host's loading scope. Unlike content
/// duplicates, these remain collisions when symlinks share a target.
public enum HostNameCollisionRule {
    public static let ruleID = "host-name-collision"

    public static func findings(
        groups: [SkillGroup], workspaces: [EnumeratedWorkspace], detectedHosts: Set<String>
    ) -> [Finding] {
        groups.compactMap { group in
            let scopes = workspaces.filter { $0.scopeGroup == group.scopeGroup }
            let hosts = Set(scopes.flatMap(\.candidateHosts)).sorted()
            let present = detectedHosts.union(
                scopes.filter { $0.workspace.id != $0.scopeGroup }.flatMap(\.candidateHosts))
            var evidence: [Evidence] = []
            var paths: Set<String> = []
            for host in hosts {
                let roots = loadingRoots(for: host, in: scopes, present: present.contains(host))
                let members = group.members.filter {
                    $0.placement.kind != .brokenSymlink && roots.contains($0.workspaceRoot)
                }
                let entries = Set(members.map { $0.placement.path })
                guard entries.count > 1 else { continue }
                // Claude Code explicitly deduplicates symlinks by target.
                let targets = Set(members.map { $0.placement.canonicalPath ?? $0.placement.path })
                if host == "claude-code", targets.count == 1 {
                    continue
                }
                evidence.append(Evidence(kind: "hostID", detail: host))
                paths.formUnion(entries)
            }
            guard !evidence.isEmpty else { return nil }
            evidence += paths.sorted().map { Evidence(kind: "memberPath", detail: $0) }
            return Finding(
                ruleID: ruleID, severity: .warning, skillName: group.name,
                workspaceID: group.scopeGroup, evidence: evidence)
        }
    }

    /// Installer destinations are not the full discovery set. Factory and
    /// OpenCode also read compatibility directories (see the rule's ADR).
    private static func loadingRoots(
        for host: String, in workspaces: [EnumeratedWorkspace], present: Bool
    ) -> Set<String> {
        Set(
            workspaces.filter { workspace in
                if workspace.candidateHosts.contains(host) { return true }
                guard present else { return false }
                switch host {
                case "droid":
                    return workspace.workspace.id == workspace.scopeGroup
                case "opencode":
                    return workspace.workspace.id == workspace.scopeGroup
                        || workspace.candidateHosts.contains("claude-code")
                default:
                    return false
                }
            }.map { $0.workspace.root })
    }
}
