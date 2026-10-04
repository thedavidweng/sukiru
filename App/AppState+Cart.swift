import Foundation
import SukiruCore

/// Pending Changes as a cart: Health repairs queue up here, and checkout
/// builds them into one batch with one snapshot and one confirmation.
/// Nothing runs while an item sits in the cart.
@MainActor
extension AppState {
    /// One queued repair. It holds the finding itself rather than a finding
    /// ID, because IDs are minted per report and the cart outlives rescans.
    struct CartItem: Identifiable, Equatable {
        let finding: Finding
        let action: DecisionAction
        let choice: DecisionChoice?

        var id: String {
            ([FindingID.baseID(for: finding)] + finding.evidence.map(\.detail))
                .joined(separator: "|")
        }
    }

    func cartItem(for finding: Finding) -> CartItem? {
        cart.first { $0.finding == finding }
    }

    /// Queues a repair, replacing any earlier choice for the same finding.
    func queue(_ action: DecisionAction, choice: DecisionChoice? = nil, for finding: Finding) {
        let item = CartItem(finding: finding, action: action, choice: choice)
        if let index = cart.firstIndex(where: { $0.finding == finding }) {
            cart[index] = item
        } else {
            cart.append(item)
        }
    }

    /// Queues the one-click fix of every given finding that has one.
    func queueFixes(_ entries: [FindingEntry]) {
        for entry in entries {
            if let action = oneClickFix(for: entry.finding) {
                queue(action, for: entry.finding)
            }
        }
    }

    func removeFromCart(_ item: CartItem) {
        cart.removeAll { $0 == item }
    }

    func clearCart() {
        cart = []
        lifecycleQueue = []
        hookState.queue = []
    }

    /// Queued repairs plus queued Library changes.
    var queuedChangeCount: Int {
        cart.count + lifecycleQueue.count + hookState.queue.count
    }

    /// Builds every queued repair and Library change into one batch and
    /// opens the confirmation. Changes that no longer apply are listed there
    /// instead of blocking the rest.
    func checkout() {
        guard let report, queuedChangeCount > 0 else { return }
        let ids = FindingID.assignments(for: report.findings)
        let decisions = cart.compactMap { item -> DecisionEntry? in
            guard let id = ids.first(where: { $0.finding == item.finding })?.id else {
                return nil
            }
            return DecisionEntry(findingID: id, action: item.action, choice: item.choice)
        }
        let built = CommandBatchBuilder().buildApplicable(
            report: report, decisions: decisions, lifecycle: lifecycleQueue)
        do {
            guard let hookPlan = try hookBatch() else {
                propose(built.batch, skipped: built.skipped)
                return
            }
            let batch = CommandBatch(
                id: hookPlan.batch.id, createdAt: hookPlan.batch.createdAt,
                findingRefs: (built.batch?.findingRefs ?? []) + hookPlan.batch.findingRefs,
                decisions: built.batch?.decisions ?? [],
                commands: (built.batch?.commands ?? []) + hookPlan.batch.commands,
                snapshotID: nil, status: .proposed)
            propose(batch, skipped: built.skipped + hookPlan.instructions)
        } catch {
            propose(nil, skipped: [error.localizedDescription])
        }
    }

    /// Keeps queued repairs attached to the same findings after a rescan,
    /// and drops the ones whose problem is gone. This is also how a checkout
    /// empties the cart: its post-run rescan drops every repair that worked,
    /// and the ones that failed stay queued for another try. Library changes
    /// follow their skill into the new scan and leave with it; an update,
    /// whose skill stays, leaves when its batch succeeds.
    func pruneCart(using report: ScanReport) {
        cart = cart.compactMap { item in
            let base = FindingID.baseID(for: item.finding)
            let candidates = report.findings.filter { FindingID.baseID(for: $0) == base }
            let fresh = candidates.first { $0 == item.finding } ?? candidates.first
            return fresh.map { CartItem(finding: $0, action: item.action, choice: item.choice) }
        }
        lifecycleQueue = lifecycleQueue.compactMap { request in
            let id = Self.skillID(request.skill)
            return report.skills.first { Self.skillID($0) == id }
                .map { LifecycleRequest(skill: $0, action: request.action) }
        }
    }
}
