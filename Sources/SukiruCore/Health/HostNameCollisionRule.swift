/// Same-name discovery entries in one host's loading scope. Unlike content
/// duplicates, these remain collisions when symlinks share a target.
///
/// The `subtype` evidence says what the user can do (ADR 0009):
/// - `distinct`: a host sees entries backed by different folders, so it
///   loads one definition and ignores the rest; the user keeps one.
/// - `redundant`: every entry is one folder, but a host that reports such
///   aliases sees them. `redundantPath` lists the links in that host's own
///   skills folder; deleting them loses nothing, since the host still reads
///   the shared entry.
/// - `alias`: every entry is one folder and no host involved reports it, so
///   each host loads the same files. A note, not a problem.
public enum HostNameCollisionRule {
    public static let ruleID = "host-name-collision"

    public enum Subtype: String, Sendable {
        case distinct
        case redundant
        case alias
    }

    /// Hosts that report same-target aliases as duplicate definitions.
    /// Droid's startup diagnostics list them; Claude Code deduplicates them.
    public static let aliasReportingHosts: Set<String> = ["droid"]

    public static func subtype(of finding: Finding) -> Subtype? {
        guard finding.ruleID == ruleID else { return nil }
        return finding.evidence.first { $0.kind == "subtype" }
            .flatMap { Subtype(rawValue: $0.detail) }
    }

    public static func findings(
        groups: [SkillGroup], workspaces: [EnumeratedWorkspace], detectedHosts: Set<String>
    ) -> [Finding] {
        groups.compactMap { group in
            let scopes = workspaces.filter { $0.scopeGroup == group.scopeGroup }
            let hosts = Set(scopes.flatMap(\.candidateHosts)).sorted()
            let present = detectedHosts.union(
                scopes.filter { $0.workspace.id != $0.scopeGroup }.flatMap(\.candidateHosts))
            var hostEvidence: [Evidence] = []
            var paths: Set<String> = []
            var redundant: Set<String> = []
            var subtype = Subtype.alias
            for host in hosts {
                let roots = loadingRoots(for: host, in: scopes, present: present.contains(host))
                let members = group.members.filter {
                    $0.placement.kind != .brokenSymlink && roots.contains($0.workspaceRoot)
                }
                let entries = Set(members.map { $0.placement.path })
                guard entries.count > 1 else { continue }
                let targets = Set(members.map(target))
                // Claude Code explicitly deduplicates symlinks by target.
                if host == "claude-code", targets.count == 1 {
                    continue
                }
                hostEvidence.append(Evidence(kind: "hostID", detail: host))
                paths.formUnion(entries)
                if targets.count > 1 {
                    subtype = .distinct
                } else if aliasReportingHosts.contains(host) {
                    if subtype == .alias { subtype = .redundant }
                    redundant.formUnion(
                        redundantLinks(members, ownRoots: ownRoots(of: host, in: scopes)))
                }
            }
            guard !hostEvidence.isEmpty else { return nil }
            var evidence = [Evidence(kind: "subtype", detail: subtype.rawValue)] + hostEvidence
            evidence += paths.sorted().map { Evidence(kind: "memberPath", detail: $0) }
            if subtype == .redundant {
                evidence += redundant.sorted().map { Evidence(kind: "redundantPath", detail: $0) }
            }
            return Finding(
                ruleID: ruleID, severity: subtype == .alias ? .info : .warning,
                skillName: group.name, workspaceID: group.scopeGroup, evidence: evidence)
        }
    }

    private static func target(_ member: DiscoveredPlacement) -> String {
        member.placement.canonicalPath ?? member.placement.path
    }

    /// Links in the host's own folder, all resolving to one target. One
    /// entry always survives, so the host keeps loading the skill.
    private static func redundantLinks(
        _ members: [DiscoveredPlacement], ownRoots: Set<String>
    ) -> [String] {
        let links = members.filter {
            $0.placement.kind == .symlink && ownRoots.contains($0.workspaceRoot)
        }.map(\.placement.path).sorted()
        let all = Set(members.map(\.placement.path))
        return Set(links) == all ? Array(links.dropFirst()) : links
    }

    /// Skills folders only this host reads, never the shared store: deleting
    /// an entry there cannot hide the skill from another host.
    private static func ownRoots(
        of host: String, in workspaces: [EnumeratedWorkspace]
    ) -> Set<String> {
        Set(
            workspaces.filter {
                $0.workspace.id != $0.scopeGroup && $0.candidateHosts == [host]
            }.map(\.workspace.root))
    }

    /// Installer destinations are not the full discovery set. Factory and
    /// OpenCode also read compatibility directories (see the rule's ADR).
    static func loadingRoots(
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
