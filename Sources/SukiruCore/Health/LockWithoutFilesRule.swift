/// `lock-without-files` (action): a lock entry whose name has no healthy
/// placement in its scope — the ledger claim alone conjures no skill. A
/// broken-symlink-only name counts as fileless (a dangling link is not a
/// healthy placement); incompatible-version locks never reach this rule
/// because the reader drops their claims entirely.
///
/// `github-companion-record` (info) replaces it for gh's companion record
/// of a skill whose files exist only in projects: gh rewrites the record on
/// every install or update of that skill, and only a bare
/// `npx skills update -g` acts on it (it would install the skill at user
/// scope), so it is a note, never a stale entry to remove.
public enum LockWithoutFilesRule {
    static let ruleID = "lock-without-files"
    /// The info-level rule ID the app presents as a note.
    public static let companionRecordRuleID = "github-companion-record"

    /// One finding per fileless lock entry: the companion note when gh's
    /// signature and a gh-provenanced placement attribute the record to a
    /// project install, the stale-entry finding otherwise.
    static func findings(locks: [ScopeLockClaim], groups: [SkillGroup]) -> [Finding] {
        var healthy: Set<String> = []
        var githubSkillFiles: [String: [String]] = [:]
        for group in groups {
            let hasFiles = group.members.contains { $0.placement.kind != .brokenSymlink }
            if hasFiles {
                healthy.insert(group.scopeGroup + "\u{1F}" + group.name)
            }
            for member in group.members where member.githubProvenance != nil {
                githubSkillFiles[group.name, default: []].append(member.skillFilePath)
            }
        }
        var findings: [Finding] = []
        for claim in locks {
            for name in claim.lock.entries.keys.sorted() {
                if healthy.contains(claim.scopeGroup + "\u{1F}" + name) {
                    continue
                }
                var evidence: [Evidence] = []
                if let lockPath = claim.lockPath {
                    evidence.append(Evidence(kind: "lockPath", detail: lockPath))
                }
                evidence.append(Evidence(kind: "entryKey", detail: name))
                if let files = companionSkillFiles(named: name, claim: claim, githubSkillFiles) {
                    evidence += files.sorted().map { Evidence(kind: "skillMdPath", detail: $0) }
                    findings.append(
                        Finding(
                            ruleID: companionRecordRuleID, severity: .info,
                            skillName: name, workspaceID: claim.scopeGroup, evidence: evidence))
                    continue
                }
                findings.append(
                    Finding(
                        ruleID: ruleID, severity: .action, skillName: name,
                        workspaceID: claim.scopeGroup, evidence: evidence))
            }
        }
        return findings
    }

    /// The gh-provenanced SKILL.md paths attributing a companion record to
    /// a project install; nil when the entry is not gh-signed or no gh
    /// placement of the name exists anywhere.
    private static func companionSkillFiles(
        named name: String, claim: ScopeLockClaim, _ githubSkillFiles: [String: [String]]
    ) -> [String]? {
        guard claim.lock.scope == .global,
            claim.lock.entries[name]?.isGitHubCompanion == true
        else { return nil }
        return githubSkillFiles[name]
    }
}
