import SukiruCore
import SwiftUI

/// The Settings surface. M3 scope (D20): the project-roots list — add and
/// remove folders, with a Refresh that re-scans and updates Library/Health
/// (`sukiru.settings.projects.add`, `sukiru.settings.projects.remove`,
/// `sukiru.settings.projects.refresh`). Plus a read-only environment section
/// echoing the CLI's environment overrides.
struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                projectRootsSection
                capabilitiesSection
                environmentSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - project roots (D20)

    private var projectRootsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Project roots")
                .font(.headline)
            if state.projectRoots.isEmpty {
                Text("No project roots. Add a folder to scan project-scope skills.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(state.projectRoots, id: \.self) { root in
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(root)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                        Spacer()
                        Button("Remove") {
                            state.removeProjectRoot(root)
                        }
                        .axButtonToken(
                            "sukiru.settings.projects.remove.\(AXTokens.path(root))")
                    }
                    .padding(.vertical, 2)
                }
            }
            HStack(spacing: 12) {
                Button("Add Folder…") {
                    state.addProjectRootViaPanel()
                }
                .axButtonToken("sukiru.settings.projects.add")
                Button("Refresh") {
                    state.rescan()
                }
                .axButtonToken(
                    "sukiru.settings.projects.refresh",
                    disabled: state.healthCheckRunning
                )
                .disabled(state.healthCheckRunning)
            }
        }
    }

    // MARK: - capabilities (D6, surfaced per VAL-CROSS-001)

    private var capabilitiesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                AXToken(token: "sukiru.settings.capabilities")
                Text("Capabilities")
                    .font(.headline)
            }
            .accessibilityElement(children: .contain)
            if let caps = state.capabilities {
                capabilityRow(
                    token: "sukiru.settings.capabilities.github",
                    name: "gh CLI",
                    value: ghSummary(caps.github)
                )
                capabilityRow(
                    token: "sukiru.settings.capabilities.npx",
                    name: "npx skills",
                    value: npxSummary(caps.npx)
                )
            } else {
                Text("Detecting…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("Capability probes match `sukiru-cli capabilities` for this environment.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func capabilityRow(
        token: String, name: LocalizedStringKey, value: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            AXToken(token: token)
            Text(name)
                .font(.callout.weight(.medium))
                .frame(width: 120, alignment: .trailing)
            Text(value)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .contain)
    }

    private func ghSummary(_ ghCapability: CapabilityReport.GitHubCapability) -> String {
        if ghCapability.available {
            return String(
                format: String(localized: "capability.available %@"),
                ghCapability.version ?? "?")
        }
        let reason: String
        switch ghCapability.reason {
        case .absent: reason = String(localized: "capability.reason.absent")
        case .tooOld: reason = String(localized: "capability.reason.tooOld")
        case .probeFailed: reason = String(localized: "capability.reason.probeFailed")
        case nil: reason = ""
        }
        return String(format: String(localized: "capability.unavailable %@"), reason)
    }

    private func npxSummary(_ npx: CapabilityReport.NpxCapability) -> String {
        if npx.resolvable {
            return String(
                format: String(localized: "capability.available %@"),
                npx.skillsVersion ?? "?")
        }
        return String(
            format: String(localized: "capability.unavailable %@"),
            String(localized: "capability.reason.unresolvable"))
    }

    // MARK: - environment

    private var environmentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Environment")
                .font(.headline)
            field("Library root", state.environment.home)
            if !state.environment.projectRoots.isEmpty {
                field("SUKIRU_ROOTS", state.environment.projectRoots.joined(separator: ":"))
            }
            Text(
                "These paths come from SUKIRU_HOME/SUKIRU_ROOTS, identical to the CLI. Relaunch to change them."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func field(_ name: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name)
                .font(.callout.weight(.medium))
                .frame(width: 120, alignment: .trailing)
            Text(value)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}
