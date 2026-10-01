import Foundation

/// The seam-A health rules (architecture §5, D3) that neither the inventory
/// scanner nor the ownership resolver can own.
///
/// Origin boundaries (library/read-side-porting.md):
/// - `broken-symlink` findings originate in `InventoryScanner`;
/// - `ambiguous-name`, `double-booked`, and `files-without-lock` originate in
///   `OwnershipResolver`.
///
/// This analyzer consumes groups + lock claims and NEVER re-emits those. It
/// owns:
/// - `cross-host-duplicate` (subtypes `alias` info / `exact` warning /
///   `divergent` warning) — ports the archive's `AliasDuplicate` /
///   `ExactDuplicate` classes (port-reference §4), grouped PER OWNERSHIP
///   BUCKET: project and user scopes are governed separately (spec story 10),
///   so a name present once per scope is not a duplicate.
/// - `symlink-authenticity` (warning) — the double-copied impostor: user-scope
///   managed layout (global lock entry + canonical store placement) implies
///   host placements are symlinks into the store, so a physical host copy is
///   rotted structure. Project scope is exempt: non-interactive `add --copy`
///   is the stock layout there (collision-matrix scenario 1).
/// - `vercel-lock-drift` (action) — recomputed `computedHash` disagrees with a
///   PROJECT lock entry, per placement. Gated by hash-algorithm.md §4.4: only
///   recompute-eligible trees (ASCII relative paths; no symlinks,
///   `node_modules/`, `metadata.json`, `__pycache__/`, `__pypackages__/` in
///   the tree), a 64-hex stored hash, and a known sourceType can be compared
///   with confidence; anything else is "cannot verify" and stays silent.
///   Global scope is silent by design (`skillFolderHash` is a git tree SHA,
///   never recomputable — and never 64-hex, so the gate also catches it).
/// - `lock-without-files` (action) — a lock entry whose name has no healthy
///   (non-broken) placement in that scope; the ledger claim alone conjures no
///   skill (VAL-SCAN-028).
/// - `canonical-host-divergence` (action) — ports the archive's
///   `SourceDuplicate`: one lock source identity, >1 distinct content hash.
/// - `dangerous-removal-surface` (action) — advisory for every name the vercel
///   ledger does NOT claim (github-owned, ownerless, ambiguous-without-claim):
///   `npx skills remove <name>` deletes by name across ownership
///   (collision-matrix scenario 6). A locked name's removal is
///   ledger-consistent and never advised, even when ambiguity voids
///   attribution.
/// - `lock-version-unsupported` (warning) — the environment anomaly: a lock
///   NEWER than supported is surfaced as a finding with
///   lockPath/foundVersion/supportedVersion evidence (FIX-MALFORMED); the lock
///   is still best-effort parsed by the reader. Older incompatible locks stay
///   issue-only (VAL-SCAN-031). All other anomaly kinds (ledger-unreadable,
///   skill-md-*, directory-unreadable) remain issues owned by the readers and
///   scanner, per their fixture expectations.
public struct HealthAnalyzer: Sendable {
    /// Source types whose project `computedHash` describes a recomputable
    /// on-disk tree (hash-algorithm.md §4.4). Space-listed to avoid a
    /// multi-line collection literal (repo lint gates conflict on those).
    private static let recomputableSourceTypes: Set<String> = Set(
        "github local node_modules well-known".split(separator: " ").map(String.init))

    private let fileSystem: FileSystemProbe

    public init(fileSystem: FileSystemProbe = DefaultFileSystemProbe()) {
        self.fileSystem = fileSystem
    }

