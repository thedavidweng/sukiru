import SukiruCore
import SwiftUI

/// The Pending Changes surface: the Command Batch
/// safety model made visible.
///
/// - **Decision** — a Health "Fix…" deep-link opens the decision
///   panel (`RepairDraftPanel`): ownership-routed repair options, with
///   capability-blocked options rendered as hints.
/// - **Confirm** — the built batch opens `BatchConfirmSheet`, the single
///   confirmation every batch needs before it runs.
/// - **Result** — the terminal record banner (`PendingResultBanners`) while
///   the post-mutation auto-refresh repopulates every other surface.
struct PendingChangesView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Group {
            if hasContent {
                content
            } else {
                SurfacePlaceholder(
                    token: "sukiru.pending.empty",
                    icon: "list.bullet.rectangle",
                    title: "No pending changes",
                    // swiftlint:disable line_length
                    explanation:
                        "Repairs and installs arrive here as reviewable command batches — use a finding's Fix button in Health, or Install in Search."
                        // swiftlint:enable line_length
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $state.showingArbitrationSheet) {
            ArbitrationSheet()
        }
        .sheet(isPresented: $state.showingAdoptSheet) {
            AdoptSheet()
        }
    }

    private var hasContent: Bool {
        state.repairDraft != nil || state.lastExecutionRecord != nil
            || state.lastExecutionFailure != nil
    }

    // MARK: - layout

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if state.batchMutationInFlight {
                progressHeader
                Divider()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PendingResultBanners()
                    if let draft = state.repairDraft {
                        RepairDraftPanel(draft: draft)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlay(alignment: .topLeading) {
            AXToken(token: "sukiru.pending.title")
        }
    }

    private var progressHeader: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            AXToken(token: "sukiru.pending.executing")
            Text("Working…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
