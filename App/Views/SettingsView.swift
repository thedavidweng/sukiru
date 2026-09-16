import SukiruCore
import SwiftUI

/// The Settings surface. M3 scope: the explicit Refresh control
/// (`sukiru.settings.refresh` — the app keeps no filesystem watchers, D7);
/// the project-roots list (D20 — add/remove folders,
/// `sukiru.settings.projects.add` / `.remove`); the launch-time capability
/// panel (`sukiru.settings.capability.gh` / `.npx`, pending → settled,
/// plus `sukiru.settings.readonlyNotice` when neither CLI is available);
/// and a read-only environment section echoing the CLI's overrides.
struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                refreshSection
                projectRootsSection
                capabilitiesSection
                environmentSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - refresh (VAL-HEALTH-036, D7 no-watchers)

    /// The explicit-Refresh control. The app keeps NO filesystem watchers
    /// (red line): external on-disk changes appear only after Refresh, here
    /// or via ⌘R in the View menu.
    private var refreshSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Library data")
                .font(.headline)
            HStack(spacing: 12) {
                Button("Refresh") {
                    state.rescan()
                }
                .axButtonToken(
                    "sukiru.settings.refresh",
                    disabled: state.healthCheckRunning
                )
                .disabled(state.healthCheckRunning)
                let hint: LocalizedStringKey =
                    "Re-reads the library from disk (⌘R). External changes appear only after Refresh."
                Text(hint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
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
            // The rows render at their D21 labels from the first frame, in a
            // pending state while the (background, never launch-blocking)
            // probes run, then settle without user action (VAL-HEALTH-004).
            if let caps = state.capabilities {
                capabilityRow(
                    token: "sukiru.settings.capability.gh",
                    name: "gh CLI",
                    value: ghSummary(caps.github)
                )
                capabilityRow(
                    token: "sukiru.settings.capability.npx",
                    name: "npx skills",
                    value: npxSummary(caps.npx)
                )
            } else {
                capabilityRow(
                    token: "sukiru.settings.capability.gh",
                    name: "gh CLI",
                    value: String(localized: "capability.checking")
                )
                capabilityRow(
                    token: "sukiru.settings.capability.npx",
                    name: "npx skills",
                    value: String(localized: "capability.checking")
                )
            }
            let neitherCLI =
                state.capabilities.map { !$0.github.available && !$0.npx.resolvable } ?? false
            if neitherCLI {
                // §8: with neither CLI, Sukiru is the full read-only
                // diagnostician — the notice is explicit and labeled
                // (VAL-HEALTH-026).
                HStack(spacing: 0) {
                    AXToken(token: "sukiru.settings.readonlyNotice")
                    // swiftlint:disable line_length
                    let notice: LocalizedStringKey =
                        "Read-only diagnostic mode: neither gh nor Node.js (npx) is available. Sukiru inspects and reports your library, but repairs and installs are unavailable."
                    // swiftlint:enable line_length
                    Text(notice)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                .accessibilityElement(children: .contain)
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
        // A present-but-too-old gh shows BOTH the detected version and the
        // unsupported state (VAL-HEALTH-027); absence shows the bare reason.
        if let version = ghCapability.version {
            return String(
                format: String(localized: "capability.unavailableAt %@ %@"),
                version, reason)
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
