import SukiruCore
import SwiftUI

extension LifecycleAction {
    var title: LocalizedStringResource {
        switch self {
        case .update: "Update"
        case .uninstall: "Uninstall"
        case .pin: "Pin"
        case .unpin: "Unpin"
        case .restore: "Restore Files"
        }
    }
}

extension LifecycleRequest {
    /// The queued-change label in Pending Changes; a pin names its ref.
    var queueTitle: String {
        if action == .pin, let pinRef {
            return String(localized: "Pin to \(pinRef)")
        }
        return String(localized: action.title)
    }
}

/// Update and Uninstall for a skill one ledger owns, queued in Pending
/// Changes. Agent-managed and ownerless skills (ambiguous ones included) get
/// nothing here: their own notices and sections say what applies to them.
///
/// Uninstall sits apart on the leading edge; Update is prominent only when a
/// check found a newer version. Restore Files is a gh write, so it is hidden
/// rather than shown permanently disabled when gh writes are withheld.
struct LibraryLifecycleControls: View {
    @EnvironmentObject private var state: AppState

    let skill: Skill

    var body: some View {
        if let request = state.queuedLifecycle(for: skill) {
            HStack {
                Spacer()
                Button {
                    state.removeFromCart(request)
                } label: {
                    Label(request.queueTitle, systemImage: "checkmark.circle.fill")
                }
                .help("Queued in Pending Changes. Click to remove it.")
            }
            .disabled(state.batchMutationInFlight)
        } else if skill.ownership == .doubleBooked {
            Text(
                "Both installers claim this skill. Choose one in Health to update or uninstall it."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else if skill.ownership == .vercel || skill.ownership == .github {
            let updateBlocker = state.lifecycleBlocker(.update, for: skill)
            if let note = updateBlocker.flatMap(Self.note) {
                Text(note)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                uninstallButton
                Spacer()
                restoreButton
                updateButton(blocked: updateBlocker != nil)
            }
            .disabled(state.batchMutationInFlight)
        }
    }

    /// Why Update is unavailable, when the reason is not already on screen
    /// (the read-only notice covers a missing Node.js).
    private static func note(_ blocker: LifecycleBlocker) -> LocalizedStringKey? {
        switch blocker {
        case .needsGitHubCLI: "Updating needs the GitHub CLI. Get it in Settings > Installers."
        case .touchesVercelRecord: "library.update.touchesVercelRecord"
        case .dropsVercelLockData: "library.update.dropsVercelLockData"
        default: nil
        }
    }

    @ViewBuilder
    private var restoreButton: some View {
        if skill.ownership == .github && state.lifecycleBlocker(.restore, for: skill) == nil {
            Button("Restore Files") {
                state.queueLifecycle(.restore, for: skill)
            }
            .axButtonToken("sukiru.library.detail.restore")
            .help("library.restore.help")
        }
    }

    private var uninstallButton: some View {
        let blocked = state.lifecycleBlocker(.uninstall, for: skill) != nil
        return Button("Uninstall", role: .destructive) {
            state.queueLifecycle(.uninstall, for: skill)
        }
        .disabled(blocked)
        .axButtonToken("sukiru.library.detail.uninstall", disabled: blocked)
        .help("Remove this skill's files (adds to Pending Changes)")
    }

    @ViewBuilder
    private func updateButton(blocked: Bool) -> some View {
        let button = Button("Update") {
            state.queueLifecycle(.update, for: skill)
        }
        .disabled(blocked)
        .axButtonToken("sukiru.library.detail.update", disabled: blocked)
        .help("Update to the latest version (adds to Pending Changes)")
        if state.githubUpdate(for: skill) != nil {
            button.buttonStyle(.borderedProminent)
        } else {
            button
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
            : "Update every skill an installer manages, in one batch"
    }
}

/// Lists the folders the last update check could not check.
struct UpdateCheckFailureAlert: ViewModifier {
    @EnvironmentObject private var state: AppState

    func body(content: Content) -> some View {
        content.alert(
            "Couldn't Check Some Skills for Updates",
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
            .help("Look for newer versions of skills installed with gh skill")
        }
    }
}
