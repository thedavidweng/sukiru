/// Per-host installed/leftover/absent detection (architecture §4.1,
/// port-reference §1–2).
///
/// Detection here is for USER (global) scope. It never consults the process
/// working directory, so scans stay deterministic and hermetic; the only
/// external probe is `/etc/codex` existence for the `codex` host (explicitly
/// permitted by the SUKIRU_HOME hermeticity rule). Project-scope host presence
/// is a plain existence test and does not use this detector.
public struct HostDetector: Sendable {
    private let environment: SukiruEnvironment
    private let fileSystem: FileSystemProbe
    private let resolver: HostPathResolver

    public init(environment: SukiruEnvironment, fileSystem: FileSystemProbe) {
        self.environment = environment
        self.fileSystem = fileSystem
        self.resolver = HostPathResolver(environment: environment, fileSystem: fileSystem)
    }

    /// The load-bearing rule (port-reference §2): a plain file always counts; a
    /// non-directory does not; an unreadable directory counts (plain
    /// existence); otherwise a directory marks an installation UNLESS its
    /// entire content is a bare `skills` entry (ignoring `.DS_Store` /
    /// `.localized`), which is CLI spray residue, not an installation.
    public func marksInstallation(_ path: String) -> Bool {
        if fileSystem.isFile(atPath: path) {
            return true
        }
        if !fileSystem.isDirectory(atPath: path) {
            return false
        }
        guard let entries = fileSystem.directoryEntries(atPath: path) else {
            return true
        }
        let sawSkills = entries.contains("skills")
        let sawOther = entries.contains { name in
            name != "skills" && name != ".DS_Store" && name != ".localized"
        }
        return !(sawSkills && !sawOther)
    }

    /// Ordered detection algorithm (port-reference §1, `is_detected_at`),
    /// evaluated for the user/global scope (no cwd). Each step short-circuits.
    public func isDetected(_ host: HostSpec) -> Bool {
        // 1. universal is a pseudo-host; never "installed".
        if host.id == "universal" {
            return false
        }
        // 2. codex: the absolute, system-wide marker (the sole external probe).
        if host.id == "codex", marksInstallation("/etc/codex") {
            return true
        }
        // 3. replit is cwd-only; with no cwd it cannot be detected in user scope.
        if host.id == "replit" {
            return false
        }
        // 4. zed: custom XDG / APPDATA / FLATPAK probe, plain existence.
        if host.id == "zed" {
            return zedDetected()
        }
        // 5. detectInProject uses a cwd probe (skipped: no cwd), then falls
        //    through to the home-marker probes below.

        // 6. Empty marker: probe the resolved config home itself and STOP;
        //    never fall through to `$HOME` (which `join(home, "")` would be).
        let base = resolver.configHome(for: host)
        if host.detectionMarker.isEmpty {
            return marksInstallation(base)
        }
        // 7. base-relative marker, then $HOME-relative marker.
        if marksInstallation(HostPathResolver.join(base, host.detectionMarker)) {
            return true
        }
        if marksInstallation(HostPathResolver.join(environment.home, host.detectionMarker)) {
            return true
        }
        // 8. extra markers, probed against $HOME only.
        for marker in host.extraMarkers
        where marksInstallation(HostPathResolver.join(environment.home, marker)) {
            return true
        }
        return false
    }

    /// The installed/leftover/absent tri-state for a host in user scope.
    ///
    /// A detected host is `.detected`. Otherwise, if the host's global skills
    /// root exists on disk it is `.leftover` (CLI spray residue — still
    /// scannable, but flagged not-installed); if it does not exist the host is
    /// `.absent`.
    public func detectionState(for host: HostSpec) -> HostDetectionState {
        if isDetected(host) {
            return .detected
        }
        let root = resolver.globalSkillsRoot(for: host)
        if fileSystem.exists(atPath: root) {
            return .leftover
        }
        return .absent
    }

    private func zedDetected() -> Bool {
        if fileSystem.exists(atPath: HostPathResolver.join(resolver.xdgConfigBase(), "zed")) {
            return true
        }
        if let appData = environment.externalValue(for: "APPDATA") {
            let probe = HostPathResolver.join(appData, "Zed")
            if fileSystem.exists(atPath: probe) {
                return true
            }
        }
        if let flatpak = environment.externalValue(for: "FLATPAK_XDG_CONFIG_HOME") {
            let probe = HostPathResolver.join(flatpak, "zed")
            if fileSystem.exists(atPath: probe) {
                return true
            }
        }
        return false
    }
}
