import Foundation

/// A host configuration file read once: its bytes' hash and parsed value.
struct HostConfigFile {
    let path: String
    let hash: String
    let value: JSONValue

    static func json(_ path: String) -> HostConfigFile? {
        guard let data = FileManager.default.contents(atPath: path),
            let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return nil }
        return HostConfigFile(path: path, hash: HookInventoryReader.hash(data), value: value)
    }

    static func yaml(_ path: String) -> HostConfigFile? {
        guard let data = FileManager.default.contents(atPath: path),
            let text = String(bytes: data, encoding: .utf8),
            let value = try? YAMLSubset.jsonValue(yaml: text)
        else { return nil }
        return HostConfigFile(path: path, hash: HookInventoryReader.hash(data), value: value)
    }

    func value(at keys: [String]) -> JSONValue? {
        keys.reduce(Optional(value)) { $0?[$1] }
    }

    func strings(at keys: [String]) -> [String] {
        (value(at: keys)?.arrayValue ?? []).compactMap(\.stringValue)
    }
}

/// The documented enablement of auto-discovered entries: Pi \`extensions\` exclusions, oh-my-pi
/// \`disabledExtensions\`, and Hermes \`plugins.enabled\`. nil where the file cannot be read.
struct AutoloadStates {
    private let piExcluded: Set<String>?
    private let ompDisabled: Set<String>?
    private let hermesEnabled: Set<String>?
    private let piAgentDir: String

    init(_ reader: AgentExtensionReader) {
        piAgentDir = reader.piAgentDir
        piExcluded = Self.strings(
            HostConfigFile.json, reader.piAgentDir + "/settings.json", ["extensions"])
        ompDisabled = Self.strings(
            HostConfigFile.yaml, reader.ompAgentDir + "/config.yml", ["disabledExtensions"])
        hermesEnabled = Self.strings(
            HostConfigFile.yaml, reader.hermesHome + "/config.yaml", ["plugins", "enabled"])
    }

    /// An absent file holds no entries; an unreadable one leaves the state unknown.
    private static func strings(
        _ read: (String) -> HostConfigFile?, _ path: String, _ keys: [String]
    ) -> Set<String>? {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        return read(path).map { Set($0.strings(at: keys)) }
    }

    func enabled(_ host: ExtensionHost, name: String) -> Bool? {
        switch host {
        case .pi:
            piExcluded.map { excluded in
                !Self.piExclusions(name, agentDir: piAgentDir).contains(where: excluded.contains)
            }
        case .omp: ompDisabled.map { !$0.contains(Self.ompID(name)) }
        case .hermes: hermesEnabled.map { $0.contains(name) }
        default: true
        }
    }

    /// Pi resolves user resource paths from its agent directory; \`-path\` excludes one exactly.
    static func piExclusions(_ name: String, agentDir: String) -> [String] {
        ["extensions/", "./extensions/", "~/.pi/agent/extensions/", agentDir + "/extensions/"]
            .map { "-" + $0 + name }
    }

    /// oh-my-pi names an extension module by its file stem.
    static func ompID(_ name: String) -> String {
        "extension-module:" + URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
    }
}