    /// Runs every analyzer-owned rule over the scan's groups and lock claims.
    public func analyze(groups: [SkillGroup], locks: [ScopeLockClaim]) -> [Finding] {
        var claims: [String: ScopeLockClaim] = [:]
        for claim in locks {
            claims[claim.scopeGroup] = claim
        }
        var findings: [Finding] = []
        for group in groups {
            let claim = claims[group.scopeGroup]
            findings.append(contentsOf: duplicateFindings(for: group))
            findings.append(contentsOf: impostorFindings(for: group, claim: claim))
            findings.append(contentsOf: driftFindings(for: group, claim: claim))
            if let finding = divergenceFinding(for: group, claim: claim) {
                findings.append(finding)
            }
            if let finding = removalSurfaceFinding(for: group, claim: claim) {
                findings.append(finding)
            }
        }
        findings.append(contentsOf: lockWithoutFilesFindings(locks: locks, groups: groups))
        findings.append(contentsOf: lockVersionFindings(locks: locks))
        return findings
    }

    // MARK: - cross-host-duplicate (alias / exact / divergent)

    /// Duplicate classes for one name within one ownership bucket. Broken
    /// symlinks never participate (no canonical path, no content); classes
    /// are not mutually exclusive (archive parity, port-reference §4).
    /// Agent-managed copies are the agent's own and never count as
    /// duplicates of an installer's copy.
    private func duplicateFindings(for group: SkillGroup) -> [Finding] {
        let members = group.members.filter {
            $0.placement.kind != .brokenSymlink && $0.placement.managingAgent == nil
        }
        var findings = aliasFindings(for: group, members: members)

        // exact: >1 distinct physical directory sharing ONE content hash. A
        // nil canonical path falls back to the raw path as physical identity
        // (the archive counts a canonicalize failure as a distinct value).
        var byHash: [String: [DiscoveredPlacement]] = [:]
        for member in members {
            if let hash = member.placement.contentHash {
                byHash[hash, default: []].append(member)
            }
        }
        for hash in byHash.keys.sorted() {
            let cluster = byHash[hash] ?? []
            guard physicalIdentities(cluster).count > 1 else { continue }
            var evidence = [Evidence(kind: "subtype", detail: "exact")]
            evidence += cluster.map { Evidence(kind: "memberPath", detail: $0.placement.path) }
            evidence.append(Evidence(kind: "contentHash", detail: hash))
            findings.append(
                Finding(
                    ruleID: "cross-host-duplicate", severity: .warning, skillName: group.name,
                    workspaceID: group.scopeGroup, evidence: evidence))
        }

        // divergent: >1 distinct physical directory with >1 distinct hash.
        let hashed = members.filter { $0.placement.contentHash != nil }
        let distinctHashes = Set(hashed.compactMap(\.placement.contentHash)).sorted()
        if distinctHashes.count > 1, physicalIdentities(hashed).count > 1 {
            var evidence = [Evidence(kind: "subtype", detail: "divergent")]
            evidence += hashed.map { Evidence(kind: "memberPath", detail: $0.placement.path) }
            evidence += distinctHashes.map { Evidence(kind: "contentHash", detail: $0) }
            findings.append(
                Finding(
                    ruleID: "cross-host-duplicate", severity: .warning, skillName: group.name,
                    workspaceID: group.scopeGroup, evidence: evidence))
        }
        return findings
    }

    /// alias: >1 placement resolving to ONE canonical path, ≥1 via symlink.
    private func aliasFindings(
        for group: SkillGroup, members: [DiscoveredPlacement]
    ) -> [Finding] {
        var findings: [Finding] = []
        var byCanonical: [String: [DiscoveredPlacement]] = [:]
        for member in members {
            if let canonical = member.placement.canonicalPath {
                byCanonical[canonical, default: []].append(member)
            }
        }
        for canonical in byCanonical.keys.sorted() {
            let cluster = byCanonical[canonical] ?? []
            guard cluster.count > 1,
                cluster.contains(where: { $0.placement.kind == .symlink })
            else { continue }
            var evidence = [Evidence(kind: "subtype", detail: "alias")]
            evidence.append(Evidence(kind: "canonicalPath", detail: canonical))
            evidence += cluster.map { Evidence(kind: "memberPath", detail: $0.placement.path) }
            findings.append(
                Finding(
                    ruleID: "cross-host-duplicate", severity: .info, skillName: group.name,
                    workspaceID: group.scopeGroup, evidence: evidence))
        }
        return findings
    }

