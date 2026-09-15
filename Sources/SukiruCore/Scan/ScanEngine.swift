/// Inputs to a scan (architecture §4.2).
///
/// `explicitRoots` come from `--root` flags and, per D5, REPLACE `SUKIRU_ROOTS`
/// rather than merging with it. The M2 engine consumes these; the skeleton
/// records them so the surface is stable.
public struct ScanRequest: Equatable, Sendable {
    public let explicitRoots: [String]
    public let scope: Scope

    public init(explicitRoots: [String] = [], scope: Scope = .all) {
        self.explicitRoots = explicitRoots
        self.scope = scope
    }
}

/// The seam-A read engine.
///
/// `scan` validates the environment (architecture D4), enumerates the
/// workspace root set (host detection + project roots, honoring D5 root
/// precedence and the requested scope), runs inventory discovery (placements,
/// issues, broken-symlink findings), reads the Vercel locks for the scanned
/// scopes (global lock for user scope, one project lock per project root),
/// and resolves ownership per skill name per scope (architecture §6, D1),
/// then runs the HealthAnalyzer's detection rules (architecture §5) over the
/// groups and lock claims.
public struct ScanEngine: Sendable {
    private let environment: SukiruEnvironment
    private let fileSystem: FileSystemProbe

    public init(
        environment: SukiruEnvironment,
        fileSystem: FileSystemProbe = DefaultFileSystemProbe()
    ) {
        self.environment = environment
        self.fileSystem = fileSystem
    }

    /// Produces the scan report.
    ///
    /// - Throws: `FatalEnvironmentProblem.sukiruHomeMissing` when `SUKIRU_HOME`
    ///   is set to a path that does not exist (architecture D4 → exit code 2).
    public func scan(_ request: ScanRequest) throws -> ScanReport {
        if let problem = environment.fatalProblem(fileSystem: fileSystem) {
            throw problem
        }
        // D5: explicit --root flags REPLACE SUKIRU_ROOTS; there is no merge.
        let roots = request.explicitRoots.isEmpty ? environment.projectRoots : request.explicitRoots
        let enumerator = WorkspaceEnumerator(environment: environment, fileSystem: fileSystem)
        let workspaces = enumerator.enumerateDetailed(projectRoots: roots).filter {
            request.scope.includes($0.workspace.kind)
        }
        let inventory = InventoryScanner(fileSystem: fileSystem).scan(workspaces: workspaces)
        let claims = readLockClaims(request: request, roots: roots)
        let groups = SkillInventory.groups(from: inventory.placements)
        let resolution = OwnershipResolver().resolve(groups: groups, locks: claims.claims)
        let health = HealthAnalyzer(fileSystem: fileSystem).analyze(
            groups: groups, locks: claims.claims)
        let findings = (inventory.findings + resolution.findings + health)
            .sorted(by: Self.findingOrder)
        let issues = (inventory.issues + claims.issues).sorted {
            ($0.path, $0.kind, $0.message) < ($1.path, $1.kind, $1.message)
        }
        return ScanReport(
            workspaces: workspaces.map(\.workspace),
            skills: resolution.skills,
            findings: findings,
            issues: issues
        )
    }

    /// Reads the Vercel locks for the scopes being scanned: the global (v3)
    /// lock for user scope, one project (v1) lock per project root. A scope
    /// excluded by `--scope` never has its lock read, so its lock issues
    /// cannot leak into a partitioned report (VAL-SCAN-007).
    private func readLockClaims(
        request: ScanRequest,
        roots: [String]
    ) -> (claims: [ScopeLockClaim], issues: [Issue]) {
        let reader = VercelLockReader(environment: environment, fileSystem: fileSystem)
        var claims: [ScopeLockClaim] = []
        var issues: [Issue] = []
        if request.scope.includes(.user) {
            let result = reader.readGlobalLock()
            if let issue = result.issue {
                issues.append(issue)
            }
            if let lock = result.lock {
                claims.append(
                    ScopeLockClaim(scopeGroup: "user", lockPath: result.path, lock: lock))
            }
        }
        if request.scope.includes(.project) {
            for root in roots {
                let result = reader.readProjectLock(projectRoot: root)
                if let issue = result.issue {
                    issues.append(issue)
                }
                if let lock = result.lock {
                    claims.append(
                        ScopeLockClaim(
                            scopeGroup: "project:\(root)", lockPath: result.path, lock: lock))
                }
            }
        }
        return (claims, issues)
    }

    /// Deterministic finding order: rule, workspace, skill, then evidence
    /// content as the final tiebreak.
    private static func findingOrder(_ lhs: Finding, _ rhs: Finding) -> Bool {
        let lhsKey = (lhs.ruleID, lhs.workspaceID, lhs.skillName ?? "")
        let rhsKey = (rhs.ruleID, rhs.workspaceID, rhs.skillName ?? "")
        if lhsKey != rhsKey {
            return lhsKey < rhsKey
        }
        let lhsEvidence = lhs.evidence.map { $0.kind + "\u{1F}" + $0.detail }
        let rhsEvidence = rhs.evidence.map { $0.kind + "\u{1F}" + $0.detail }
        return lhsEvidence.lexicographicallyPrecedes(rhsEvidence)
    }
}
