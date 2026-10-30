import CryptoKit
import Foundation

/// Agents whose add-ons (auto-loaded extensions, packages, plugins outside `PluginHost`, and
/// MCP servers) Sukiru lists. Raw values match `HookHost` where both exist.
public enum ExtensionHost: String, Codable, CaseIterable, Sendable {
    // swiftlint:disable:next identifier_name
    case pi
    case omp
    case amp
    case opencode
    case hermes
    case dsh
    case claude
    case openclaude
    case codex
    case cursor
    case droid
    case devin
    case muse
    case gemini
    case grok

    /// The host table id, for agent artwork.
    public var agentID: String {
        if self == .hermes { return "hermes-agent" }
        return HookHost(rawValue: rawValue)?.agentID ?? rawValue
    }

    /// The categories this host can hold, in list order.
    public var categories: [ExtensionCategory] {
        switch self {
        case .pi: [.package, .autoloaded]
        case .omp, .opencode, .hermes: [.autoloaded, .mcpServer]
        case .amp: [.autoloaded]
        case .dsh: [.package]
        case .droid, .openclaude, .devin: [.plugin, .mcpServer]
        case .claude, .codex, .cursor, .muse, .gemini, .grok: [.mcpServer]
        }
    }
}

public enum ExtensionCategory: String, Codable, CaseIterable, Sendable {
    /// A file or directory in an auto-discovery folder (Hermes: a plugin directory).
    case autoloaded
    /// A declared package source (Pi `packages`, a DSH profile dependency).
    case package
    /// A plugin of a host without a `PluginHost` lifecycle.
    case plugin
    case mcpServer
}

/// One add-on an agent loads. Sukiru never loads the code; changes touch exactly the scanned
/// entry, through the host's command where one exists (ADR-0017).
public struct AgentExtension: Codable, Equatable, Sendable, Identifiable {
    /// `enabledEntry`: a Hermes `plugins.enabled` name without a plugin directory.
    /// `configEntry`: an entry inside a host configuration file.
    public enum Kind: String, Codable, Sendable {
        case file, directory, link, enabledEntry, configEntry
    }

    public let host: ExtensionHost
    public let category: ExtensionCategory
    public let name: String
    /// The discovered entry, or the configuration file that declares it.
    public let path: String
    public let kind: Kind
    public let producer: String
    public let evidence: [String]
    public let contentHash: String
    /// nil when the host records no state Sukiru can read.
    public let enabled: Bool?
    /// The configured source, command, or URL.
    public let detail: String?
    /// Where the entry is declared inside the host, such as a DSH profile.
    public let scopeName: String?

    init(
        host: ExtensionHost, category: ExtensionCategory = .autoloaded, name: String, path: String,
        kind: Kind, producer: String, evidence: [String], contentHash: String,
        enabled: Bool? = nil, detail: String? = nil, scopeName: String? = nil
    ) {
        self.host = host
        self.category = category
        self.name = name
        self.path = path
        self.kind = kind
        self.producer = producer
        self.evidence = evidence
        self.contentHash = contentHash
        self.enabled = enabled
        self.detail = detail
        self.scopeName = scopeName
    }

    public var id: String {
        [host.rawValue, category.rawValue, kind.rawValue, path, scopeName ?? "", name]
            .joined(separator: ":")
    }

    func with(enabled: Bool?) -> AgentExtension {
        AgentExtension(
            host: host, category: category, name: name, path: path, kind: kind,
            producer: producer, evidence: evidence, contentHash: contentHash, enabled: enabled,
            detail: detail, scopeName: scopeName)
    }
}

public struct ExtensionInventory: Codable, Equatable, Sendable {
    public let extensions: [AgentExtension]
    public init(extensions: [AgentExtension]) { self.extensions = extensions }
    public var isEmpty: Bool { extensions.isEmpty }
}

/// Reads user-scope discovery directories; no extension code is loaded or evaluated.
public struct AgentExtensionReader: Sendable {
    let environment: SukiruEnvironment

    public init(environment: SukiruEnvironment) { self.environment = environment }

    public func read() -> ExtensionInventory {
        let states = AutoloadStates(self)
        var result: [AgentExtension] = []
        for (host, directory) in directories() {
            for name in entries(directory) {
                if let item = entry(host, directory: directory, name: name) {
                    result.append(item.with(enabled: states.enabled(host, name: name)))
                }
            }
        }
        for (host, container) in disabledContainers() {
            for name in entries(container) {
                if let item = entry(host, directory: container, name: name) {
                    result.append(item.with(enabled: false))
                }
            }
        }
        result += danglingHermesEntries() + packages() + plugins() + mcpServers()
        return ExtensionInventory(extensions: result.sorted { $0.id < $1.id })
    }

    private func entry(_ host: ExtensionHost, directory: String, name: String) -> AgentExtension? {
        let path = directory + "/" + name
        guard let kind = kind(path, host: host), let hash = Self.hash(path) else { return nil }
        let producer = Self.producer(name)
        return AgentExtension(
            host: host, name: name, path: path, kind: kind, producer: producer.name,
            evidence: producer.evidence, contentHash: hash)
    }

    /// The directories each host auto-loads at user scope.
    func directories() -> [(ExtensionHost, String)] {
        [
            (.pi, piAgentDir + "/extensions"),
            (.omp, ompAgentDir + "/extensions"),
            (.amp, configHome + "/amp/plugins"),
            (.opencode, openCodeDir + "/plugins"),
            (.opencode, openCodeDir + "/plugin"),
            (.hermes, hermesHome + "/plugins")
        ]
    }

