import Foundation

/// Native installation paths stay inside a registered project. The pnpm lock's
/// importer inventory avoids recursive package discovery or workspace glob guesses.
struct PnpmProjectLayout {
    let fileSystem: FileSystemProbe

    func importerRoots(projectRoot root: String) -> [String] {
        guard let data = safeContents(at: root + "/pnpm-lock.yaml", projectRoot: root),
            let text = String(bytes: data, encoding: .utf8),
            let lock = try? YAMLSubset.jsonValue(yaml: text),
            let importers = lock["importers"]?.objectValue
        else { return [root] }
        var roots: Set<String> = [root]
        for importer in importers.keys where importer != "." {
            guard let path = contained(importer, in: root) else { continue }
            if fileSystem.isFile(atPath: path + "/package.json") {
                roots.insert(path)
            }
        }
        return roots.sorted()
    }

    func customWorkspaces(projectRoot root: String) -> [EnumeratedWorkspace] {
        guard let data = safeContents(at: root + "/pnpm-workspace.yaml", projectRoot: root),
            let text = String(bytes: data, encoding: .utf8),
            let config = try? YAMLSubset.jsonValue(yaml: text),
            let dirs = config["skills"]?["dirs"]?.arrayValue
        else { return [] }
        return Set(dirs.compactMap(\.stringValue)).sorted().compactMap { relative in
            guard let path = contained(relative, in: root),
                fileSystem.isDirectory(atPath: path)
            else { return nil }
            return EnumeratedWorkspace(
                workspace: Workspace(
                    id: "project:" + root + "#pnpm:" + relative, kind: .project,
                    root: path, installed: true),
                candidateHosts: [], scopeGroup: "project:" + root)
        }
    }

    func safeContents(at path: String, projectRoot root: String) -> Data? {
        guard let project = fileSystem.resolvedPath(atPath: root),
            let resolved = fileSystem.resolvedPath(atPath: path),
            resolved.hasPrefix(project + "/")
        else { return nil }
        return fileSystem.fileContents(atPath: path)
    }

    func contained(_ relative: String, in root: String) -> String? {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\\"),
            !relative.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }),
            let project = fileSystem.resolvedPath(atPath: root)
        else { return nil }
        let path = root + "/" + relative
        // Resolve the path before reading a manifest or traversing a skill root.
        guard let resolved = fileSystem.resolvedPath(atPath: path),
            resolved.hasPrefix(project + "/")
        else { return nil }
        return path
    }
}
