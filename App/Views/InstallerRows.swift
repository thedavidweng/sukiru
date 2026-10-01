import SukiruCore
import SwiftUI

/// A CLI row's probe verdict and the summary shown under its title.
enum InstallerStatus {
    case ready(String)
    case outdated(String)
    case missing(String)

    var summary: String {
        switch self {
        case .ready(let text), .outdated(let text), .missing(let text): text
        }
    }
}

/// The row's leading symbol; a spinner while the probes run.
struct InstallerStatusSymbol: View {
    let status: InstallerStatus?

    var body: some View {
        Group {
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
        .font(.title2)
        .frame(width: 24)
    }
}

/// The Vercel skills CLI, run through npx. Sukiru never downloads or updates
/// it on its own: the row offers Download when it is missing and Update when
/// the registry has a newer release, and runs npx only on that click.
struct SkillsCLIRow: View {
    @EnvironmentObject private var state: AppState
    let status: InstallerStatus?

    var body: some View {
        HStack(spacing: 10) {
            InstallerStatusSymbol(status: status)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "skills CLI")
                HStack(spacing: 0) {
                    AXToken(token: "sukiru.settings.capability.npx")
                    Text(status?.summary ?? String(localized: "capability.checking"))
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .contain)
                .font(.caption)
                .foregroundStyle(.secondary)
                if let failure = state.skillsFetchFailure {
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

    @ViewBuilder private var action: some View {
        if state.skillsFetchInFlight {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Working…")
                    .foregroundStyle(.secondary)
            }
        } else if let npx = state.capabilities?.npx, npx.reason != .absent {
            let busy = state.capabilityCheckRunning || state.installerInFlight != nil
            switch status {
            case .missing:
                Button("Download") { state.fetchSkillsCLI() }
                    .disabled(busy)
                    .help("Download the skills CLI with npx")
            case .outdated:
                Button("Update") { state.fetchSkillsCLI() }
                    .disabled(busy)
                    .help("Update the skills CLI to the latest release with npx")
            case .ready, nil:
                EmptyView()
            }
        }
    }
}

/// One CLI: a status symbol, its probe summary and location, and the action
/// that fits its state (Install, Update/Reinstall, or Show in Finder).
struct InstallerRow: View {
    @EnvironmentObject private var state: AppState
    let tool: InstallerTool
    let title: LocalizedStringKey
    let token: String
    let status: InstallerStatus?

    var body: some View {
        HStack(spacing: 10) {
            InstallerStatusSymbol(status: status)
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
