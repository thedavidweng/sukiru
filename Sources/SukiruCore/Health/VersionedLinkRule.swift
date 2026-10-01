/// `versioned-link-target` (info): a link whose own target path names a
/// version folder (`…/Versions/0.5.1.13/…`, `…/Cellar/foo/1.2.3/…`). When
/// the app or package updates, that folder goes away and the link dies.
/// Only the link's literal target counts: a link through a stable pointer
/// the updater rewrites (`~/.local/share/<app>/current`) stays silent even
/// when the pointer itself resolves into a version folder.
enum VersionedLinkRule {
    static let ruleID = "versioned-link-target"

    static func finding(for group: SkillGroup) -> Finding? {
        var evidence: [Evidence] = []
        var targets: Set<String> = []
        for member in group.members where member.placement.kind == .symlink {
            guard let target = member.placement.linkTarget, versionComponent(of: target) != nil
            else { continue }
            if targets.insert(target).inserted {
                evidence.append(Evidence(kind: "linkTarget", detail: target))
            }
            evidence.append(Evidence(kind: "linkPath", detail: member.placement.path))
        }
        guard !evidence.isEmpty else { return nil }
        return Finding(
            ruleID: ruleID, severity: .info, skillName: group.name,
            workspaceID: group.scopeGroup, evidence: evidence)
    }

    /// The first path component shaped like a release version (`1.2`,
    /// `v20.11.0`, `0.5.1.13`), or nil.
    static func versionComponent(of path: String) -> String? {
        path.split(separator: "/").map(String.init).first { component in
            let digits = component.hasPrefix("v") ? component.dropFirst() : Substring(component)
            let parts = digits.split(separator: ".", omittingEmptySubsequences: false)
            return (2...4).contains(parts.count)
                && parts.allSatisfy {
                    !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber)
                }
        }
    }
}
