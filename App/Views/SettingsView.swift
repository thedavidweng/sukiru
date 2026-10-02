import SukiruCore
import SwiftUI

/// The Settings window (standard ⌘, scene), paged like Contacts. Projects
/// edits the saved project folders; Installers checks, installs, and
/// updates the official CLIs Sukiru delegates to. Refresh lives in the
/// main window toolbar (and ⌘R) because the app keeps no watchers.
struct SettingsView: View {
    var body: some View {
        if #available(macOS 15.0, *) {
            TabView {
                Tab("General", systemImage: "gearshape") { GeneralSettingsPane() }
                Tab("Projects", systemImage: "folder") { ProjectsSettingsPane() }
                Tab("Installers", systemImage: "shippingbox") { InstallersSettingsPane() }
            }
        } else {
            TabView {
                GeneralSettingsPane()
                    .tabItem { Label("General", systemImage: "gearshape") }
                ProjectsSettingsPane()
                    .tabItem { Label("Projects", systemImage: "folder") }
                InstallersSettingsPane()
                    .tabItem { Label("Installers", systemImage: "shippingbox") }
            }
        }
    }
}

// MARK: - Projects

private struct ProjectsSettingsPane: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        let counts = skillCounts
        Form {
            Section {
                if state.projectRoots.isEmpty {
                    Text("No projects yet. Add a folder to include its project-scope skills.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                }
                ForEach(state.projectRoots, id: \.self) { root in
                    row(root, skillCount: counts[root, default: 0])
                }
            } header: {
                Text("Project Folders")
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text(footnote)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Add Project…") {
                        state.addProjectRootViaPanel()
                    }
                    .axButtonToken("sukiru.settings.projects.add")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 340)
    }

    private var footnote: LocalizedStringKey {
        state.environment.projectRoots.isEmpty
            ? "Sukiru reads the skills in each project's agent folders."
            : "SUKIRU_ROOTS is set, so changes here last until Sukiru quits."
    }

    private var skillCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for skill in state.report?.skills ?? [] where skill.scope == .project {
            if let root = state.projectRoot(of: skill) {
                counts[root, default: 0] += 1
            }
        }
        return counts
    }

    private func row(_ root: String, skillCount: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: URL(fileURLWithPath: root).lastPathComponent)
                    .lineLimit(1)
                Text(verbatim: root)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text("\(skillCount) skills")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Menu {
                Button("Show in Finder") {
                    state.revealInFinder([root])
                }
                Divider()
                Button("Remove Project", role: .destructive) {
                    state.removeProjectRoot(root)
                }
                .axButtonToken("sukiru.settings.projects.remove.\(AXTokens.path(root))")
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions for this project")
        }
        .padding(.vertical, 2)
        .help(root)
        .contextMenu {
            Button("Show in Finder") {
                state.revealInFinder([root])
            }
            Divider()
            Button("Remove Project", role: .destructive) {
                state.removeProjectRoot(root)
            }
        }
    }
}

// MARK: - Installers

private struct InstallersSettingsPane: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(AppState.installAsCopiesDefaultsKey) private var installAsCopies = false

    var body: some View {
        Form {
            Section {
                // Rows render from the first frame in a checking state while
                // the background probes run, then settle.
                InstallerRow(
                    tool: .github, title: "GitHub CLI", token: "sukiru.settings.capability.gh",
                    status: state.capabilities.map { githubStatus($0.github) })
                InstallerRow(
                    tool: .node, title: "Node.js", token: "sukiru.settings.capability.node",
                    status: state.capabilities.map { nodeStatus($0.npx) })
                SkillsCLIRow(status: state.capabilities.map { skillsStatus($0.npx) })
            } header: {
                Text("Command-Line Tools")
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    HStack(spacing: 0) {
                        AXToken(token: "sukiru.settings.capabilities")
                        Text(footnote)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .contain)
                    Spacer()
                    if state.capabilityCheckRunning {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("Check Again") {
                        state.recheckCapabilities()
                    }
                    .disabled(
                        state.capabilityCheckRunning || state.installerInFlight != nil
                            || state.skillsFetchInFlight)
                }
            }
            Section {
                Toggle("Install new skills as copies", isOn: $installAsCopies)
            } footer: {
                Text("settings.installAsCopies.footer")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if neitherCLI {
                // With neither CLI, Sukiru is the full read-only
                // diagnostician; the notice is explicit.
                Section {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        AXToken(token: "sukiru.settings.readonlyNotice")
                        // swiftlint:disable line_length
                        let notice: LocalizedStringKey =
                            "Read-only diagnostic mode: neither gh nor the skills CLI is available. Sukiru inspects and reports your library, but repairs and installs are unavailable."
                        // swiftlint:enable line_length
                        Label {
                            Text(notice)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .symbolRenderingMode(.multicolor)
                        }
                    }
                    .accessibilityElement(children: .contain)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 420)
    }

    // swiftlint:disable line_length
    private var footnote: LocalizedStringKey {
        AppState.brewURL == nil
            ? "Sukiru hands installs and repairs to these tools. Install opens the download page because Homebrew isn't installed."
            : "Sukiru hands installs and repairs to these tools. Install and Update run Homebrew."
    }
    // swiftlint:enable line_length

    private var neitherCLI: Bool {
        state.capabilities.map { !$0.github.available && !$0.npx.canRunSkills } ?? false
    }

    private func githubStatus(_ github: CapabilityReport.GitHubCapability) -> InstallerStatus {
        if github.available {
            return .ready(String(localized: "capability.available \(github.version ?? "?")"))
        }
        let reason: String
        switch github.reason {
        case .absent: reason = String(localized: "capability.reason.absent")
        case .tooOld: reason = String(localized: "capability.reason.tooOld")
        case .probeFailed: reason = String(localized: "capability.reason.probeFailed")
        case nil: reason = ""
        }
        // A present-but-too-old gh shows BOTH the detected version and the
        // unsupported state; absence shows the bare reason.
        if let version = github.version {
            return .outdated(String(localized: "capability.unavailableAt \(version) \(reason)"))
        }
        let summary = String(localized: "capability.unavailable \(reason)")
        return github.present ? .outdated(summary) : .missing(summary)
    }

    private func nodeStatus(_ npx: CapabilityReport.NpxCapability) -> InstallerStatus {
        guard npx.reason == .absent else {
            return .ready(String(localized: "capability.installed"))
        }
        let reason = String(localized: "capability.reason.absent")
        return .missing(String(localized: "capability.unavailable \(reason)"))
    }

    private func skillsStatus(_ npx: CapabilityReport.NpxCapability) -> InstallerStatus {
        guard npx.canRunSkills else {
            let reason = String(localized: "capability.reason.needsNode")
            return .missing(String(localized: "capability.unavailable \(reason)"))
        }
        guard npx.resolvable, let installed = npx.skillsVersion else {
            return .ready(String(localized: "capability.downloadsOnFirstUse"))
        }
        if let latest = state.skillsLatestVersion, SkillsCLI.isUpdate(latest, over: installed) {
            return .outdated(String(localized: "capability.updateAvailable \(installed) \(latest)"))
        }
        return .ready(String(localized: "capability.available \(installed)"))
    }
}
