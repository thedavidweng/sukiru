import AppKit
import SukiruCore

/// The official CLIs Sukiru delegates installs and repairs to, and how
/// Settings can install or update them through Homebrew.
enum InstallerTool: String, CaseIterable, Identifiable {
    case github
    case node

    var id: String { rawValue }

    /// The executable whose location decides who manages the tool.
    var executable: String {
        switch self {
        case .github: return "gh"
        case .node: return "npx"
        }
    }

    var formula: String {
        switch self {
        case .github: return "gh"
        case .node: return "node"
        }
    }

    /// The vendor download page, offered when Homebrew is absent.
    var downloadURL: URL {
        switch self {
        case .github: return URL(string: "https://cli.github.com")!
        case .node: return URL(string: "https://nodejs.org/en/download")!
        }
    }
}

extension AppState {
    enum BrewAction: String {
        case install
        case upgrade
        case reinstall
    }

    nonisolated private static let homebrewPrefixes = ["/opt/homebrew", "/usr/local"]

    /// The Homebrew executable, if Homebrew is installed in a standard prefix.
    nonisolated static var brewURL: URL? {
        homebrewPrefixes
            .map { URL(fileURLWithPath: $0).appending(path: "bin/brew") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Apps launched from Finder inherit launchd's minimal PATH, so the
    /// probes would miss Homebrew-installed CLIs (and every install made from
    /// Settings). Appending keeps any caller-provided PATH entries first, and
    /// sessions with an explicit `SUKIRU_HOME` (fixtures, CLI parity) are left
    /// untouched so their PATH shims stay authoritative.
    static func includeHomebrewInPath() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SUKIRU_HOME"] == nil, brewURL != nil else { return }
        var entries = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for prefix in homebrewPrefixes where !entries.contains("\(prefix)/bin") {
            entries.append("\(prefix)/bin")
        }
        setenv("PATH", entries.joined(separator: ":"), 1)
    }

    /// Finds CLIs the way the user's terminal does: the login shell's PATH
    /// first, then the version managers' own directories for shells that
    /// fail or time out. Runs off the main actor; only the results land on
    /// it. Fixture sessions keep their PATH so their shims stay authoritative.
    nonisolated func adoptUserToolPath() async {
        let environment = ProcessInfo.processInfo.environment
        let toolchain = NodeToolchain(home: NSHomeDirectory())
        let entries = { (path: String?) in (path ?? "").split(separator: ":").map(String.init) }
        let isFixture = environment["SUKIRU_HOME"] != nil
        let path =
            isFixture
            ? environment["PATH"] ?? ""
            : NodeToolchain.searchPath([
                entries(LoginShell.path()), entries(environment["PATH"]),
                toolchain.managerBinDirectories()
            ])
        let managers = isFixture ? [] : toolchain.installedManagers(searchPath: path)
        var locations: [InstallerTool: String] = [:]
        for tool in InstallerTool.allCases {
            locations[tool] = entries(path).map { "\($0)/\(tool.executable)" }
                .first { FileManager.default.isExecutableFile(atPath: $0) }
        }
        await MainActor.run {
            if !isFixture { setenv("PATH", path, 1) }
            self.nodeManagers = managers
            self.installedPaths = locations
        }
    }

    /// Where `tool` resolves on PATH, or nil when it is not installed, as of
    /// the last installer check.
    func installedPath(of tool: InstallerTool) -> String? {
        installedPaths[tool]
    }

    /// Homebrew can only update the copies it installed.
    func isManagedByHomebrew(_ tool: InstallerTool) -> Bool {
        guard Self.brewURL != nil, let path = installedPath(of: tool) else { return false }
        return Self.homebrewPrefixes.contains { path.hasPrefix($0 + "/") }
    }

    /// Runs `brew <action> <formula>` in the background, then re-probes so the
    /// row reflects the result. Without Homebrew, opens the vendor page.
    func runInstaller(_ tool: InstallerTool, action: BrewAction) {
        guard installerInFlight == nil else { return }
        guard let brew = Self.brewURL else {
            NSWorkspace.shared.open(tool.downloadURL)
            return
        }
        installerInFlight = tool
        installerFailures[tool] = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            let failure = Self.runBrew(brew, arguments: [action.rawValue, tool.formula])
            await MainActor.run {
                guard let self else { return }
                self.installerInFlight = nil
                self.installerFailures[tool] = failure
                self.recheckCapabilities()
            }
        }
    }

    /// Looks up the registry's latest skills CLI release. Failures leave the
    /// hint off; nothing is downloaded.
    func checkForSkillsUpdate() {
        Task { [weak self] in
            let latest = try? await SkillsCLI.latestVersion(
                transport: URLSessionMarketplaceTransport())
            self?.skillsLatestVersion = latest
        }
    }

    /// Downloads the skills CLI, or updates it to the latest release, only
    /// when the user asks; then re-probes so Settings shows the result.
    func fetchSkillsCLI() {
        guard !skillsFetchInFlight else { return }
        skillsFetchInFlight = true
        skillsFetchFailure = nil
        let environment = self.environment
        Task.detached(priority: .userInitiated) { [weak self] in
            let failure = SkillsCLI.fetch(environment: environment)
            await MainActor.run {
                guard let self else { return }
                self.skillsFetchInFlight = false
                self.skillsFetchFailure = failure
                self.recheckCapabilities()
            }
        }
    }

    /// Returns nil on success, otherwise the last lines Homebrew printed.
    nonisolated private static func runBrew(_ brew: URL, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = brew
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            return error.localizedDescription
        }
        // Drain before waiting so a chatty install cannot fill the pipe.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return nil }
        let text = String(bytes: data, encoding: .utf8) ?? ""
        return text.split(separator: "\n").suffix(3).joined(separator: "\n")
    }
}