    private func physicalIdentities(_ members: [DiscoveredPlacement]) -> Set<String> {
        Set(members.map { $0.placement.canonicalPath ?? $0.placement.path })
    }

    // MARK: - symlink-authenticity (double-copied impostor)

    /// User scope only: a vercel-locked name with a canonical-store placement
    /// implies link mode, so a PHYSICAL host copy is an impostor. Project
    /// scope never flags — copy mode is the stock layout there.
    private func impostorFindings(for group: SkillGroup, claim: ScopeLockClaim?) -> [Finding] {
        guard group.scopeGroup == "user",
            claim?.lock.entries[group.name] != nil,
            let canonical = group.members.first(where: {
                $0.workspaceID == group.scopeGroup && $0.placement.kind == .directory
            })
        else { return [] }
        return group.members
            .filter {
                $0.workspaceID != group.scopeGroup && $0.placement.kind == .directory
                    && $0.placement.managingAgent == nil
            }
            .map { impostor in
                var evidence = [Evidence(kind: "impostorPath", detail: impostor.placement.path)]
                evidence.append(
                    Evidence(kind: "canonicalPath", detail: canonical.placement.path))
                return Finding(
                    ruleID: "symlink-authenticity", severity: .warning, skillName: group.name,
                    workspaceID: group.scopeGroup, evidence: evidence)
            }
    }

    // MARK: - vercel-lock-drift

    /// One finding per recompute-eligible placement whose content hash
    /// disagrees with the PROJECT lock entry. Every placement is compared: a
    /// healthy canonical copy does not clear a drifted host copy
    /// (collision-matrix scenario 3, where gh overwrote only the host copy).
    private func driftFindings(for group: SkillGroup, claim: ScopeLockClaim?) -> [Finding] {
        guard let claim, claim.lock.scope == .project,
            let entry = claim.lock.entries[group.name],
            let stored = entry.computedHash,
            ContentHasher.isSHA256FolderHash(stored),
            let sourceType = entry.sourceType,
            Self.recomputableSourceTypes.contains(sourceType)
        else { return [] }
        var findings: [Finding] = []
        for member in group.members {
            guard member.placement.kind != .brokenSymlink,
                let actual = member.placement.contentHash,
                actual != stored,
                recomputeIneligibility(atPath: member.placement.path).isEmpty
            else { continue }
            var evidence: [Evidence] = []
            if let lockPath = claim.lockPath {
                evidence.append(Evidence(kind: "lockPath", detail: lockPath))
            }
            evidence.append(Evidence(kind: "entryKey", detail: group.name))
            evidence.append(Evidence(kind: "placementPath", detail: member.placement.path))
            evidence.append(Evidence(kind: "expectedHash", detail: stored))
            evidence.append(Evidence(kind: "actualHash", detail: actual))
            findings.append(
                Finding(
                    ruleID: "vercel-lock-drift", severity: .action, skillName: group.name,
                    workspaceID: group.scopeGroup, evidence: evidence))
        }
        return findings
    }

    /// The §4.4 confidence gate, delegated to `RecomputeEligibility`.
    private func recomputeIneligibility(atPath root: String) -> [String] {
        RecomputeEligibility(fileSystem: fileSystem).reasons(atPath: root)
    }

    // MARK: - lock-without-files

    /// Every lock entry whose name has no healthy placement in its scope.
    /// A broken-symlink-only name counts as fileless (a dangling link is not
    /// a healthy placement); incompatible-version locks never reach this rule
    /// because the reader drops their claims entirely.
    private func lockWithoutFilesFindings(
        locks: [ScopeLockClaim], groups: [SkillGroup]
    ) -> [Finding] {
        var healthy: Set<String> = []
        for group in groups {
            let hasFiles = group.members.contains { $0.placement.kind != .brokenSymlink }
            if hasFiles {
                healthy.insert(group.scopeGroup + "\u{1F}" + group.name)
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
                findings.append(
                    Finding(
                        ruleID: "lock-without-files", severity: .action, skillName: name,
                        workspaceID: claim.scopeGroup, evidence: evidence))
            }
        }
        return findings
    }

    // MARK: - canonical-host-divergence

