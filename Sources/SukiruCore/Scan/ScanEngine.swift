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
/// precedence and the requested scope), and returns a `ScanReport`. Skill
/// inventory, ownership resolution, and findings land in later features; until
/// then those collections are empty-but-schema-valid.
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
        let workspaces = enumerator.enumerate(projectRoots: roots).filter {
            request.scope.includes($0.kind)
        }
        return ScanReport(workspaces: workspaces)
    }
}
