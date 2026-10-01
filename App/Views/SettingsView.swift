import SukiruCore
import SwiftUI

/// The Settings window (standard ⌘, scene), paged like Contacts. Projects
/// edits the saved project folders (D20); Installers checks, installs, and
/// updates the official CLIs Sukiru delegates to (D6). Refresh lives in the
/// main window toolbar (and ⌘R) because the app keeps no watchers (D7).
struct SettingsView: View {
    var body: some View {
        if #available(macOS 15.0, *) {
            TabView {
                Tab("Projects", systemImage: "folder") { ProjectsSettingsPane() }
                Tab("Installers", systemImage: "shippingbox") { InstallersSettingsPane() }
            }
        } else {
            TabView {
                ProjectsSettingsPane()
                    .tabItem { Label("Projects", systemImage: "folder") }
                InstallersSettingsPane()
                    .tabItem { Label("Installers", systemImage: "shippingbox") }
            }
        }
    }
}

// MARK: - Projects (D20)

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

// MARK: - Installers (D6, surfaced per VAL-CROSS-001)

private struct InstallersSettingsPane: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            Section {
                // Rows render from the first frame in a checking state while
                // the background probes run, then settle (VAL-HEALTH-004).
                InstallerRow(
                    tool: .github, title: "GitHub CLI", token: "sukiru.settings.capability.gh",
                    status: state.capabilities.map { githubStatus($0.github) })
                InstallerRow(
                    tool: .node, title: "Node.js (npx skills)",
                    token: "sukiru.settings.capability.npx",
                    status: state.capabilities.map { npxStatus($0.npx) })
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
                    .disabled(state.capabilityCheckRunning || state.installerInFlight != nil)
                }
            }
            if neitherCLI {
                // §8: with neither CLI, Sukiru is the full read-only
                // diagnostician; the notice is explicit (VAL-HEALTH-026).
                Section {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        AXToken(token: "sukiru.settings.readonlyNotice")
                        // swiftlint:disable line_length
                        let notice: LocalizedStringKey =
                            "Read-only diagnostic mode: neither gh nor Node.js (npx) is available. Sukiru inspects and reports your library, but repairs and installs are unavailable."
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
        .frame(width: 560, height: 340)
    }

    // swiftlint:disable line_length
    private var footnote: LocalizedStringKey {
        AppState.brewURL == nil
            ? "Sukiru hands installs and repairs to these tools. Install opens the download page because Homebrew isn't installed."
            : "Sukiru hands installs and repairs to these tools. Install and Update run Homebrew."
    }
    // swiftlint:enable line_length

    private var neitherCLI: Bool {
        state.capabilities.map { !$0.github.available && !$0.npx.resolvable } ?? false
    }

    private func githubStatus(_ github: CapabilityReport.GitHubCapability) -> InstallerRow.Status {
        if github.available {
            return .ready(
                String(format: String(localized: "capability.available %@"), github.version ?? "?"))
        }
        let reason: String
        switch github.reason {
        case .absent: reason = String(localized: "capability.reason.absent")
        case .tooOld: reason = String(localized: "capability.reason.tooOld")
        case .probeFailed: reason = String(localized: "capability.reason.probeFailed")
        case nil: reason = ""
        }
        // A present-but-too-old gh shows BOTH the detected version and the
        // unsupported state (VAL-HEALTH-027); absence shows the bare reason.
        if let version = github.version {
            return .outdated(
                String(format: String(localized: "capability.unavailableAt %@ %@"), version, reason)
            )
        }
        let summary = String(format: String(localized: "capability.unavailable %@"), reason)
        return github.present ? .outdated(summary) : .missing(summary)
    }

    private func npxStatus(_ npx: CapabilityReport.NpxCapability) -> InstallerRow.Status {
        if npx.resolvable {
            return .ready(
                String(
                    format: String(localized: "capability.available %@"), npx.skillsVersion ?? "?"))
        }
        let summary = String(
            format: String(localized: "capability.unavailable %@"),
            String(localized: "capability.reason.unresolvable"))
        return state.installedPath(of: .node) == nil ? .missing(summary) : .outdated(summary)
    }
}

/// One CLI: a status symbol, its probe summary and location, and the action
/// that fits its state (Install, Update/Reinstall, or Show in Finder).
private struct InstallerRow: View {
    enum Status {
        case ready(String)
        case outdated(String)
        case missing(String)

        var summary: String {
            switch self {
            case .ready(let text), .outdated(let text), .missing(let text): text
            }
        }
    }

    @EnvironmentObject private var state: AppState
    let tool: InstallerTool
    let title: LocalizedStringKey
    let token: String
    let status: Status?

    var body: some View {
        HStack(spacing: 10) {
            statusSymbol
                .font(.title2)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                HStack(spacing: 0) {
                    AXToken(token: token)
                    Text(status?.summary ?? String(localized: "capability.checking"))
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .contain)
                .font(.caption)
                .foregroundStyle(.secondary)
                if let path = state.installedPath(of: tool) {
                    Text(verbatim: path)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let failure = state.installerFailures[tool] {
                    Text(verbatim: failure)
                        .font(.caption.monospaced())
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            action
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var statusSymbol: some View {
        switch status {
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Available")
        case .outdated:
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .accessibilityLabel("Needs attention")
        case .missing:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Not installed")
        case nil:
            ProgressView()
                .controlSize(.small)
        }
    }

    @ViewBuilder private var action: some View {
        if state.installerInFlight == tool {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Working…")
                    .foregroundStyle(.secondary)
            }
        } else if let status {
            let busy = state.installerInFlight != nil
            switch status {
            case .missing:
                let title: LocalizedStringKey = AppState.brewURL == nil ? "Download…" : "Install"
                Button(title) {
                    state.runInstaller(tool, action: .install)
                }
                .disabled(busy)
            case .ready, .outdated:
                if state.isManagedByHomebrew(tool) {
                    Menu("Update") {
                        Button("Reinstall") {
                            state.runInstaller(tool, action: .reinstall)
                        }
                    } primaryAction: {
                        state.runInstaller(tool, action: .upgrade)
                    }
                    .fixedSize()
                    .disabled(busy)
                } else if let path = state.installedPath(of: tool) {
                    Button("Show in Finder") {
                        state.revealInFinder([path])
                    }
                }
            }
        }
    }
}
