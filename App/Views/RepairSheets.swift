import SukiruCore
import SwiftUI

/// The double-booked arbitration sheet (D10, VAL-REPAIR-016): exactly two
/// explicit choices — keep the Vercel ledger or keep the GitHub ledger —
/// each with its consequences spelled out, and NO default (nothing is
/// preselected, Return does not confirm). Dismissing the sheet (Cancel /
/// Escape) creates no batch; only an explicit choice builds one.
struct ArbitrationSheet: View {
    @EnvironmentObject private var state: AppState

    /// keep-github re-anchors through `gh skill install` (D10); with gh
    /// unavailable the choice is disabled and says why (§8).
    private var ghUnavailable: Bool {
        state.capabilities?.github.available == false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 0) {
                AXToken(token: "sukiru.pending.arbitration.title")
                Text("Resolve Double-Booking")
                    .font(.headline)
            }
            .accessibilityElement(children: .contain)
            if let draft = state.repairDraft {
                Text(
                    String(
                        format: String(localized: "arbitration.explainer %@"),
                        draft.finding.skillName ?? "-")
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            keepVercelChoice
            keepGitHubChoice
            HStack {
                Spacer()
                Button {
                    state.showingArbitrationSheet = false
                } label: {
                    Text("Cancel")
                }
                .axButtonToken("sukiru.pending.arbitration.cancel")
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    /// D10 keep-vercel: re-install from the vercel lock's recorded source;
    /// content resets to upstream, local edits are lost, and the re-install
    /// erases the GitHub frontmatter provenance.
    private var keepVercelChoice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                state.confirmArbitration(keepVercel: true)
            } label: {
                Text("Keep Vercel Ledger")
            }
            .axButtonToken("sukiru.pending.arbitration.keepVercel")
            .keyboardShortcut("v", modifiers: [])
            Text("arbitration.keepVercel.consequence")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    /// D10 keep-github: FIRST the danger-flagged `npx skills remove`
    /// (deleting by name across ownership is the point), THEN
    /// `gh skill install --force` re-anchoring the recorded provenance;
    /// content resets to the gh-recorded ref, local edits are lost.
    private var keepGitHubChoice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                state.confirmArbitration(keepVercel: false)
            } label: {
                Text("Keep GitHub Ledger")
            }
            .axButtonToken(
                "sukiru.pending.arbitration.keepGitHub", disabled: ghUnavailable
            )
            .disabled(ghUnavailable)
            .keyboardShortcut("g", modifiers: [])
            Text("arbitration.keepGitHub.consequence")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if ghUnavailable {
                Text("arbitration.keepGitHub.needsGH")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The ownerless adopt sheet (D11, VAL-REPAIR-051): the user supplies BOTH
/// the `owner/repo` source and the repo-relative skill path — neither field
/// is prefilled and the proceed control stays disabled (`.disabled` AX
/// suffix) while either is empty. The merge-overwrite warning is always
/// visible: upstream content keeps extra local files but overwrites
/// colliding ones.
struct AdoptSheet: View {
    @EnvironmentObject private var state: AppState

    private var canProceed: Bool {
        !state.adoptRepo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !state.adoptPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 0) {
                AXToken(token: "sukiru.pending.adopt.title")
                Text("Adopt into GitHub Ledger")
                    .font(.headline)
            }
            .accessibilityElement(children: .contain)
            Text("adopt.explainer")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                Text("Repository (owner/repo)")
                    .font(.caption.weight(.medium))
                TextField("owner/repo", text: $state.adoptRepo)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("sukiru.pending.adopt.repo")
                Text("Path in Repository")
                    .font(.caption.weight(.medium))
                TextField("path/to/skill", text: $state.adoptPath)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("sukiru.pending.adopt.path")
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                AXToken(token: "sukiru.pending.adopt.warning")
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("adopt.mergeWarning")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .contain)
            HStack {
                Spacer()
                Button {
                    state.showingAdoptSheet = false
                } label: {
                    Text("Cancel")
                }
                .axButtonToken("sukiru.pending.adopt.cancel")
                .keyboardShortcut(.cancelAction)
                Button {
                    state.confirmAdoption()
                } label: {
                    Text("Adopt")
                }
                .axButtonToken("sukiru.pending.adopt.confirm", disabled: !canProceed)
                .disabled(!canProceed)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
