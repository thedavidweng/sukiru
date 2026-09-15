/// The scanner's container ignore list (architecture §4.1, port-reference §3
/// `is_ignored_container` / `is_known_agent_or_skill_container`).
///
/// Unconditional entries are noise/build directories that are never skills.
/// Dot-prefixed names are ignored UNLESS they are known agent-or-skill
/// containers, and the known-container allowlist is DERIVED from `HostTable`
/// (the first path component of every host's `projectSkillDir`) plus the
/// curated sub-buckets — never a hand-maintained second list. The archive's
/// three hand-maintained lists were mutually inconsistent (19 missing project
/// dirs, three phantom entries); derivation makes that drift impossible.
///
/// Deliberate deviation from upstream: the archive's structural escape
/// hatches (`path/SKILL.md` exists → known; parent named `skills` → known)
/// are NOT ported. They un-ignore any hidden dot-dir carrying a SKILL.md,
/// which is exactly the `ignore-list` fixture's `.hidden-junk` defect — an
/// unknown dot-dir must stay ignored even when it looks like a skill.
public enum ContainerIgnoreList {
    /// Never treated as skill placements, at any depth. Space-listed to avoid
    /// a multi-line collection literal (repo lint gates conflict on those).
    public static let unconditional: Set<String> = Set(
        "node_modules __pycache__ __pypackages__ dist build .git .archive"
            .split(separator: " ").map(String.init)
    )

    /// Curated sub-buckets inside a skills root (port-reference §3: these are
    /// legitimate containers, not hosts, and exist in no host table row).
    public static let curatedBuckets: Set<String> = [".curated", ".experimental", ".system"]

    /// Dot-prefixed container names derived from `HostTable`: the first path
    /// component of every host's `projectSkillDir`, plus curated buckets.
    public static let knownContainerNames: Set<String> = {
        var names = curatedBuckets
        for host in HostTable.hosts {
            guard let first = host.projectSkillDir.split(separator: "/").first,
                first.hasPrefix(".")
            else {
                continue
            }
            names.insert(String(first))
        }
        return names
    }()

    /// Whether a directory entry named `name` is excluded from the scan.
    public static func isIgnored(name: String) -> Bool {
        if unconditional.contains(name) {
            return true
        }
        if name.hasPrefix(".") {
            return !knownContainerNames.contains(name)
        }
        return false
    }
}
