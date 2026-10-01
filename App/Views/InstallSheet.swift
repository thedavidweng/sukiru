import SukiruCore
import SwiftUI

/// The installer-choice sheet: pick npx skills (Vercel ledger)
/// or gh skill (GitHub ledger), see the consequences spelled out, choose
/// the target scope (user global vs a project root), and for gh the agent
/// (and optional pin). "Add to Pending Changes" builds the Command Batch
/// and lands it on the standard review → execute → rollback flow.
struct InstallSheet: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let result = state.selectedSearchResult() {
                resultSummary(result)
            }
            installerChoice
            targetScope
            Divider()
            if let error = state.installError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack(spacing: 12) {
                Button("Cancel") {
                    state.showingInstallSheet = false
                }
                .axButtonToken("sukiru.search.install.cancel")
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    state.confirmInstall()
                } label: {
                    Text("Add to Pending Changes")
                }
                .axButtonToken(
                    "sukiru.search.install.confirm",
                    disabled: !canConfirm
                )
                .disabled(!canConfirm)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                AXToken(token: "sukiru.search.install.title")
                Text("Install Skill")
                    .font(.title3.weight(.semibold))
            }
            .accessibilityElement(children: .contain)
            // swiftlint:disable line_length
            Text(
                "The install is a reviewable Command Batch: it runs through Pending Changes with a snapshot, post-run diff, and rollback."
            )
            // swiftlint:enable line_length
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func resultSummary(_ result: SkillSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.name)
                .font(.headline)
            if let repo = result.repo {
                Text(repo)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - installer choice

    private var installerChoice: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                AXToken(token: "sukiru.search.install.installer")
                Text("Installer")
                    .font(.headline)
            }
            .accessibilityElement(children: .contain)
            Picker("Installer", selection: $state.installInstaller) {
                Text("npx skills (Vercel)").tag(InstallerChoice.vercel)
                Text("gh skill (GitHub)").tag(InstallerChoice.github)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text(state.installConsequenceCopy(state.installInstaller))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !state.installCapabilityAvailable(state.installInstaller) {
                HStack(spacing: 0) {
                    AXToken(token: "sukiru.search.install.blocked")
                    let hint: LocalizedStringKey =
                        "The required CLI is unavailable in this environment; this installer cannot build a batch."
                    Text(hint)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                .accessibilityElement(children: .contain)
            }
        }
    }

    // MARK: - target scope

    private var targetScope: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                AXToken(token: "sukiru.search.install.scope")
                Text("Target")
                    .font(.headline)
            }
            .accessibilityElement(children: .contain)
            Picker("Target", selection: $state.installTarget) {
                Text("User (global)").tag(InstallTarget.user)
                ForEach(state.projectRoots, id: \.self) { root in
                    Text(root)
                        .tag(InstallTarget.project(root: root))
                        .lineLimit(2)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if case .project(let root) = state.installTarget {
                Text("Installs into \(root) at project scope.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if state.installInstaller == .github {
                githubAgentFields
            }
        }
    }

    /// gh-only fields: the target agent (--agent, required) and the optional
    /// pin ref. The agent list is the canonical store host plus the common
    /// agent hosts (probe-verified `--agent` values); user picks one.
    private var githubAgentFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                AXToken(token: "sukiru.search.install.agent")
                Text("Agent target")
                    .font(.callout.weight(.medium))
            }
            .accessibilityElement(children: .contain)
            Picker("Agent", selection: $state.ghInstallAgent) {
                ForEach(AppState.ghInstallAgentOptions, id: \.self) { agent in
                    Text(agent).tag(agent)
                }
            }
            .labelsHidden()
            Text("install.gh.agentNote \(state.ghInstallAgent)")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                AXToken(token: "sukiru.search.install.pin")
                TextField("Pin ref (optional: tag or SHA)", text: $state.ghPinRef)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
            }
            .accessibilityElement(children: .contain)
        }
    }

    private var canConfirm: Bool {
        let ghReady =
            state.installInstaller != .github
            || !state.ghInstallAgent.isEmpty
        return ghReady && state.installCapabilityAvailable(state.installInstaller)
    }
}
