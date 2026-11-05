import Foundation

/// One detected Agent Host's global skills folder that does not hold a
/// user-scope Skill, plus the link that would deploy the shared copy there.
///
/// Hosts that read one personal folder (Antigravity's App and CLI) collapse
/// into a single target: one link serves all of them.
public struct HostLinkTarget: Equatable, Sendable {
    /// Every detected host that reads `skillsRoot`, in host-table order.
    public let hostIDs: [String]
    public let displayName: String
    /// The host's global skills folder; the batch creates it when missing.
    public let skillsRoot: String
    /// Where the link goes: `skillsRoot/<shared folder name>`.
    public let linkPath: String
    /// The shared-store copy the link points at.
    public let storePath: String

    /// The identity a caller passes back to `batch`: the first detected host
    /// at this folder, in host-table order.
    public var hostID: String { hostIDs[0] }
}

/// Plans user-initiated deployment of one global Skill into Agent Hosts that
/// do not see it.
///
/// A host holding a subset of the shared store is a user choice, not a
/// defect: nothing here is a Problem, counted in Health, or one-click fixed.
/// `targets` answers which detected hosts can receive the Skill now, and
/// `batch` re-resolves that answer immediately before building the
/// snapshot-protected link, so a host folder filled since the scan is
/// refused instead of overwritten.
///
/// The link is a direct file operation because the pinned `skills` release
/// returns the shared-store path for a universal agent's global install
/// before it creates the agent link (`isGlobal && isUniversalAgent`), so no
/// official command deploys a global Skill to an agent whose global folder
/// differs from the shared store.
public struct HostLinkPlanner: Sendable {
    private let fileSystem: FileSystemProbe
    private let resolver: HostPathResolver
    private let detector: HostDetector
    private let idProvider: @Sendable () -> String
    private let dateProvider: @Sendable () -> Date

    public init(
        environment: SukiruEnvironment,
        fileSystem: FileSystemProbe = DefaultFileSystemProbe(),
        idProvider: @escaping @Sendable () -> String = { UUID().uuidString },
        dateProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileSystem = fileSystem
        self.resolver = HostPathResolver(environment: environment, fileSystem: fileSystem)
        self.detector = HostDetector(environment: environment, fileSystem: fileSystem)
        self.idProvider = idProvider
        self.dateProvider = dateProvider
    }

    /// Detected hosts whose global folder can receive this Skill now, one
    /// entry per folder. Empty for project Skills, Skills with no shared
    /// copy, and hosts whose folder already holds the name.
    public func targets(for skill: Skill) -> [HostLinkTarget] {
        guard skill.scope == .user, let store = sharedCopy(of: skill) else { return [] }
        let storeRoot = resolver.canonicalUserRoot()
        let name = Self.folderName(store)
        var hostIDsByRoot: [String: [String]] = [:]
        for host in HostTable.hosts where detector.isDetected(host) {
            let root = resolver.globalSkillsRoot(for: host)
            guard root != storeRoot,
                fileSystem.entryKind(atPath: HostPathResolver.join(root, name)) == nil
            else { continue }
            hostIDsByRoot[root, default: []].append(host.id)
        }
        return
            hostIDsByRoot
            .map { root, hostIDs in
                let names = hostIDs.compactMap { HostTable.host(id: $0)?.displayName }
                return HostLinkTarget(
                    hostIDs: hostIDs,
                    displayName: names.joined(separator: ", "),
                    skillsRoot: root,
                    linkPath: HostPathResolver.join(root, name),
                    storePath: store)
            }
            .sorted { ($0.displayName, $0.skillsRoot) < ($1.displayName, $1.skillsRoot) }
    }

    /// One link command for the chosen host, or the reason it no longer
    /// applies. Re-resolves the target against disk, so a caller that queued
    /// a target from an older scan gets an explanation instead of a silent
    /// overwrite.
    public func batch(skill: Skill, host: String) throws -> CommandBatch {
        guard let target = targets(for: skill).first(where: { $0.hostIDs.contains(host) }) else {
            throw BatchBuildError(problems: [refusal(skill: skill, host: host)])
        }
        let id = idProvider()
        let command = BatchCommandFactory.link(
            name: skill.name, path: target.linkPath, storePath: target.storePath,
            hosts: target.displayName,
            intent: "Link the shared copy of '\(skill.name)' into \(target.displayName) "
                + "(\(target.skillsRoot)) so the agent reads it.")
        return CommandBatch(
            id: id,
            createdAt: ISO8601DateFormatter().string(from: dateProvider()),
            findingRefs: [
                FindingRef(
                    findingID: id, ruleID: "host-link", skillName: skill.name,
                    workspaceID: "user")
            ],
            decisions: [],
            commands: [command],
            snapshotID: nil,
            status: .proposed)
    }

    /// The shared-store placement of a user-scope Skill, which every host
    /// link points at. Agent-internal entries are not deployable.
    private func sharedCopy(of skill: Skill) -> String? {
        let storeRoot = resolver.canonicalUserRoot()
        return skill.placements.first { placement in
            !placement.internal && placement.kind != .brokenSymlink
                && Self.parent(of: placement.path) == storeRoot
        }?.path
    }

    /// Why a host cannot receive the Skill, phrased for the user.
    private func refusal(skill: Skill, host: String) -> String {
        guard let spec = HostTable.host(id: host) else {
            return "Unknown Agent Host: \(host)"
        }
        if skill.scope != .user {
            return "Only user-scope (global) Skills can be linked into an Agent Host; "
                + "'\(skill.name)' is a project Skill"
        }
        guard let store = sharedCopy(of: skill) else {
            return "'\(skill.name)' has no shared copy in \(resolver.canonicalUserRoot()) to link"
        }
        if !detector.isDetected(spec) {
            return "\(spec.displayName) is not installed on this Mac"
        }
        let root = resolver.globalSkillsRoot(for: spec)
        if root == resolver.canonicalUserRoot() {
            return "\(spec.displayName) already reads the shared skills folder"
        }
        let name = Self.folderName(store)
        if fileSystem.entryKind(atPath: HostPathResolver.join(root, name)) != nil {
            return "\(spec.displayName) already has an entry named '\(name)' in \(root)"
        }
        return "'\(skill.name)' cannot be linked into \(spec.displayName)"
    }

    private static func parent(of path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().path
    }

    private static func folderName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}
