import Foundation

/// Pure capture planning: which ledger
/// paths, placements, payload sources, and watched directories a batch plus
/// the pre-run scan imply. Split from SnapshotStore so the decision logic is
/// reviewable without disk writes.
struct SnapshotPlan: Equatable, Sendable {
    /// Absolute ledger file paths to record, sorted: ALWAYS the global lock
    /// plus every project-lock probe candidate of every touched project root
    /// (both lock files are captured; absent candidates are
    /// recorded so rollback can delete a lock the batch creates there).
    let ledgerPaths: [String]
    /// The placement manifest: every placement of every skill in every
    /// touched workspace, deduped and sorted by path.
    let placements: [PlacementSnapshot]
    /// Absolute paths of skill directories to copy in full, sorted: every
    /// directory placement of every skill the batch's findings name, plus
    /// the in-bounds canonical targets of those skills' symlink placements.
    let payloadSources: [String]
    /// Parent directory of every recorded placement, sorted; restore sweeps
    /// their immediate children for batch-added paths.
    let watchedDirectories: [String]
    /// Container dirs of the affected scope that exist on disk at capture
    /// time — including EMPTY host skills dirs with zero placements (a
    /// spray into one must roll back without deleting the host's own
    /// containers). Sourced from the report's workspace roots, sorted.
    let preExistingDirectories: [String]

    init(batch: CommandBatch, report: ScanReport, environment: SukiruEnvironment) {
        let touchedIDs = Set(batch.findingRefs.map(\.workspaceID))
        let touchedSkills = report.skills.filter { skill in
            touchedIDs.contains { Self.skill(skill, isIn: $0) }
        }
        let projectRoots = Self.touchedProjectRoots(touchedIDs)
        placements = Self.placementSnapshots(of: touchedSkills)
        watchedDirectories = Self.parents(of: placements)
        let named = Set(batch.findingRefs.compactMap(\.skillName))
        payloadSources = Self.payloadSources(
            of: touchedSkills,
            named: named,
            environment: environment,
            projectRoots: projectRoots)
        ledgerPaths = Self.ledgerPaths(environment: environment, projectRoots: projectRoots)
        preExistingDirectories = Self.preExistingDirectories(
            in: report, touchedIDs: touchedIDs, projectRoots: projectRoots)
    }

    /// Whether the skill belongs to the given ownership-bucket workspace id
    /// (`user` / `project:<root>`), mirroring CommandBatchBuilder's scoping.
    static func skill(_ skill: Skill, isIn workspaceID: String) -> Bool {
        if workspaceID == "user" {
            return skill.scope == .user
        }
        guard workspaceID.hasPrefix("project:") else {
            return false
        }
        let root = String(workspaceID.dropFirst("project:".count))
        return skill.scope == .project
            && skill.placements.contains { $0.path.hasPrefix(root + "/") }
    }

    static func touchedProjectRoots(_ workspaceIDs: Set<String>) -> [String] {
        workspaceIDs.filter { $0.hasPrefix("project:") }
            .map { String($0.dropFirst("project:".count)) }
            .sorted()
    }

    static func placementSnapshots(of skills: [Skill]) -> [PlacementSnapshot] {
        var byPath: [String: PlacementSnapshot] = [:]
        for skill in skills {
            for placement in skill.placements {
                byPath[placement.path] = PlacementSnapshot(
                    path: placement.path,
                    kind: placement.kind,
                    linkTarget: placement.linkTarget,
                    hash: placement.contentHash)
            }
        }
        return byPath.values.sorted { $0.path < $1.path }
    }

    static func parents(of placements: [PlacementSnapshot]) -> [String] {
        let dirs = placements.map {
            URL(fileURLWithPath: $0.path).deletingLastPathComponent().path
        }
        return Array(Set(dirs)).sorted()
    }

    /// The roots of the report's workspaces that belong to a touched
    /// ownership bucket AND exist on disk at capture time, deduped and
    /// sorted. An empty pre-existing host skills dir appears here (the scan
    /// enumerates it as a leftover workspace) even though no placement
    /// names it — exactly the case the restore-time pruning stop set
    /// cannot otherwise distinguish from a batch-created container.
    static func preExistingDirectories(
        in report: ScanReport, touchedIDs: Set<String>, projectRoots: [String]
    ) -> [String] {
        let probe = DefaultFileSystemProbe()
        var dirs: [String] = []
        for workspace in report.workspaces {
            let touched: Bool
            switch workspace.kind {
            case .user:
                touched = touchedIDs.contains("user")
            case .project:
                touched = projectRoots.contains {
                    workspace.root == $0 || workspace.root.hasPrefix($0 + "/")
                }
            }
            if touched && probe.isDirectory(atPath: workspace.root) {
                dirs.append(workspace.root)
            }
        }
        return Array(Set(dirs)).sorted()
    }

    /// The payload copy set, deduped by canonical path (a symlink alias and
    /// its target dir are ONE physical dir), restricted to dirs inside the
    /// home or a touched project root — Sukiru never captures or restores
    /// outside the workspace boundary.
    static func payloadSources(
        of skills: [Skill],
        named: Set<String>,
        environment: SukiruEnvironment,
        projectRoots: [String]
    ) -> [String] {
        let probe = DefaultFileSystemProbe()
        let home = probe.resolvedPath(atPath: environment.home) ?? environment.home
        let roots = projectRoots.map { probe.resolvedPath(atPath: $0) ?? $0 }
        var byCanonical: [String: String] = [:]
        for skill in skills where named.contains(skill.name) {
            for placement in skill.placements {
                addSource(placement, probe: probe, into: &byCanonical)
            }
        }
        return byCanonical.filter { withinBounds($0.key, home: home, roots: roots) }
            .sorted { $0.key < $1.key }
            .map { $0.value }
    }

    static func addSource(
        _ placement: Placement,
        probe: FileSystemProbe,
        into sources: inout [String: String]
    ) {
        let candidate: String?
        switch placement.kind {
        case .directory:
            candidate = placement.path
        case .symlink:
            // The real dir behind an alias placement is one the batch may
            // write through; capture it under its canonical path.
            candidate = probe.resolvedPath(atPath: placement.path)
        case .brokenSymlink:
            candidate = nil
        }
        guard let candidate, probe.isDirectory(atPath: candidate) else {
            return
        }
        let canonical = probe.resolvedPath(atPath: candidate) ?? candidate
        if sources[canonical] == nil {
            sources[canonical] = candidate
        }
    }

    static func withinBounds(_ canonicalPath: String, home: String, roots: [String]) -> Bool {
        let bounds = [home] + roots
        return bounds.contains { canonicalPath == $0 || canonicalPath.hasPrefix($0 + "/") }
    }

    static func ledgerPaths(environment: SukiruEnvironment, projectRoots: [String]) -> [String] {
        var paths = [VercelLockReader(environment: environment).globalLockPath()]
        for root in projectRoots {
            for candidate in VercelLockReader.projectProbeOrder {
                paths.append(HostPathResolver.join(root, candidate))
            }
        }
        return paths.sorted()
    }
}
