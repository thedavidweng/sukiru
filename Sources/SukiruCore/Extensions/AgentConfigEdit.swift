import Foundation

/// One documented configuration change (ADR-0014 rule 2). Applying it re-reads the file, edits
/// only the named entry, and checks that the result parses to exactly the intended change.
enum AgentConfigEdit: Codable, Equatable, Sendable {
    /// Sets, inserts, or (nil) removes the JSON member at \`keys\`; missing parents are created.
    case jsonMember(keys: [String], value: JSONValue?)
    /// Adds or removes one string of the JSON array at \`keys\`.
    case jsonItem(keys: [String], item: String, present: Bool)
    /// Pi \`packages\`: removes a source, or narrows (disabled) or widens its resource filters.
    case piPackage(source: String, change: ExtensionAction)
    case yamlItem(keys: [String], item: String, present: Bool)
    case yamlBool(keys: [String], value: Bool)
    case yamlRemove(keys: [String])
    case tomlEnabled(server: String, value: Bool)
    case tomlRemove(server: String)

    static func apply(_ edits: [AgentConfigEdit], to data: Data) throws -> Data {
        try edits.reduce(data) { try $1.apply($0) }
    }

    func apply(_ data: Data) throws -> Data {
        switch self {
        case .jsonMember(let keys, let value): return try Self.member(keys, value, data)
        case .jsonItem(let keys, let item, let present):
            return try Self.item(keys, item: item, present: present, data)
        case .piPackage(let source, let change): return try Self.piPackage(source, change, data)
        case .yamlItem(let keys, let item, let present):
            return try Self.yaml(data) { try $0.setItem(item, present: present, at: keys) }
        case .yamlBool(let keys, let value):
            return try Self.yaml(data) {
                try $0.setScalar(String(value), json: .bool(value), at: keys)
            }
        case .yamlRemove(let keys):
            return try Self.yaml(data) { try $0.remove(at: keys) }
        case .tomlEnabled(let server, let value):
            return Data(
                try TOMLServerTables.setting(Self.text(data), name: server, enabled: value).utf8)
        case .tomlRemove(let server):
            return Data(try TOMLServerTables.removing(Self.text(data), name: server).utf8)
        }
    }

    private static func text(_ data: Data) throws -> String {
        guard let text = String(bytes: data, encoding: .utf8) else {
            throw HookError("Configuration is not UTF-8 text")
        }
        return text
    }

    private static func yaml(
        _ data: Data, _ edit: (inout YAMLBlockEditor) throws -> Void
    ) throws -> Data {
        var editor = try YAMLBlockEditor(text(data))
        try edit(&editor)
        return Data(editor.text.utf8)
    }

    private static func json(_ data: Data) throws -> (HookJSONDocument, JSONValue) {
        let source = data.isEmpty ? HookJSONDocument.emptyDocument : data
        return (
            try HookJSONDocument(source), try JSONDecoder().decode(JSONValue.self, from: source)
        )
    }

    private static func member(_ keys: [String], _ value: JSONValue?, _ data: Data) throws -> Data {
        let (document, before) = try json(data)
        var existing: [HookJSONDocument.Step] = []
        var rest = keys
        while rest.count > 1, document.node(at: existing + [.key(rest[0])])?.isObject == true {
            existing.append(.key(rest.removeFirst()))
        }
        guard rest.count == 1 || document.node(at: existing + [.key(rest[0])]) == nil else {
            throw HookError("Expected an object at " + keys.joined(separator: "."))
        }
        let key = rest.removeFirst()
        let nested = value.map { leaf in
            rest.reversed().reduce(HookEditValue(leaf)) { .object([($1, $0)]) }
        }
        guard nested != nil || rest.isEmpty else { return data }
        let result = try document.setting(key, to: nested, at: existing)
        return try verified(result, before.setting(keys, to: value))
    }

    private static func item(
        _ keys: [String], item: String, present: Bool, _ data: Data
    ) throws -> Data {
        let (document, before) = try json(data)
        let items = before.at(keys)?.arrayValue
        guard let items else {
            guard present else { return data }
            return try member(keys, .array([.string(item)]), data)
        }
        let steps = keys.map(HookJSONDocument.Step.key)
        let result: Data
        var expected = items
        if present {
            guard !items.contains(.string(item)) else { return data }
            result = try document.settingElement(nil, to: .string(item), at: steps)
            expected.append(.string(item))
        } else {
            guard let index = items.firstIndex(of: .string(item)) else { return data }
            result = try document.settingElement(index, to: nil, at: steps)
            expected.remove(at: index)
        }
        return try verified(result, before.setting(keys, to: .array(expected)))
    }

    private static func piPackage(
        _ source: String, _ change: ExtensionAction, _ data: Data
    ) throws -> Data {
        let (document, before) = try json(data)
        var packages = before["packages"]?.arrayValue ?? []
        guard
            let index = packages.firstIndex(where: {
                ($0.stringValue ?? $0["source"]?.stringValue) == source
            })
        else { throw HookError("Pi package is no longer configured: " + source) }
        var members = packages[index].objectValue ?? ["source": .string(source)]
        let replacement: JSONValue?
        switch change {
        case .remove:
            replacement = nil
        case .disable:
            for filter in AgentExtensionReader.piPackageFilters { members[filter] = .array([]) }
            replacement = .object(members)
        case .enable:
            let filters = AgentExtensionReader.piPackageFilters
            for filter in filters where members[filter] == .array([]) { members[filter] = nil }
            replacement = Array(members.keys) == ["source"] ? .string(source) : .object(members)
        }
        let result = try document.settingElement(
            index, to: replacement.map(HookEditValue.init), at: [.key("packages")])
        if let replacement { packages[index] = replacement } else { packages.remove(at: index) }
        return try verified(result, before.setting(["packages"], to: .array(packages)))
    }

    private static func verified(_ data: Data, _ expected: JSONValue) throws -> Data {
        guard (try? JSONDecoder().decode(JSONValue.self, from: data)) == expected else {
            throw HookError("The edited JSON would not read back as intended")
        }
        return data
    }
}
