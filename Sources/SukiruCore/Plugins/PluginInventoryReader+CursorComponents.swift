import Foundation

extension PluginInventoryReader {
    func cursorComponents(
        path: String, manifest: [String: Any], native: Bool, issues: inout [Issue]
    ) -> [PluginComponent] {
        var result: [PluginComponent] = []
        let kinds = native ? ["skills", "rules", "agents", "commands"] : ["skills"]
        for kind in kinds {
            result += cursorDocumentComponents(
                kind: kind, declaration: manifest[kind], root: path, issues: &issues)
        }
        let skillsDirectory = HostPathResolver.join(path, "skills")
        let rootSkill = cursorDocument(
            kind: "skills", name: URL(fileURLWithPath: path).lastPathComponent, path: path,
            root: path)
        let rootOnly =
            native && manifest["skills"] == nil
            && !DefaultFileSystemProbe().isDirectory(atPath: skillsDirectory)
        if rootOnly, let rootSkill {
            result.append(rootSkill)
        }
        result += cursorConfigComponents(
            path: path, manifest: manifest, native: native, issues: &issues)
        let schema = manifest["variables"] as? [String: Any]
        if native, let properties = schema?["properties"] as? [String: Any] {
            for name in properties.keys.sorted() {
                result.append(PluginComponent(kind: "variables", name: name, path: nil))
            }
        }
        return result
    }

    private func cursorDocumentComponents(
        kind: String, declaration: Any?, root path: String, issues: inout [Issue]
    ) -> [PluginComponent] {
        var result: [PluginComponent] = []
        let declared = declaration
        let paths =
            (declared as? [String]) ?? (declared as? String).map { [$0] }
            ?? (declared == nil ? [kind] : [])
        for relative in paths {
            guard let component = cursorComponentPath(relative, root: path) else {
                issues.append(
                    Issue(
                        kind: "plugin-containment", path: path,
                        message: "Invalid Cursor component path: " + relative))
                continue
            }
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: component, isDirectory: &directory)
            else { continue }
            let ownSkill = cursorDocument(
                kind: "skills", name: URL(fileURLWithPath: component).lastPathComponent,
                path: component, root: path)
            if kind == "skills", let ownSkill {
                result.append(ownSkill)
                continue
            }
            let children =
                directory.boolValue
                ? cursorChildren(component, issues: &issues)
                : [URL(fileURLWithPath: component).lastPathComponent]
            for name in children.sorted() where !name.hasPrefix(".") {
                let child =
                    directory.boolValue ? HostPathResolver.join(component, name) : component
                guard cursorContained(child, in: path) else { continue }
                if let entry = cursorDocument(kind: kind, name: name, path: child, root: path) {
                    result.append(entry)
                }
            }
        }
        return result
    }

    private func cursorDocument(
        kind: String, name: String, path child: String, root path: String
    ) -> PluginComponent? {
        if kind == "skills" {
            let skill = HostPathResolver.join(child, "SKILL.md")
            guard cursorContained(skill, in: path), FileManager.default.fileExists(atPath: skill)
            else { return nil }
        } else {
            let extensions =
                kind == "commands" ? ["md", "mdc", "markdown", "txt"] : ["md", "mdc", "markdown"]
            guard extensions.contains(URL(fileURLWithPath: child).pathExtension) else { return nil }
        }
        return PluginComponent(kind: kind, name: name, path: child)
    }

    private func cursorConfigComponents(
        path: String, manifest: [String: Any], native: Bool, issues: inout [Issue]
    ) -> [PluginComponent] {
        var result: [PluginComponent] = []
        for kind in native ? ["mcpServers", "hooks"] : ["mcpServers"] {
            let declared = manifest[kind]
            let defaults = kind == "hooks" ? "hooks/hooks.json" : "mcp.json"
            let declarations: [Any] = declared.map { ($0 as? [Any]) ?? [$0] } ?? [defaults]
            for declaration in declarations {
                if let inline = declaration as? [String: Any], !inline.isEmpty {
                    result += cursorInlineComponents(
                        kind: kind, object: inline, root: path, issues: &issues)
                    continue
                }
                guard let relative = declaration as? String else { continue }
                guard let file = cursorComponentPath(relative, root: path),
                    let object = json(file, issues: &issues),
                    let entries = object[kind] as? [String: Any]
                else { continue }
                for name in entries.keys.sorted() {
                    result.append(PluginComponent(kind: kind, name: name, path: file))
                }
            }
        }
        return result
    }

    private func cursorInlineComponents(
        kind: String, object: [String: Any], root: String, issues: inout [Issue]
    ) -> [PluginComponent] {
        let entries: [String: Any]
        if let wrapped = object[kind] as? [String: Any] {
            entries = wrapped
        } else if kind == "mcpServers" {
            entries = object
        } else {
            issues.append(
                Issue(
                    kind: "plugin-manifest", path: root,
                    message: "Inline Cursor hooks require a hooks object"))
            return []
        }
        return entries.keys.sorted().map { PluginComponent(kind: kind, name: $0, path: nil) }
    }

    private func cursorComponentPath(_ relative: String, root: String) -> String? {
        guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else {
            return nil
        }
        let path = URL(fileURLWithPath: root).appendingPathComponent(relative).standardizedFileURL
            .path
        return cursorContained(path, in: root) ? path : nil
    }
}
