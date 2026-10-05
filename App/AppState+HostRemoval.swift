import Foundation
import SukiruCore

/// Remove Skills from Agent: one request per Agent Host and concrete scope,
/// queued in Pending Changes beside repairs and Library changes (ADR 0012).
@MainActor
extension AppState {
    /// The concrete scopes a removal can target: the user scope, then each
    /// added project root.
    var hostRemovalBuckets: [String] {
        ["user"] + projectRoots.map { "project:" + $0 }
    }

    /// Disk evidence for planning. It is read again for every sheet and
    /// checkout because the builder must not plan against a stale disk.
    func makeHostRemovalContext() -> HostRemovalContext? {
        guard let report else { return nil }
        return HostRemovalContext(
            environment: Self.makeEnvironment(roots: projectRoots), report: report,
            projectRoots: projectRoots)
    }

    func queuedHostRemoval(hostID: String, bucket: String) -> HostRemovalRequest? {
        hostRemovalQueue.first { $0.hostID == hostID && $0.bucket == bucket }
    }

    /// Queues a plan's request, replacing an earlier one for the same host
    /// and scope. A plan with problems has nothing to run.
    func queueHostRemoval(_ plan: HostRemovalPlan) {
        guard plan.problems.isEmpty else { return }
        hostRemovalQueue.removeAll { $0.hostID == plan.hostID && $0.bucket == plan.bucket }
        hostRemovalQueue.append(plan.request)
    }

    func removeFromCart(_ request: HostRemovalRequest) {
        hostRemovalQueue.removeAll { $0 == request }
    }

    /// Drops removals whose project root is gone. Stale names are left for
    /// checkout, which lists them as not included instead of guessing.
    func pruneHostRemovals() {
        let buckets = Set(hostRemovalBuckets)
        hostRemovalQueue.removeAll { !buckets.contains($0.bucket) }
    }

    func hostRemovalScopeTitle(_ bucket: String) -> String {
        guard bucket.hasPrefix("project:") else { return String(localized: "User Library") }
        return URL(fileURLWithPath: String(bucket.dropFirst("project:".count))).lastPathComponent
    }
}
