import Foundation

/// Per-host installed/leftover/absent detection.
///
/// Detection here is for USER (global) scope. It never consults the process
/// working directory, so scans stay deterministic and hermetic; the only
/// external probe is `/etc/codex` existence for the `codex` host (explicitly
/// permitted by the SUKIRU_HOME hermeticity rule). `launcherPresent` also reads
/// `PATH`, which only the sidebar's installed-agent list uses. Project-scope
/// host presence is a plain existence test and does not use this detector.
public struct HostDetector: Sendable {
    private let environment: SukiruEnvironment
    private let fileSystem: FileSystemProbe
    private let resolver: HostPathResolver

    public init(environment: SukiruEnvironment, fileSystem: FileSystemProbe) {
        self.environment = environment
        self.fileSystem = fileSystem
        self.resolver = HostPathResolver(environment: environment, fileSystem: fileSystem)
    }

    /// The load-bearing rule: a plain file always counts; a
    /// non-directory does not; an unreadable directory counts (plain
    /// existence); otherwise a directory marks an installation UNLESS it is
    /// CLI spray residue: folders holding nothing but `skills` entries and
    /// empty folders (ignoring `.DS_Store` / `.localized`), such as
    /// `.adal/skills` or `.astrbot/data/skills`.
    public func marksInstallation(_ path: String) -> Bool {
        if fileSystem.isFile(atPath: path) {
            return true
        }
        if !fileSystem.isDirectory(atPath: path) {
            return false
        }
        return !isResidue(path, depth: 0)
    }

    /// The skills CLI nests a host's folder at most a few levels under its
    /// config home, so deeper trees are treated as real content.
    private func isResidue(_ path: String, depth: Int) -> Bool {
        guard depth < 4, let entries = fileSystem.directoryEntries(atPath: path) else {
            return false
        }
        return entries.allSatisfy { name in
            if name == "skills" || name == ".DS_Store" || name == ".localized" { return true }
            let child = HostPathResolver.join(path, name)
            return fileSystem.isDirectory(atPath: child) && isResidue(child, depth: depth + 1)
        }
    }

    /// Ordered detection algorithm (`is_detected_at`),
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

    /// Ids of every agent installed in user scope: host-table hosts plus the
    /// agents Sukiru manages that the skills CLI does not list, probed at the
    /// config homes their hook and add-on readers use. An agent with a known
    /// launcher counts only while that launcher is on this Mac.
    public func installedAgentIDs() -> Set<String> {
        let home = environment.home
        let homes = [
            "openclaude": home + "/.openclaude",
            "jcode": environment.externalValue(for: "JCODE_HOME") ?? home + "/.jcode",
            "muse": resolver.xdgConfigBase() + "/muse",
            "dsh": home + "/.dsh",
            "omp": home + "/.omp/agent"
        ]
        let configured = Set(HostTable.hosts.filter(isDetected).map(\.id))
            .union(homes.filter { marksInstallation($0.value) }.keys)
        return configured.filter { launcherPresent($0) != false }
            .union(AgentLauncher.probes.keys.filter { launcherPresent($0) == true })
    }

    /// Whether the agent's app, command, or editor extension is on this Mac;
    /// nil when Sukiru knows no launcher for it. Commands are looked up on
    /// `PATH` and in `~/.local/bin`, where native installers put them even
    /// when the app's inherited `PATH` lacks it. Fixture homes never probe
    /// `/Applications`.
    public func launcherPresent(_ agentID: String) -> Bool? {
        guard let probe = AgentLauncher.probes[agentID] else { return nil }
        let home = environment.home
        let appFolders =
            [home + "/Applications"] + (environment.homeIsOverridden ? [] : ["/Applications"])
        let commandFolders =
            (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(
                String.init)
            + [home + "/.local/bin"]
        let extensionFolders = AgentLauncher.editorHomes.compactMap {
            fileSystem.directoryEntries(atPath: home + "/" + $0 + "/extensions")
        }
        return probe.apps.contains { app in
            appFolders.contains { fileSystem.exists(atPath: $0 + "/" + app + ".app") }
        }
            || probe.commands.contains { command in
                commandFolders.contains { fileSystem.isFile(atPath: $0 + "/" + command) }
            }
            || probe.extensions.contains { id in
                extensionFolders.contains { $0.contains { $0.lowercased().hasPrefix(id + "-") } }
            }
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
