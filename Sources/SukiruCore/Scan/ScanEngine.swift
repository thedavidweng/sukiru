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
/// At the skeleton milestone `scan` validates the environment (architecture
/// D4) and returns an empty-but-schema-valid `ScanReport`. The full inventory,
/// ownership resolution, and detection rules land in M2.
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
        return ScanReport()
    }
}
