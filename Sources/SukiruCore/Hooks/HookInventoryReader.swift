import CryptoKit
import Foundation
import Yams

/// Reconstructs current local facts. No host, producer, shell, network, or hook is invoked.
public struct HookInventoryReader: Sendable {
    let environment: SukiruEnvironment

    public init(environment: SukiruEnvironment) { self.environment = environment }

    public func read(_ request: ScanRequest, plugins: PluginInventory) -> HookInventory {
        var hooks: [AgentHook] = []
        var issues: [HookInventoryIssue] = []
        for descriptor in sources(request, plugins: plugins) {
            guard FileManager.default.fileExists(atPath: descriptor.path) else { continue }
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: descriptor.path))
                let source = descriptor.source(hash: Self.hash(data))
                if descriptor.path.hasSuffix(".toml") || descriptor.tomlPreferenceKey != nil {
                    guard let toml = try tomlData(data, descriptor: descriptor) else { continue }
                    let document = try HookTOMLDocument(toml)
                    for handler in document.handlers {
                        let matcher = document.groups.first {
                            $0.event == handler.event && $0.index == handler.group
                        }?.matcher
                        hooks.append(
                            try item(
                                source: source, event: handler.event, matcher: matcher,
                                details: handler.details, position: (handler.group, handler.index)))
                    }
                } else {
                    let object: JSONValue
                    if descriptor.path.hasSuffix(".md") {
                        object = try frontmatter(data)
                    } else if descriptor.path.hasSuffix(".plist") {
                        let plist = try PropertyListSerialization.propertyList(
                            from: data, format: nil)
                        object = try JSONDecoder().decode(
                            JSONValue.self, from: JSONSerialization.data(withJSONObject: plist))
                    } else {
                        _ = try HookJSONDocument(data)
                        object = try JSONDecoder().decode(JSONValue.self, from: data)
                    }
                    let container = try hookObject(object, prefix: descriptor.prefix)
                    hooks += try items(container, source: source)
                }
            } catch {
                issues.append(
                    HookInventoryIssue(
                        host: descriptor.host, path: descriptor.path,
                        scopeRoot: descriptor.scopeRoot, message: error.localizedDescription))
            }
        }
        return HookInventory(
            hooks: hooks.sorted { $0.id < $1.id }, issues: issues.sorted { $0.id < $1.id })
    }

    private func tomlData(_ data: Data, descriptor: SourceDescriptor) throws -> Data? {
        guard let key = descriptor.tomlPreferenceKey else { return data }
        let object =
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        guard let value = object?[key] else { return nil }
        guard let text = value as? String, let payload = Data(base64Encoded: text) else {
            throw HookError("Invalid managed TOML preference: " + key)
        }
        return payload
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func hookObject(_ value: JSONValue, prefix: [String]) throws -> JSONValue? {
        var object = value
        for key in prefix {
            let next: JSONValue?
            if let array = object.arrayValue, let index = Int(key), array.indices.contains(index) {
                next = array[index]
            } else {
                next = object[key]
            }
            guard let next else { throw HookError("Invalid plugin hook declaration") }
            object = next
        }
        guard object.objectValue != nil else { throw HookError("Expected hook source object") }
        return object["hooks"]
    }

    private func items(_ value: JSONValue?, source: HookSource) throws -> [AgentHook] {
        guard let value else { return [] }
        guard let events = value.objectValue else { throw HookError("Expected hooks object") }
        var result: [AgentHook] = []
        for event in events.keys.sorted() {
            guard let groups = events[event]?.arrayValue else {
                throw HookError("Expected matcher groups for " + event)
            }
            for (groupIndex, group) in groups.enumerated() {
                guard let handlers = group["hooks"]?.arrayValue,
                    group["matcher"] == nil || group["matcher"]?.stringValue != nil
                else { throw HookError("Invalid hook group for " + event) }
                for (handlerIndex, handler) in handlers.enumerated() {
                    guard let details = handler.objectValue else {
                        throw HookError("Expected handler object")
                    }
                    result.append(
                        try item(
                            source: source, event: event, matcher: group["matcher"]?.stringValue,
                            details: details, position: (groupIndex, handlerIndex)))
                }
            }
        }
        return result
    }

    private func item(
        source: HookSource, event: String, matcher: String?, details: [String: JSONValue],
        position: (group: Int, handler: Int)
    ) throws -> AgentHook {
        guard let type = details["type"]?.stringValue else {
            throw HookError("Hook handler has no type")
        }
        let required: [String: [String]] = [
            "command": ["command"], "http": ["url"],
            "mcp_tool": ["server", "tool"], "prompt": ["prompt"], "agent": ["prompt"]
        ]
        let invalid =
            required[type] == nil
            || !(required[type] ?? []).allSatisfy { details[$0]?.stringValue?.isEmpty == false }
        let assessment = HookDiagnosis(environment: environment)
            .inspect(details: details, source: source)
        let identity = [
            source.host.rawValue, source.path, source.tier, source.scopeRoot,
            source.definitionRoot.joined(separator: "/"),
            source.managingPluginID ?? "", event, String(position.group), String(position.handler)
        ]
        return AgentHook(
            id: identity.map { "\($0.utf8.count):\($0)" }.joined(), source: source,
            event: event, matcher: matcher, handlerType: type, details: details,
            groupIndex: position.group, handlerIndex: position.handler,
            attribution: assessment.attribution,
            health: invalid ? .invalid : assessment.health,
            evidence: invalid
                ? ["Invalid or unsupported handler fields for " + type] : assessment.evidence,
            targets: assessment.targets, trust: "Unknown — review remains in the host")
    }

    private func frontmatter(_ data: Data) throws -> JSONValue {
        guard let text = String(bytes: data, encoding: .utf8) else {
            throw HookError("Hook frontmatter is not UTF-8")
        }
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
            let end = lines.dropFirst().firstIndex(where: {
                $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---"
            })
        else { return .object([:]) }
        return try YAMLDecoder().decode(
            JSONValue.self, from: lines[1..<end].joined(separator: "\n"))
    }
}
