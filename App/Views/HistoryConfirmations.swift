import SwiftUI

/// The confirmations for rolling back and deleting history. They live on the
/// window rather than the Snapshots list, so the Repair menu's rollback
/// command confirms from any surface.
struct HistoryConfirmations: ViewModifier {
    @EnvironmentObject private var state: AppState

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Roll Back This Batch?",
                isPresented: Binding(
                    get: { state.historyPendingRollback != nil },
                    set: { if !$0 { state.historyPendingRollback = nil } })
            ) {
                Button("Roll Back", role: .destructive) {
                    if let batchID = state.historyPendingRollback {
                        state.rollbackBatch(batchID)
                    }
                }
            } message: {
                Text("snapshots.rollback.message")
            }
            .confirmationDialog(
                "Delete Snapshot?",
                isPresented: Binding(
                    get: { !state.historyPendingDeletion.isEmpty },
                    set: { if !$0 { state.historyPendingDeletion = [] } })
            ) {
                Button("Delete", role: .destructive) {
                    state.deleteHistory(batchIDs: state.historyPendingDeletion)
                }
            } message: {
                Text("snapshots.delete.message")
            }
    }
}
