/// Recognizes skill directories an agent host manages itself, through a
/// ledger of its own that neither `npx skills` nor `gh skill` reads.
///
/// - Hermes Agent keeps `.bundled_manifest` and `.hub/lock.json` in its
///   skills root and writes (curates) skills there itself, so every physical
///   directory under a root carrying either marker is Hermes's.
/// - Codex ships its built-in skills under `<skills root>/.system/`.
///
/// Such skills are not orphans: they have an owner, just not one of the two
/// installer ledgers, so Health never proposes adopting or deleting them.
/// Symlinked placements are never agent-managed — the link points elsewhere.
public struct AgentManagedDirectories: Sendable {
    /// Root-relative marker files whose presence makes the root self-managed.
    static let ledgerMarkers = [".bundled_manifest", ".hub/lock.json"]
    /// The root-relative container holding an agent's shipped skills.
    static let builtInContainer = ".system"

    private let fileSystem: FileSystemProbe

    public init(fileSystem: FileSystemProbe = DefaultFileSystemProbe()) {
        self.fileSystem = fileSystem
    }

    /// The managing host id for a physical skill directory discovered in
    /// `workspace`, or nil when no agent claims it. Only host workspaces
    /// qualify; the canonical store (`user` / `project:<root>`) is shared.
    public func managingAgent(
        ofDirectory path: String, in workspace: EnumeratedWorkspace
    ) -> String? {
        let root = workspace.workspace.root
        guard workspace.workspace.id != workspace.scopeGroup,
            let host = workspace.candidateHosts.first,
            path.hasPrefix(root + "/")
        else { return nil }
        let relative = path.dropFirst(root.count + 1)
        if relative.hasPrefix(Self.builtInContainer + "/") {
            return host
        }
        let selfManaged = Self.ledgerMarkers.contains {
            fileSystem.isFile(atPath: HostPathResolver.join(root, $0))
        }
        return selfManaged ? host : nil
    }
}
