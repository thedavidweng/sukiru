import Foundation

/// Read-only disk evidence captured before pure batch planning. Recreate after a scan.
public struct HostRemovalContext: Sendable {
    struct ScopeFacts: Sendable {
        let sharedRoot: String
        let sharedCanonicalRoot: String?
        let nativeRoots: [String: String]
        let installRoots: [String: String]
        let detectedHosts: Set<String>
        var existingPaths: Set<String>
        let workspaces: [EnumeratedWorkspace]
        let lockPath: String
    }

    var scopes: [String: ScopeFacts]

    mutating func exclude(_ paths: Set<String>, bucket: String) {
        scopes[bucket]?.existingPaths.subtract(paths)
    }

    public init(
        environment: SukiruEnvironment, report: ScanReport, projectRoots: [String],
        fileSystem: any FileSystemProbe = DefaultFileSystemProbe()
    ) {
        let resolver = HostPathResolver(environment: environment, fileSystem: fileSystem)
        let detailed = WorkspaceEnumerator(environment: environment, fileSystem: fileSystem)
            .enumerateDetailed(projectRoots: projectRoots)
        var scopes: [String: ScopeFacts] = [:]
        for bucket in Set(detailed.map(\.scopeGroup)) {
            let project = CommandBatchBuilder.projectRoot(ofBucket: bucket)
            let shared =
                project.map { resolver.canonicalProjectRoot(projectRoot: $0) }
                ?? resolver.canonicalUserRoot()
            var native: [String: String] = [:]
            var install: [String: String] = [:]
            var detected: Set<String> = []
            var existing: Set<String> = []
            for host in HostTable.hosts {
                let root =
                    project.map { resolver.projectSkillsRoot(for: host, projectRoot: $0) }
                    ?? resolver.globalSkillsRoot(for: host)
                native[host.id] = root
                let installRoot = Self.isUniversal(host) ? shared : root
                install[host.id] = installRoot
                let isDetected = Self.detected(
                    host, project: project, environment: environment, resolver: resolver,
                    fileSystem: fileSystem)
                if isDetected { detected.insert(host.id) }
                for name in report.skills.map(\.name) {
                    let path = installRoot + "/" + Self.folderName(name)
                    if fileSystem.entryKind(atPath: path) != nil { existing.insert(path) }
                }
            }
            scopes[bucket] = ScopeFacts(
                sharedRoot: shared, sharedCanonicalRoot: fileSystem.resolvedPath(atPath: shared),
                nativeRoots: native, installRoots: install, detectedHosts: detected,
                existingPaths: existing, workspaces: detailed.filter { $0.scopeGroup == bucket },
                lockPath: project.map { $0 + "/skills-lock.json" }
                    ?? environment.home + "/.agents/.skill-lock.json")
        }
        self.scopes = scopes
    }

    static func isUniversal(_ host: HostSpec) -> Bool {
        host.projectSkillDir == HostTable.canonicalProjectSkillDir && host.showInUniversalList
    }

    /// skills@1.7.0's name-to-folder mapping, including plugin names such as ce:review.
    static func folderName(_ name: String) -> String {
        let replaced = name.lowercased().replacingOccurrences(
            of: "[^a-z0-9._]+", with: "-", options: .regularExpression)
        let trimmed = replaced.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return trimmed.isEmpty ? "unnamed-skill" : String(trimmed.prefix(255))
    }

    /// Official detection uses plain existence, deliberately unlike Sukiru's spray filter.
    private static func detected(
        _ host: HostSpec, project: String?, environment: SukiruEnvironment,
        resolver: HostPathResolver, fileSystem: any FileSystemProbe
    ) -> Bool {
        if host.id == "universal" { return false }
        let cwd = project ?? FileManager.default.currentDirectoryPath
        if host.id == "replit" { return fileSystem.exists(atPath: cwd + "/.replit") }
        if host.id == "zed" {
            return fileSystem.exists(atPath: resolver.xdgConfigBase() + "/zed")
                || environment.externalValue(for: "APPDATA").map {
                    fileSystem.exists(atPath: $0 + "/Zed")
                } == true
                || environment.externalValue(for: "FLATPAK_XDG_CONFIG_HOME").map {
                    fileSystem.exists(atPath: $0 + "/zed")
                } == true
        }
        if host.id == "codex", fileSystem.exists(atPath: "/etc/codex") { return true }
        if host.detectInProject {
            if fileSystem.exists(atPath: cwd + "/" + host.detectionMarker) { return true }
        }
        let base = resolver.configHome(for: host)
        if host.detectionMarker.isEmpty { return fileSystem.exists(atPath: base) }
        return fileSystem.exists(atPath: HostPathResolver.join(base, host.detectionMarker))
            || host.extraMarkers.contains { fileSystem.exists(atPath: environment.home + "/" + $0) }
    }
}
