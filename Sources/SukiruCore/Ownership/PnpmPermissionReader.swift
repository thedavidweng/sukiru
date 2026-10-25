import Foundation

/// Reads pnpm 12's JSON modules manifest and native workspace YAML without invoking pnpm.
struct PnpmPermissionReader {
    let fileSystem: FileSystemProbe

    private struct Metadata {
        var pending: [String] = []
        var decisions: [String: Bool] = [:]
        var undecided: Set<String> = []
        var issues: [Issue] = []
    }

    func read(
        projectRoots: [String], verified: [String: PnpmProvenance]
    ) -> (observations: [PnpmObservation], issues: [Issue]) {
        var observations: [PnpmObservation] = []
        var issues: [Issue] = []
        for root in Set(projectRoots).sorted() {
            let result = readRoot(root, verified: verified)
            observations.append(contentsOf: result.observations)
            issues.append(contentsOf: result.issues)
        }
        return (observations, issues)
    }

    private func readRoot(
        _ root: String, verified: [String: PnpmProvenance]
    ) -> (observations: [PnpmObservation], issues: [Issue]) {
        let installed = Set(verified.values.filter { $0.projectRoot == root }.map(\.packageName))
        let metadata = readMetadata(projectRoot: root)
        var selectors = Set(metadata.pending).union(metadata.decisions.keys).union(
            metadata.undecided)
        for name in installed where !selectors.contains(where: { Self.packageName($0) == name }) {
            selectors.insert(name)
        }
        var observations: [PnpmObservation] = []
        for selector in selectors.sorted() {
            guard let name = Self.packageName(selector) else { continue }
            let usesWorkspace =
                metadata.decisions[selector] != nil
                || metadata.undecided.contains(selector) || metadata.decisions[name] == false
            observations.append(
                PnpmObservation(
                    projectRoot: root, packageName: name, selector: selector,
                    permission: Self.permission(for: selector, name: name, metadata: metadata),
                    installed: installed.contains(name),
                    metadataPath: root
                        + (usesWorkspace ? "/pnpm-workspace.yaml" : "/node_modules/.modules.yaml")))
        }
        return (observations, metadata.issues)
    }

    private func readMetadata(projectRoot: String) -> Metadata {
        let modulesPath = projectRoot + "/node_modules/.modules.yaml"
        let workspacePath = projectRoot + "/pnpm-workspace.yaml"
        var metadata = Metadata()
        if fileSystem.exists(atPath: modulesPath) {
            do {
                metadata.pending = try readModules(at: modulesPath, projectRoot: projectRoot)
            } catch {
                metadata.issues.append(Self.issue(modulesPath, error))
            }
        }
        if fileSystem.exists(atPath: workspacePath) {
            do {
                try readWorkspace(at: workspacePath, projectRoot: projectRoot, metadata: &metadata)
            } catch {
                metadata.decisions.removeAll()
                metadata.issues.append(Self.issue(workspacePath, error))
            }
        }
        return metadata
    }

    private func readModules(at path: String, projectRoot: String) throws -> [String] {
        guard let data = safeContents(at: path, projectRoot: projectRoot),
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let manager = object["packageManager"] as? String,
            manager.hasPrefix("pnpm@12."),
            let minor = Int(manager.dropFirst(8).split(separator: ".").first ?? ""),
            minor >= 11,
            object["layoutVersion"] as? Int == 5
        else { throw YAMLError("unsupported pnpm modules metadata") }
        guard let value = object["pendingSkills"] else { return [] }
        guard let selectors = value as? [String],
            selectors.allSatisfy({ selector in
                guard let name = Self.packageName(selector) else { return false }
                return selector.hasPrefix(name + "@")
            })
        else { throw YAMLError("invalid pendingSkills selectors") }
        return selectors
    }

    private func readWorkspace(
        at path: String, projectRoot: String, metadata: inout Metadata
    ) throws {
        guard let data = safeContents(at: path, projectRoot: projectRoot),
            let text = String(data: data, encoding: .utf8),
            case .mapping(let workspace) = try YAMLSubset.compose(yaml: text)
        else { throw YAMLError("invalid workspace mapping") }
        guard let permissions = workspace["permissions"] else { return }
        guard case .mapping(let entries) = permissions else {
            throw YAMLError("invalid permissions mapping")
        }
        var seen: Set<String> = []
        for entry in entries.pairs {
            guard let selector = entry.key.string,
                Self.packageName(selector) != nil,
                seen.insert(selector).inserted,
                case .mapping(let capabilities) = entry.value
            else { throw YAMLError("invalid or duplicate permission selector") }
            if let skills = capabilities["skills"] {
                if let allowed = skills.bool {
                    metadata.decisions[selector] = allowed
                } else if skills.tag == .str, skills.string != nil {
                    metadata.undecided.insert(selector)
                } else {
                    throw YAMLError("invalid skills permission value")
                }
            }
        }
    }

    private static func permission(
        for selector: String, name: String, metadata: Metadata
    ) -> PnpmObservation.Permission {
        if !metadata.issues.isEmpty {
            return .unknown
        } else if metadata.decisions[name] == false || metadata.decisions[selector] == false {
            return .denied
        } else if let allowed = metadata.decisions[selector] {
            return allowed ? .approved : .denied
        } else if metadata.pending.contains(selector) {
            // A recorded pending depPath is evidence of awaiting approval, not a skill.
            return .pending
        } else {
            return .unknown
        }
    }

    private func safeContents(at path: String, projectRoot: String) -> Data? {
        PnpmProjectLayout(fileSystem: fileSystem).safeContents(at: path, projectRoot: projectRoot)
    }

    /// Preserve the complete selector; only split the package identity for display.
    private static func packageName(_ selector: String) -> String? {
        guard !selector.isEmpty, !selector.contains(where: { $0.isWhitespace }),
            !selector.contains("\\")
        else { return nil }
        let start =
            selector.hasPrefix("@")
            ? selector.index(after: selector.startIndex) : selector.startIndex
        let end = selector[start...].firstIndex(of: "@") ?? selector.endIndex
        let name = String(selector[..<end])
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
            parts.count == (name.hasPrefix("@") ? 2 : 1),
            end == selector.endIndex || selector.index(after: end) < selector.endIndex
        else { return nil }
        return name
    }

    private static func issue(_ path: String, _ error: Error) -> Issue {
        Issue(
            kind: IssueKind.pnpmUnverified, path: path,
            message:
                "pnpm permission metadata is unreadable or incompatible: \(error). Inspect the project with pnpm."
        )
    }
}
