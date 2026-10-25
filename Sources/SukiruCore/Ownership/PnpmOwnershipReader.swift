import Foundation

/// Evidence from pnpm's native installation record, corroborated on disk.
public struct PnpmProvenance: Codable, Equatable, Sendable {
    public let packageName: String
    public let packageVersion: String
    public let dependency: String
    public let originalName: String
    public let projectRoot: String
    public let placement: String
    public let target: String
    public let metadataPath: String
}

struct PnpmOwnershipEvidence {
    var verified: [String: PnpmProvenance] = [:]
    var unverified: Set<String> = []
    var issues: [Issue] = []

    func protects(_ group: SkillGroup) -> Bool {
        group.members.contains {
            verified[$0.placement.path] != nil || unverified.contains($0.placement.path)
        }
    }
}

/// Passive, project-bounded recognition of pnpm 12's isolated installation.
/// Names and paths only trigger diagnostics; they never establish ownership.
struct PnpmOwnershipReader {
    let fileSystem: FileSystemProbe

    func read(
        placements: [DiscoveredPlacement], projectRoots: [String] = []
    ) -> PnpmOwnershipEvidence {
        var result = PnpmOwnershipEvidence()
        let projects = Dictionary(
            grouping: placements.filter {
                $0.scopeGroup.hasPrefix("project:")
            }, by: \.scopeGroup)
        let scopes = Set(projects.keys).union(projectRoots.map { "project:" + $0 })
        for scope in scopes.sorted() {
            let root = String(scope.dropFirst("project:".count))
            read(root: root, placements: projects[scope] ?? [], into: &result)
        }
        return result
    }

    private func read(
        root: String, placements: [DiscoveredPlacement], into result: inout PnpmOwnershipEvidence
    ) {
        let metadataPath = root + "/node_modules/.modules.yaml"
        let metadata = object(at: metadataPath, projectRoot: root)
        let records = metadata?["linkedSkills"] as? [String]
        let recorded = Set(
            (records ?? []).compactMap { record -> String? in
                let path = record.hasPrefix("/") ? record : root + "/" + record
                guard !record.split(separator: "/").contains(".."),
                    path.hasPrefix(root + "/")
                else { return nil }
                return path
            })
        let candidates = placements.filter {
            recorded.contains($0.placement.path)
                || ($0.placement.path as NSString).lastPathComponent.hasPrefix("pnpm-")
                || ($0.placement.canonicalPath?.contains("/node_modules/") == true
                    && $0.placement.canonicalPath?.contains("/skills/") == true)
        }
        let supported =
            metadata.map(Self.supported) == true
            && (metadata?["linkedSkills"] == nil || records != nil)
        for member in candidates {
            let path = member.placement.path
            let evidence =
                supported && recorded.contains(path)
                ? verify(member, root: root, metadataPath: metadataPath) : nil
            if let evidence {
                result.verified[path] = evidence
            } else {
                result.unverified.insert(path)
                result.issues.append(
                    Issue(
                        kind: IssueKind.pnpmUnverified, path: path,
                        message:
                            "pnpm ownership is unverified: requires supported native linkedSkills "
                            + "data, a matching symlink and an installed project dependency skill. "
                            + "Inspect the project with pnpm; Sukiru will not modify this entry."))
            }
        }
        let discovered = Set(placements.map(\.placement.path))
        for path in recorded.sorted() where !discovered.contains(path) {
            result.issues.append(
                Issue(
                    kind: IssueKind.pnpmUnverified, path: path,
                    message: "pnpm recorded a linked skill that is not readable in the scanned "
                        + "project skill folders. Inspect the project with pnpm."))
        }
    }

    private static func supported(_ metadata: [String: Any]) -> Bool {
        guard let manager = metadata["packageManager"] as? String,
            manager.hasPrefix("pnpm@"),
            metadata["layoutVersion"] as? Int == 5,
            metadata["nodeLinker"] as? String == "isolated",
            metadata["virtualStoreDir"] as? String == ".pnpm"
        else { return false }
        let version = manager.dropFirst(5).split(separator: ".").compactMap { Int($0) }
        return version.count == 3 && version[0] == 12 && version[1] >= 11
    }

    private func verify(
        _ member: DiscoveredPlacement, root: String, metadataPath: String
    ) -> PnpmProvenance? {
        let path = member.placement.path
        guard case .symlink = fileSystem.entryKind(atPath: path),
            let project = fileSystem.resolvedPath(atPath: root),
            let parent = fileSystem.resolvedPath(
                atPath: (path as NSString).deletingLastPathComponent),
            parent.hasPrefix(project + "/"),
            let target = fileSystem.resolvedPath(atPath: path),
            target.hasPrefix(project + "/node_modules/.pnpm/")
        else { return nil }
        let skillFolder = (target as NSString).lastPathComponent
        let skills = (target as NSString).deletingLastPathComponent
        guard (skills as NSString).lastPathComponent == "skills" else { return nil }
        let packageRoot = (skills as NSString).deletingLastPathComponent
        guard let package = object(at: packageRoot + "/package.json", projectRoot: root),
            let name = package["name"] as? String, Self.validPackageName(name),
            let version = package["version"] as? String, !version.isEmpty,
            let dependency = dependency(named: name, packageRoot: packageRoot, projectRoot: root),
            (path as NSString).lastPathComponent
                == "pnpm-" + name.replacingOccurrences(of: "/", with: "+") + "-" + skillFolder,
            fileSystem.isFile(atPath: target + "/SKILL.md")
        else { return nil }
        return PnpmProvenance(
            packageName: name, packageVersion: version, dependency: dependency,
            originalName: member.name, projectRoot: root, placement: path, target: target,
            metadataPath: metadataPath)
    }

    private func dependency(
        named name: String, packageRoot: String, projectRoot root: String
    ) -> String? {
        for importer in PnpmProjectLayout(fileSystem: fileSystem).importerRoots(projectRoot: root) {
            guard
                fileSystem.resolvedPath(atPath: importer + "/node_modules/" + name) == packageRoot,
                let manifest = object(at: importer + "/package.json", projectRoot: root),
                let dependency = ["dependencies", "devDependencies", "optionalDependencies"]
                    .compactMap({ (manifest[$0] as? [String: String])?[name] }).first
            else { continue }
            return dependency
        }
        return nil
    }

    private static func validPackageName(_ name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        return !name.isEmpty && !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
            && (parts.count == 1 || (parts.count == 2 && name.hasPrefix("@")))
            && !name.contains("\\")
    }

    private func object(at path: String, projectRoot root: String) -> [String: Any]? {
        guard
            let data = PnpmProjectLayout(fileSystem: fileSystem)
                .safeContents(at: path, projectRoot: root)
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
