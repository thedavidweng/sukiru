import Foundation

extension PluginInventoryReader {
    func components(
        at path: String?, manifest: [String: Any]?, issues: inout [Issue]
    ) -> [PluginComponent] {
        guard let path else { return [] }
        var result: [PluginComponent] = []
        for kind in ["skills", "commands", "agents"] {
            if kind != "skills", manifest?[kind] != nil { continue }
            let directory = HostPathResolver.join(path, kind)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
                continue
            }
            for name in names.sorted() where !name.hasPrefix(".") {
                let componentPath = HostPathResolver.join(directory, name)
                if kind == "skills" {
                    let skillPath = HostPathResolver.join(componentPath, "SKILL.md")
                    if FileManager.default.fileExists(atPath: skillPath) {
                        result.append(PluginComponent(kind: kind, name: name, path: componentPath))
                    }
                } else if name.hasSuffix(".md") {
                    result.append(PluginComponent(kind: kind, name: name, path: componentPath))
                }
            }
        }
        if let manifest {
            appendDeclaredComponents(manifest, root: path, to: &result, issues: &issues)
            let openAI = (manifest["extensions"] as? [String: Any])?["com.openai"] as? [String: Any]
            if let openAI {
                appendDeclaredComponents(openAI, root: path, to: &result, issues: &issues)
            }
        }
        appendConventionalComponent(
            at: path, file: ".mcp.json", key: "mcpServers", to: &result, issues: &issues)
        appendConventionalComponent(
            at: path, file: "mcp.json", key: "mcpServers", to: &result, issues: &issues)
        appendConventionalComponent(
            at: path, file: ".lsp.json", key: "lspServers", to: &result, issues: &issues)
        appendConventionalComponent(
            at: HostPathResolver.join(path, "hooks"), file: "hooks.json", key: "hooks",
            to: &result, issues: &issues)
        var seen = Set<String>()
        return result.filter {
            seen.insert("\($0.kind)|\($0.name)|\($0.path ?? "")").inserted
        }
    }

    private func appendDeclaredComponents(
        _ manifest: [String: Any], root: String, to result: inout [PluginComponent],
        issues: inout [Issue]
    ) {
        for key in ["skills", "commands", "agents"] {
            guard let value = manifest[key] else { continue }
            if key == "commands", let declarations = value as? [String: Any] {
                appendInlineCommands(declarations, root: root, to: &result)
                continue
            }
            for declared in stringValues(value) {
                guard let path = declaredPath(declared, root: root) else { continue }
                if key == "skills" {
                    appendSkills(at: path, to: &result)
                } else {
                    appendMarkdownComponents(kind: key, at: path, to: &result)
                }
            }
        }
        appendDeclaredConfigs(manifest, root: root, to: &result, issues: &issues)
    }

    private func appendDeclaredConfigs(
        _ manifest: [String: Any], root: String, to result: inout [PluginComponent],
        issues: inout [Issue]
    ) {
        for key in ["hooks", "mcpServers", "lspServers"] {
            guard let value = manifest[key] else { continue }
            for declaration in value as? [Any] ?? [value] {
                if let inline = declaration as? [String: Any], !inline.isEmpty {
                    result.append(PluginComponent(kind: key, name: key, path: nil))
                    continue
                }
                guard let declared = declaration as? String else { continue }
                guard let path = declaredPath(declared, root: root),
                    let object = json(path, issues: &issues), isDeclaredConfig(object, key: key)
                else { continue }
                result.append(PluginComponent(kind: key, name: key, path: path))
            }
        }
    }

    private func appendInlineCommands(
        _ declarations: [String: Any], root: String, to result: inout [PluginComponent]
    ) {
        for (name, declaration) in declarations {
            guard let command = declaration as? [String: Any] else { continue }
            if command["content"] is String {
                result.append(PluginComponent(kind: "commands", name: name, path: nil))
            } else if let source = command["source"] as? String {
                guard let path = declaredPath(source, root: root) else { continue }
                if path.hasSuffix(".md"), FileManager.default.fileExists(atPath: path) {
                    result.append(PluginComponent(kind: "commands", name: name, path: path))
                }
            }
        }
    }

    private func appendConventionalComponent(
        at directory: String, file: String, key: String, to result: inout [PluginComponent],
        issues: inout [Issue]
    ) {
        let path = HostPathResolver.join(directory, file)
        guard let object = json(path, issues: &issues),
            isDeclaredConfig(object, key: key)
        else {
            return
        }
        result.append(PluginComponent(kind: key, name: key, path: path))
    }

    private func isDeclaredConfig(_ object: [String: Any], key: String) -> Bool {
        if let config = object[key] as? [String: Any] { return !config.isEmpty }
        return key != "hooks" && !object.isEmpty
    }

    private func appendSkills(at path: String, to result: inout [PluginComponent]) {
        guard isDirectory(path) else { return }
        if FileManager.default.fileExists(atPath: HostPathResolver.join(path, "SKILL.md")) {
            result.append(
                PluginComponent(
                    kind: "skills", name: URL(fileURLWithPath: path).lastPathComponent, path: path))
            return
        }
        let children = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        for name in children.sorted() where !name.hasPrefix(".") {
            let child = HostPathResolver.join(path, name)
            let skillPath = HostPathResolver.join(child, "SKILL.md")
            if isDirectory(child), FileManager.default.fileExists(atPath: skillPath) {
                result.append(PluginComponent(kind: "skills", name: name, path: child))
            }
        }
    }

    private func appendMarkdownComponents(
        kind: String, at path: String, to result: inout [PluginComponent]
    ) {
        if path.hasSuffix(".md"), FileManager.default.fileExists(atPath: path) {
            result.append(
                PluginComponent(
                    kind: kind, name: URL(fileURLWithPath: path).lastPathComponent, path: path))
            return
        }
        guard isDirectory(path) else { return }
        let children = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        for name in children.sorted() where name.hasSuffix(".md") {
            result.append(
                PluginComponent(kind: kind, name: name, path: HostPathResolver.join(path, name)))
        }
    }

    private func declaredPath(_ value: String, root: String) -> String? {
        guard value == "." || value == "./" || value.hasPrefix("./") else { return nil }
        let relative = value == "." || value == "./" ? "" : String(value.dropFirst(2))
        guard !relative.split(separator: "/").contains("..") else { return nil }
        let path = URL(fileURLWithPath: root).appendingPathComponent(relative).standardizedFileURL
            .path
        let resolvedRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL
            .path
        let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            .path
        guard resolvedPath == resolvedRoot || resolvedPath.hasPrefix(resolvedRoot + "/") else {
            return nil
        }
        return path
    }

    private func stringValues(_ value: Any) -> [String] {
        if let string = value as? String { return [string] }
        return value as? [String] ?? []
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