    /// One lock source identity, >1 distinct content hash (the archive's
    /// `SourceDuplicate`; collision-matrix scenario 3). Requires a MANAGED
    /// entry (source + sourceType) — untracked copies have no identity to
    /// diverge from. Fires independently of ambiguity: the lock claim is
    /// data even when attribution is voided.
    private func divergenceFinding(for group: SkillGroup, claim: ScopeLockClaim?) -> Finding? {
        guard let entry = claim?.lock.entries[group.name], entry.isManaged else { return nil }
        let hashed = group.members.filter {
            $0.placement.kind != .brokenSymlink && $0.placement.contentHash != nil
                && $0.placement.managingAgent == nil
        }
        let distinctHashes = Set(hashed.compactMap(\.placement.contentHash)).sorted()
        guard distinctHashes.count > 1 else { return nil }
        var evidence: [Evidence] = []
        for member in hashed where member.workspaceID == group.scopeGroup {
            evidence.append(Evidence(kind: "canonicalPath", detail: member.placement.path))
        }
        for member in hashed where member.workspaceID != group.scopeGroup {
            evidence.append(Evidence(kind: "hostPath", detail: member.placement.path))
        }
        evidence.append(Evidence(kind: "sourceIdentity", detail: entry.sourceIdentity))
        evidence += distinctHashes.map { Evidence(kind: "contentHash", detail: $0) }
        return Finding(
            ruleID: "canonical-host-divergence", severity: .action, skillName: group.name,
            workspaceID: group.scopeGroup, evidence: evidence)
    }

    // MARK: - dangerous-removal-surface

    /// Advisory for names the vercel ledger does NOT claim: `npx skills
    /// remove <name>` deletes by name across ownership (collision-matrix
    /// scenario 6), so github-owned and ownerless skills are in its blast
    /// radius. Ownership detail mirrors the resolver's verdict (ambiguity
    /// voids to ownerless). placementPath evidence lists real placements
    /// only — a broken-symlink member is covered by its own finding and is
    /// filtered here like every other rule does.
    private func removalSurfaceFinding(for group: SkillGroup, claim: ScopeLockClaim?) -> Finding? {
        guard claim?.lock.entries[group.name] == nil else { return nil }
        let ownership = OwnershipResolver.ownership(
            ambiguous: group.ambiguous,
            vercelClaim: false,
            githubClaim: group.members.contains { $0.githubProvenance != nil },
            agentClaim: group.managingAgent != nil)
        var evidence = [Evidence(kind: "skillName", detail: group.name)]
        evidence += group.members
            .filter { $0.placement.kind != .brokenSymlink }
            .map { Evidence(kind: "placementPath", detail: $0.placement.path) }
        evidence.append(Evidence(kind: "ownership", detail: ownership.rawValue))
        return Finding(
            ruleID: "dangerous-removal-surface", severity: .action, skillName: group.name,
            workspaceID: group.scopeGroup, evidence: evidence)
    }

    // MARK: - lock-version-unsupported (environment anomaly)

    /// A lock NEWER than supported surfaces as a finding carrying the
    /// versionStatus evidence (lockPath/foundVersion/supportedVersion); the
    /// reader still best-effort parses it. Older incompatible locks are
    /// issue-only per VAL-SCAN-031.
    private func lockVersionFindings(locks: [ScopeLockClaim]) -> [Finding] {
        var findings: [Finding] = []
        for claim in locks {
            guard case .newerThanSupported(let found, let supported) = claim.lock.versionStatus
            else { continue }
            var evidence: [Evidence] = []
            if let lockPath = claim.lockPath {
                evidence.append(Evidence(kind: "lockPath", detail: lockPath))
            }
            evidence.append(Evidence(kind: "foundVersion", detail: String(found)))
            evidence.append(Evidence(kind: "supportedVersion", detail: String(supported)))
            findings.append(
                Finding(
                    ruleID: "lock-version-unsupported", severity: .warning, skillName: nil,
                    workspaceID: claim.scopeGroup, evidence: evidence))
        }
        return findings
    }
}
