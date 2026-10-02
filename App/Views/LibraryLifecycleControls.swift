import SukiruCore
import SwiftUI

extension LifecycleAction {
    var title: LocalizedStringResource {
        switch self {
        case .update: "Update"
        case .uninstall: "Uninstall"
        }
    }
}

/// Update and Uninstall for a skill one ledger owns, queued in Pending
/// Changes. Agent-managed and ownerless skills (ambiguous ones included) get
/// nothing here: their own notices and sections say what applies to them.
struct LibraryLifecycleControls: View {
    @EnvironmentObject private var state: AppState

    let skill: Skill

    private let doubleBookedNote: LocalizedStringKey =
        "Both installers claim this skill. Choose which one keeps it in Health before you update or uninstall it."

    var body: some View {
        if let request = state.queuedLifecycle(for: skill) {
            HStack {
                Spacer()
                Button {
                    state.removeFromCart(request)
                } label: {
                    Label {
                        Text(request.action.title)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                    }
                }
                .help("Queued in Pending Changes. Click to remove it.")
            }
            .disabled(state.batchMutationInFlight)
        } else if skill.ownership == .doubleBooked {
            Text(doubleBookedNote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if skill.ownership == .vercel || skill.ownership == .github {
            let updateBlocker = state.lifecycleBlocker(.update, for: skill)
            let uninstallBlocked = state.lifecycleBlocker(.uninstall, for: skill) != nil
            if updateBlocker == .needsGitHubCLI {
                Text("Updating needs the GitHub CLI. Get it in Settings > Installers.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if updateBlocker == .touchesVercelRecord {
                Text("library.update.touchesVercelRecord")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if updateBlocker == .dropsVercelLockData {
                Text("library.update.dropsVercelLockData")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Uninstall", role: .destructive) {
                    state.queueLifecycle(.uninstall, for: skill)
                }
                .disabled(uninstallBlocked)
                .axButtonToken("sukiru.library.detail.uninstall", disabled: uninstallBlocked)
                .help("Add uninstalling this skill to Pending Changes")
                Button("Update") {
                    state.queueLifecycle(.update, for: skill)
                }
                .disabled(updateBlocker != nil)
                .axButtonToken("sukiru.library.detail.update", disabled: updateBlocker != nil)
                .help("Add updating this skill through its installer to Pending Changes")
            }
            .disabled(state.batchMutationInFlight)
        }
    }
}

/// Library toolbar: queues an update for every skill an installer owns
/// among `skills`, then opens the batch confirmation (like Fix All).
struct UpdateAllButton: View {
    @EnvironmentObject private var state: AppState

    let skills: [Skill]

    var body: some View {
        let none = state.updatableSkills(skills).isEmpty
        let disabled = none || state.batchMutationInFlight
        Button {
            state.updateAll(skills)
        } label: {
            Label("Update All", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(disabled)
        .axButtonToken("sukiru.library.updateAll", disabled: disabled)
        .help(help(nothingUpdatable: none))
    }

    private func help(nothingUpdatable: Bool) -> LocalizedStringKey {
        nothingUpdatable && !state.withheldUpdates(skills).isEmpty
            ? "None of these skills can be updated here. Select one to see why."
            : "Update every skill an installer manages here, reviewed in one batch"
    }
}

/// Lists the folders the last update check could not check.
struct UpdateCheckFailureAlert: ViewModifier {
    @EnvironmentObject private var state: AppState

    func body(content: Content) -> some View {
        content.alert(
            "Some skills could not be checked for updates",
            isPresented: Binding(
                get: { !state.updateCheck.failures.isEmpty },
                set: { if !$0 { state.updateCheck.failures = [] } })
        ) {
            Button("OK") {}
        } message: {
            Text(verbatim: state.updateCheck.failures.joined(separator: "\n\n"))
        }
    }
}

/// Library toolbar: asks gh which GitHub-ledger skills have upstream
/// updates (`gh skill update --dry-run`, read-only).
struct CheckForUpdatesButton: View {
    @EnvironmentObject private var state: AppState

    let skills: [Skill]

    var body: some View {
        if state.updateCheck.running {
            ProgressView()
                .controlSize(.small)
        } else {
            let disabled = !state.canCheckGitHubUpdates(skills)
            Button {
                state.checkGitHubUpdates(skills)
            } label: {
                Label("Check for Updates", systemImage: "arrow.down.circle")
            }
            .disabled(disabled)
            .axButtonToken("sukiru.library.checkUpdates", disabled: disabled)
            .help("Ask gh skill whether GitHub-installed skills have newer versions")
        }
    }
}
