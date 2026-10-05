import Foundation

/// Classifies the discovery entries in one host folder against scan ownership.
struct HostRemovalSelection {
    let root: String
    let facts: HostRemovalContext.ScopeFacts
    let skills: [Skill]

    var sharedFolder: Bool {
        root == facts.sharedRoot
            || facts.nativeRoots.values.filter { $0 == root }.count > 1
    }

    func entries() -> (removed: [HostRemovalEntry], kept: [HostRemovalKeptEntry]) {
        var removed: [HostRemovalEntry] = []
        var kept: [HostRemovalKeptEntry] = []
        for skill in skills.sorted(by: { $0.name < $1.name }) {
            for placement in skill.placements.sorted(by: { $0.path < $1.path })
            where placement.path.hasPrefix(root + "/") {
                let entry = HostRemovalEntry(name: skill.name, path: placement.path)
                if let reason = reason(skill: skill, placement: placement) {
                    kept.append(HostRemovalKeptEntry(entry: entry, reason: reason))
                } else {
                    removed.append(entry)
                }
            }
        }
        return (removed, kept)
    }

    func visible(
        host: HostSpec, removed: [HostRemovalEntry], deletions: [String]
    ) -> [HostRemovalEntry] {
        var loadingRoots = HostNameCollisionRule.loadingRoots(
            for: host.id, in: facts.workspaces, present: true)
        if HostRemovalContext.isUniversal(host) { loadingRoots.insert(facts.sharedRoot) }
        let removedPaths = Set(removed.map(\.path))
        let deletedTargets = Set(
            deletions.map {
                (facts.sharedCanonicalRoot ?? facts.sharedRoot) + "/"
                    + HostRemovalContext.folderName($0)
            })
        return skills.flatMap { skill in
            skill.placements.filter { placement in
                placement.kind != .brokenSymlink && !removedPaths.contains(placement.path)
                    && loadingRoots.contains { placement.path.hasPrefix($0 + "/") }
                    && !deletedTargets.contains(placement.canonicalPath ?? placement.path)
            }.map { HostRemovalEntry(name: skill.name, path: $0.path) }
        }.sorted { ($0.name, $0.path) < ($1.name, $1.path) }
    }

    private func reason(skill: Skill, placement: Placement) -> HostRemovalReason? {
        let folder = HostRemovalContext.folderName(skill.name)
        if placement.managingAgent != nil || skill.ownership == .agent { return .agentManaged }
        let ambiguous =
            skill.name == "*" || skill.name.hasPrefix("-")
            || skill.ambiguous || skill.ownership == .doubleBooked
            || skills.contains(where: {
                $0.name != skill.name && HostRemovalContext.folderName($0.name) == folder
            })
        if ambiguous { return .ambiguous }
        if skill.ownership == .github { return .githubLedger }
        if skill.ownership == .ownerless { return .ownerless }
        if sharedFolder { return .sharedFolder }
        guard placement.path == root + "/" + folder else { return .unofficialEntry }
        if placement.kind == .directory, skill.provenance.vercel != nil { return nil }
        if placement.kind == .symlink, let shared = facts.sharedCanonicalRoot {
            return placement.canonicalPath == shared + "/" + folder ? nil : .unofficialEntry
        }
        return .unofficialEntry
    }

}
