import SukiruCore
import SwiftUI

/// The Pending Changes surface: the cart of queued repairs and the Command
/// Batch safety model made visible.
///
/// - **Cart** — repairs queued from Health, each removable, checked out
///   together into one batch with one snapshot (`sukiru.pending.checkout`).
/// - **Decision** — a Health "Choose Repair…" deep-link opens the decision
///   panel (`RepairDraftPanel`): ownership-routed repair options, with
///   capability-blocked options rendered as hints. A choice joins the cart.
/// - **Confirm** — checkout opens `BatchConfirmSheet`, the single
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
                    if !state.cart.isEmpty {
                        cartList
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
                        "Repairs you queue in Health collect here, so you can review and apply them together in one batch with one snapshot."
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
            } else if !state.cart.isEmpty {
                checkoutHeader
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
            || state.lastExecutionFailure != nil || !state.cart.isEmpty
    }

    private var cartList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(state.cart) { item in
                CartRow(item: item)
                if item != state.cart.last {
                    Divider()
                }
            }
        }
    }

    private var checkoutHeader: some View {
        HStack(spacing: 12) {
            Text("\(state.cart.count) queued changes")
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            Spacer()
            Button("Clear") {
                state.clearCart()
            }
            .axButtonToken("sukiru.pending.clear")
            Button("Review & Apply") {
                state.checkout()
            }
            .buttonStyle(.borderedProminent)
            .axButtonToken("sukiru.pending.checkout")
            .help("Apply every queued repair in one batch, with one snapshot")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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

/// One queued repair: what it fixes, what it will do, and a remove button.
private struct CartRow: View {
    @EnvironmentObject private var state: AppState
    let item: AppState.CartItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.finding.skillName ?? item.finding.title)
                    .font(.callout.weight(.medium))
                Text(verbatim: item.title)
                    .font(.caption)
                Text(verbatim: item.finding.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                state.removeFromCart(item)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove from Pending Changes")
            .accessibilityLabel("Remove from Pending Changes")
        }
        .padding(.vertical, 8)
    }
}