    /// Amp and OpenCode document no per-file switch; a disabled file is moved here, beside the
    /// discovery folder, so neither host discovers it (ADR-0008 local-file exception).
    func disabledContainers() -> [(ExtensionHost, String)] {
        [
            (.amp, configHome + "/amp/disabled-extensions"),
            (.opencode, openCodeDir + "/disabled-extensions")
        ]
    }

    var configHome: String {
        environment.externalValue(for: "XDG_CONFIG_HOME") ?? environment.home + "/.config"
    }
    var openCodeDir: String {
        environment.externalValue(for: "OPENCODE_CONFIG_DIR") ?? configHome + "/opencode"
    }
    var piAgentDir: String { environment.home + "/.pi/agent" }
    var ompAgentDir: String { environment.home + "/.omp/agent" }
    var hermesHome: String { environment.home + "/.hermes" }

    private func kind(_ path: String, host: ExtensionHost) -> AgentExtension.Kind? {
        switch DefaultFileSystemProbe().entryKind(atPath: path) {
        case .symlink?: return .link
        case .directory?: return .directory
        case .file? where host != .hermes:
            let suffixes = [".ts", ".js", ".mjs", ".cjs", ".mts"]
            return suffixes.contains(where: path.hasSuffix) ? .file : nil
        default: return nil
        }
    }

    /// Orca and Muxy name every integration they install with their own prefix.
    static func producer(_ name: String) -> (name: String, evidence: [String]) {
        for (producer, prefix) in [("Orca", "orca-"), ("Muxy", "muxy-")]
        where name.hasPrefix(prefix) {
            return (producer, ["\(producer) names the integrations it installs \(prefix)*"])
        }
        return ("Unknown", [])
    }

    private func danglingHermesEntries() -> [AgentExtension] {
        let path = hermesHome + "/config.yaml"
        guard let data = FileManager.default.contents(atPath: path),
            let text = String(bytes: data, encoding: .utf8)
        else { return [] }
        let hash = HookInventoryReader.hash(data)
        return HermesPluginList(text).names.filter {
            !FileManager.default.fileExists(atPath: hermesHome + "/plugins/" + $0)
        }.map { name in
            let producer = Self.producer(name)
            return AgentExtension(
                host: .hermes, name: name, path: path, kind: .enabledEntry,
                producer: producer.name,
                evidence: producer.evidence + ["Enabled in config.yaml without a plugin directory"],
                contentHash: hash, enabled: true)
        }
    }

    func entries(_ directory: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
            .filter { !$0.hasPrefix(".") }.sorted()
    }

    /// A file's bytes, a link's destination, or a directory's relative paths and file bytes.
    static func hash(_ path: String) -> String? {
        let manager = FileManager.default
        switch DefaultFileSystemProbe().entryKind(atPath: path) {
        case .symlink?:
            return (try? manager.destinationOfSymbolicLink(atPath: path)).map { "link:" + $0 }
        case .file?:
            return manager.contents(atPath: path).map(HookInventoryReader.hash)
        case .directory?:
            var digest = SHA256()
            for relative in (manager.subpaths(atPath: path) ?? []).sorted() {
                digest.update(data: Data((relative + "\0").utf8))
                if let data = manager.contents(atPath: path + "/" + relative) {
                    digest.update(data: Data(HookInventoryReader.hash(data).utf8))
                }
            }
            return digest.finalize().map { String(format: "%02x", $0) }.joined()
        default:
            return nil
        }
    }
}

/// Hermes' block-style `plugins:` → `enabled:` list. Flow-style lists are left unread.
struct HermesPluginList {
    let lines: [String]
    /// Line index and plugin name of each `enabled` item.
    private(set) var items: [(line: Int, name: String)] = []
    private(set) var enabledLine: Int?

    init(_ text: String) {
        lines = text.components(separatedBy: "\n")
        guard let plugins = lines.firstIndex(where: { Self.content($0) == "plugins:" }) else {
            return
        }
        var index = plugins + 1
        while index < lines.count {
            let line = lines[index]
            let content = Self.content(line)
            if !content.isEmpty && Self.indent(line) == 0 { return }
            if let enabledLine {
                if content.hasPrefix("- ") && Self.indent(line) >= Self.indent(lines[enabledLine]) {
                    let name = content.dropFirst(2).trimmingCharacters(in: .whitespaces)
                    items.append(
                        (index, name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))))
                } else if !content.isEmpty {
                    return
                }
            } else if content == "enabled:" {
                enabledLine = index
            }
            index += 1
        }
    }

    var names: [String] { items.map(\.name) }

    /// The text without `name`'s item; an emptied list becomes `enabled: []`.
    func removing(_ name: String) -> String? {
        guard let item = items.first(where: { $0.name == name }), let enabledLine else {
            return nil
        }
        var result = lines
        result.remove(at: item.line)
        if items.count == 1 {
            let line = lines[enabledLine]
            result[enabledLine] = String(line.prefix(Self.indent(line))) + "enabled: []"
        }
        return result.joined(separator: "\n")
    }

    private static func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }

    private static func content(_ line: String) -> String {
        HookTOMLDocument.withoutComment(line).trimmingCharacters(in: .whitespaces)
    }
}
