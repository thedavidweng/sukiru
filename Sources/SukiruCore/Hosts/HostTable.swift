/// The embedded 56-host directory table.
///
/// The data itself is generated from `research/host-table.json` into
/// `HostTableData.swift` by `Scripts/generate-host-table.sh`; regenerate rather
/// than editing by hand. `HostTableTests` asserts the count and JSON parity.
public enum HostTable {
    /// All 56 host specifications, in the source table's order.
    public static let hosts: [HostSpec] = generatedHosts

    /// Looks up a host by its stable id.
    public static func host(id: String) -> HostSpec? {
        hosts.first { $0.id == id }
    }

    /// The project-scope skills dir shared by every "canonical store" host:
    /// `<project>/.agents/skills`.
    public static let canonicalProjectSkillDir = ".agents/skills"

    /// The host id used to target the canonical project store on the
    /// `skills` CLI: any host whose `projectSkillDir` is `.agents/skills`
    /// works; `codex` is pinned as the probe-verified representative
    /// (skills@1.5.26).
    public static let canonicalStoreHost = "codex"

    /// A host id whose project skills dir is exactly `projectSkillDir`
    /// (relative, e.g. `.claude/skills`). Many hosts share a dir — the
    /// `codex` entry is preferred when present (probe-verified), otherwise
    /// the lexicographically-first id keeps the choice deterministic.
    public static func host(forProjectSkillDir projectSkillDir: String) -> String? {
        let matches = hosts.filter { $0.projectSkillDir == projectSkillDir }.map(\.id)
        guard !matches.isEmpty else { return nil }
        if matches.contains(canonicalStoreHost) { return canonicalStoreHost }
        return matches.sorted().first
    }
}
