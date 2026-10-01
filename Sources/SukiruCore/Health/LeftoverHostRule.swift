/// `leftover-host-dir` (warning): a user-scope host skills folder whose host
/// is not installed (CLI spray residue, `installed == false`) and that holds
/// nothing but links and Finder noise. Every link points elsewhere, so
/// removing the folder loses no skill content. A leftover folder holding a
/// physical copy never qualifies: that copy may be the only one.
enum LeftoverHostRule {
    static let ruleID = "leftover-host-dir"

    /// Finder bookkeeping that never counts as content.
    static let finderNoise: Set<String> = [".DS_Store", ".localized"]

    static func findings(
        workspaces: [EnumeratedWorkspace], fileSystem: FileSystemProbe
    ) -> [Finding] {
        workspaces.compactMap { enumerated in
            let workspace = enumerated.workspace
            guard workspace.kind == .user, !workspace.installed,
                let links = linkCount(in: workspace.root, fileSystem: fileSystem)
            else { return nil }
            let hosts = enumerated.candidateHosts.map { HostTable.host(id: $0)?.displayName ?? $0 }
            return Finding(
                ruleID: ruleID,
                severity: .warning,
                skillName: nil,
                workspaceID: workspace.id,
                evidence: [
                    Evidence(kind: "hosts", detail: hosts.joined(separator: ", ")),
                    Evidence(kind: "skillsDir", detail: workspace.root),
                    Evidence(kind: "linkCount", detail: String(links))
                ])
        }
    }

    /// The number of links in `directory`, or nil when it holds anything
    /// besides links and Finder noise (or cannot be read).
    static func linkCount(in directory: String, fileSystem: FileSystemProbe) -> Int? {
        guard let entries = fileSystem.directoryEntries(atPath: directory) else { return nil }
        var links = 0
        for entry in entries where !finderNoise.contains(entry) {
            guard case .symlink? = fileSystem.entryKind(atPath: directory + "/" + entry) else {
                return nil
            }
            links += 1
        }
        return links
    }
}
