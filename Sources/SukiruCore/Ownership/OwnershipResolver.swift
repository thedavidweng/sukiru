/// A scope's Vercel lock claim, as read by `VercelLockReader`, paired with
/// the ownership bucket it applies to.
///
/// The bucket key is `user` for the global (v3) lock and `project:<root>` for
/// each project (v1) lock — resolution is independent per project root and
/// per user scope, with no cross-scope leakage (architecture §6, VAL-SCAN-055).
public struct ScopeLockClaim: Equatable, Sendable {
    /// The ownership bucket this lock governs (`user` / `project:<root>`).
    public let scopeGroup: String
    /// The lock file path, when one exists on disk (evidence for findings).
    public let lockPath: String?
    /// The parsed lock (an incompatible-version lock arrives as no claim at
    /// all — the reader returns nil and the scope resolves from disk alone).
    public let lock: VercelLock

    public init(scopeGroup: String, lockPath: String?, lock: VercelLock) {
        self.scopeGroup = scopeGroup
        self.lockPath = lockPath
        self.lock = lock
    }
}

/// The resolver's full output: the D18 skills plus the findings ownership
/// resolution itself raises.
public struct OwnershipResolution: Equatable, Sendable {
    /// Resolved logical skills, in `SkillInventory` group order.
    public let skills: [Skill]
    /// `ambiguous-name`, `double-booked`, and `files-without-lock` findings.
    /// HealthAnalyzer owns the remaining rules and must NOT re-emit these
    /// (same origin pattern as InventoryScanner's `broken-symlink`).
    public let findings: [Finding]

    public init(skills: [Skill], findings: [Finding]) {
        self.skills = skills
        self.findings = findings
    }
}

/// Resolves per-skill ownership from the two ledgers plus disk facts
/// (architecture §6, D1).
///
/// For skill name N in scope S: `v` = N has an entry in S's Vercel lock;
/// `g` = any placement of N in S carries `metadata.github-repo`.
/// v∧g → double-booked, v∧¬g → vercel, ¬v∧g → github, ¬v∧¬g → ownerless.
/// When N is ambiguous (the D23 refined trigger — the scope's UNEXPLAINED
/// placements hold ≥2 distinct content hashes, computed by `SkillInventory`
/// after alias collapse), attribution is VOIDED: ownership reports ownerless
/// with `ambiguous: true`, never a guess — while the ledger claims stay
/// surfaced in `provenance` as non-authoritative data (VAL-SCAN-018).
///
/// The resolver also emits the findings only ownership data can produce:
/// `ambiguous-name` (warning, one placementPath per colliding directory),
/// `double-booked` (action, two-sided evidence: lockPath + entryKey +
/// skillMdPath + githubRepo), and `files-without-lock` (info, the ownerless
/// inventory listing, one placementPath per real placement). A name whose
/// only placements are broken symlinks is ownerless but NOT listed — the
/// broken-symlink finding already covers it and there are no files to list.
public struct OwnershipResolver: Sendable {
    public init() {}

    /// Resolves every group against its scope's lock claim.
    public func resolve(groups: [SkillGroup], locks: [ScopeLockClaim]) -> OwnershipResolution {
        var claims: [String: ScopeLockClaim] = [:]
        for claim in locks {
            claims[claim.scopeGroup] = claim
        }
        var skills: [Skill] = []
        var findings: [Finding] = []
        for group in groups {
            let claim = claims[group.scopeGroup]
            let entry = claim?.lock.entries[group.name]
            // Members are path-sorted, so the first placement carrying a gh
            // claim is a deterministic choice when several carry one.
            let ghPlacement = group.members.first { $0.githubProvenance != nil }
            let ownership = Self.ownership(
                ambiguous: group.ambiguous, vercelClaim: entry != nil,
                githubClaim: ghPlacement != nil)
            let provenance = SkillProvenance(
                vercel: entry.map {
                    VercelProvenance(entry: $0, scope: claim?.lock.scope ?? .global)
                },
                github: ghPlacement?.githubProvenance
            )
            skills.append(
                Skill(
                    name: group.name,
                    scope: group.scopeGroup == "user" ? .user : .project,
                    ownership: ownership,
                    ambiguous: group.ambiguous,
                    provenance: provenance,
                    placements: group.members.map(\.placement)
                ))
            findings.append(
                contentsOf: groupFindings(
                    for: group, ownership: ownership, claim: claim, ghPlacement: ghPlacement))
        }
        return OwnershipResolution(skills: skills, findings: findings)
    }

