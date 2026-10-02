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
        // The scroll view stays even when empty, so the column starts with
        // one and the toolbar matches every other surface.
        ScrollView {
            if hasContent {
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
        .overlay {
            if !hasContent {
                SurfacePlaceholder(
                    token: "sukiru.pending.empty",
                    icon: "list.bullet.rectangle",
                    title: "No pending changes",
                    // swiftlint:disable line_length
                    explanation:
                        "Repairs and installs arrive here as command batches you can review. Use a finding's Fix button in Health, or Install in Search."
                        // swiftlint:enable line_length
                )
            }
        }
        .overlay(alignment: .topLeading) {
            if hasContent {
                AXToken(token: "sukiru.pending.title")
            }
        }
        .surfaceBar {
            if state.batchMutationInFlight && hasContent {
                progressHeader
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
