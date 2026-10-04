import Foundation

enum HookFileMutation {
    static func replace(path: String, hash: String, contents: String) throws {
        try HookFilePrecondition(path: path, contentHash: hash).validate()
        guard let data = Data(base64Encoded: contents) else {
            throw HookError("Invalid hook replacement data")
        }
        if path.hasSuffix(".toml") {
            _ = try HookTOMLDocument(data)
        } else {
            _ = try HookJSONDocument(data)
        }
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    static func deleteHelper(path: String, hash: String, environment: SukiruEnvironment) throws {
        try HookFilePrecondition(path: path, contentHash: hash).validate()
        let producer = path.hasPrefix(environment.home + "/.orca/agent-hooks/") ? "Orca" : "Muxy"
        let suffix =
            producer == "Orca" ? "/.orca/agent-hooks/" : "/Library/Application Support/Muxy/hooks/"
        guard path.hasPrefix(environment.home + suffix),
            !HookDiagnosis(environment: environment).producerPresent(producer)
        else {
            throw HookError("Helper does not belong to an absent producer: " + path)
        }
        let plugins = PluginInventoryReader(environment: environment).read(ScanRequest())
        let inventory = HookInventoryReader(environment: environment).read(
            ScanRequest(), plugins: plugins)
        let referenced = inventory.hooks.contains {
            references($0, path: path) || ($0.handlerType == "command" && $0.targets.isEmpty)
        }
        guard inventory.issues.isEmpty, !referenced else {
            throw HookError("Hook helper may still be referenced; rescan and replan: " + path)
        }
        try FileManager.default.removeItem(atPath: path)
    }

    static func references(_ hook: AgentHook, path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return hook.targets.contains {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == resolved
        }
    }
}
