import Foundation

/// The scan's second phase: content hashes for every discovered placement.
extension InventoryScanner {
    struct PendingHash {
        let index: Int
        let path: String
        let canonicalPath: String?

        /// Placements sharing a canonical directory share its content.
        var key: String { canonicalPath.map { "canonical:" + $0 } ?? "path:" + path }
    }

    /// Hash results written from concurrent workers.
    final class HashResults: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [Int: Result<String, Issue>] = [:]

        func set(_ result: Result<String, Issue>, at index: Int) {
            lock.lock()
            results[index] = result
            lock.unlock()
        }

        func result(at index: Int) -> Result<String, Issue>? {
            lock.lock()
            defer { lock.unlock() }
            return results[index]
        }
    }

    /// Hashes every discovered placement, reading each canonical directory
    /// once and spreading directories across cores. Most placements are
    /// symlinks into a few shared stores. A failed directory is re-hashed per
    /// placement so each issue names that placement's own path.
    func hashPlacements(in outcome: inout Outcome) {
        let pending = outcome.pendingHashes
        var representatives: [String: String] = [:]
        var keys: [String] = []
        for item in pending where representatives[item.key] == nil {
            representatives[item.key] = item.path
            keys.append(item.key)
        }
        let paths = keys.map { representatives[$0] ?? "" }
        let results = HashResults()
        let hasher = self.hasher
        DispatchQueue.concurrentPerform(iterations: paths.count) { index in
            results.set(hasher.computedHash(ofSkillAtPath: paths[index]), at: index)
        }
        var hashesByKey: [String: Result<String, Issue>] = [:]
        for (index, key) in keys.enumerated() {
            hashesByKey[key] = results.result(at: index)
        }
        for item in pending {
            var result = hashesByKey[item.key]
            if case .failure = result, representatives[item.key] != item.path {
                result = hasher.computedHash(ofSkillAtPath: item.path)
            }
            switch result {
            case .success(let hash):
                outcome.placements[item.index] = outcome.placements[item.index]
                    .withContentHash(hash)
            case .failure(let issue):
                outcome.issues.append(issue)
            case nil:
                break
            }
        }
    }
}

extension DiscoveredPlacement {
    fileprivate func withContentHash(_ hash: String) -> DiscoveredPlacement {
        DiscoveredPlacement(
            name: name,
            placement: Placement(
                path: placement.path,
                kind: placement.kind,
                linkTarget: placement.linkTarget,
                canonicalPath: placement.canonicalPath,
                contentHash: hash,
                internal: placement.internal,
                managingAgent: placement.managingAgent),
            workspaceID: workspaceID,
            scopeGroup: scopeGroup,
            candidateHosts: candidateHosts,
            skillFilePath: skillFilePath,
            githubProvenance: githubProvenance)
    }
}