    /// The §6 truth table. Ambiguity voids attribution first (D1): an
    /// ambiguous name is treated as ownerless, never guessed.
    static func ownership(ambiguous: Bool, vercelClaim: Bool, githubClaim: Bool) -> Ownership {
        if ambiguous {
            return .ownerless
        }
        switch (vercelClaim, githubClaim) {
        case (true, true):
            return .doubleBooked
        case (true, false):
            return .vercel
        case (false, true):
            return .github
        case (false, false):
            return .ownerless
        }
    }

    /// The findings one resolved group raises. Scope-level findings anchor to
    /// the scope's canonical workspace: the bucket key IS that workspace's id
    /// (`user` / `project:<root>`).
    private func groupFindings(
        for group: SkillGroup,
        ownership: Ownership,
        claim: ScopeLockClaim?,
        ghPlacement: DiscoveredPlacement?
    ) -> [Finding] {
        let workspaceID = group.scopeGroup
        if group.ambiguous {
            return [ambiguousFinding(group: group, workspaceID: workspaceID)]
        }
        if ownership == .doubleBooked, let ghPlacement {
            return [
                doubleBookedFinding(
                    group: group, claim: claim, ghPlacement: ghPlacement,
                    workspaceID: workspaceID)
            ]
        }
        if ownership == .ownerless {
            return filesWithoutLockFinding(group: group, workspaceID: workspaceID).map { [$0] }
                ?? []
        }
        return []
    }

    /// `ambiguous-name` (warning): one placementPath per DISTINCT canonical
    /// path (D1), the first path-sorted member standing in for each.
    private func ambiguousFinding(group: SkillGroup, workspaceID: String) -> Finding {
        var seen: Set<String> = []
        var evidence: [Evidence] = []
        for member in group.members {
            guard let canonical = member.placement.canonicalPath, seen.insert(canonical).inserted
            else { continue }
            evidence.append(Evidence(kind: "placementPath", detail: member.placement.path))
        }
        return Finding(
            ruleID: "ambiguous-name",
            severity: .warning,
            skillName: group.name,
            workspaceID: workspaceID,
            evidence: evidence
        )
    }

    /// `double-booked` (action): two-sided evidence — the lock (path + entry
    /// key) and the frontmatter claim (SKILL.md path + github-repo value).
    private func doubleBookedFinding(
        group: SkillGroup,
        claim: ScopeLockClaim?,
        ghPlacement: DiscoveredPlacement,
        workspaceID: String
    ) -> Finding {
        var evidence: [Evidence] = []
        if let lockPath = claim?.lockPath {
            evidence.append(Evidence(kind: "lockPath", detail: lockPath))
        }
        evidence.append(Evidence(kind: "entryKey", detail: group.name))
        evidence.append(Evidence(kind: "skillMdPath", detail: ghPlacement.skillFilePath))
        if let repo = ghPlacement.githubProvenance?.repo {
            evidence.append(Evidence(kind: "githubRepo", detail: repo))
        }
        return Finding(
            ruleID: "double-booked",
            severity: .action,
            skillName: group.name,
            workspaceID: workspaceID,
            evidence: evidence
        )
    }

    /// `files-without-lock` (info): the ownerless inventory listing, one
    /// placementPath per real placement. Nil when the name has no readable
    /// content at all (broken-symlink-only names are covered elsewhere).
    private func filesWithoutLockFinding(group: SkillGroup, workspaceID: String) -> Finding? {
        let evidence = group.members
            .filter { $0.placement.kind != .brokenSymlink }
            .map { Evidence(kind: "placementPath", detail: $0.placement.path) }
        guard !evidence.isEmpty else { return nil }
        return Finding(
            ruleID: "files-without-lock",
            severity: .info,
            skillName: group.name,
            workspaceID: workspaceID,
            evidence: evidence
        )
    }
}
