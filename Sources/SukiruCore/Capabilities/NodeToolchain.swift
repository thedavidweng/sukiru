import Foundation

/// A Node.js version manager Sukiru knows how to find.
public enum NodeVersionManager: String, CaseIterable, Sendable {
    case mise
    case fnm
    case nvm
    case volta
    case asdf
    case nodenv

    public var displayName: String {
        switch self {
        case .volta: "Volta"
        default: rawValue
        }
    }

    /// The command that installs a Node.js the manager uses by default, when
    /// one command does it.
    public var installCommand: String? {
        switch self {
        case .mise: "mise use -g node@lts"
        case .fnm: "fnm install --lts && fnm default lts-latest"
        case .nvm: "nvm install --lts && nvm alias default 'lts/*'"
        case .volta: "volta install node"
        case .asdf, .nodenv: nil
        }
    }
}

/// Finds Node.js for an app launched from Finder, whose PATH is launchd's
/// minimal one. Version managers add themselves to PATH in shell startup
/// files, so the login shell's PATH comes first; the managers' well-known
/// directories cover shells that fail or time out.
public struct NodeToolchain: Sendable {
    private let home: String

    public init(home: String) {
        self.home = home
    }

    /// Directories under `home` where a manager keeps a usable `npx`.
    public func managerBinDirectories() -> [String] {
        var candidates = [
            "\(home)/.local/share/mise/shims",
            "\(home)/.volta/bin",
            "\(home)/.asdf/shims",
            "\(home)/.nodenv/shims"
        ]
        candidates += fnmRoots.map { "\($0)/aliases/default/bin" }
        if let nvm = nvmDefaultBin() {
            candidates.append(nvm)
        }
        return candidates.filter { FileManager.default.isExecutableFile(atPath: "\($0)/npx") }
    }

    /// Managers present on this Mac, in display priority, judged by their
    /// data directory or an executable on `searchPath`.
    public func installedManagers(searchPath: String) -> [NodeVersionManager] {
        let fileManager = FileManager.default
        let pathEntries = searchPath.split(separator: ":").map(String.init)
        return NodeVersionManager.allCases.filter { manager in
            let hasData = dataDirectories(of: manager).contains {
                fileManager.fileExists(atPath: $0)
            }
            if hasData { return true }
            // nvm is a shell function, never an executable.
            guard manager != .nvm else { return false }
            return pathEntries.contains {
                fileManager.isExecutableFile(atPath: "\($0)/\(manager.rawValue)")
            }
        }
    }

    /// Joins PATH lists in order, dropping empty and repeated entries.
    public static func searchPath(_ lists: [[String]]) -> String {
        var seen = Set<String>()
        return lists.joined().filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
    }

    // MARK: - Locations

    private var fnmRoots: [String] {
        ["\(home)/.local/share/fnm", "\(home)/Library/Application Support/fnm", "\(home)/.fnm"]
    }

    private func dataDirectories(of manager: NodeVersionManager) -> [String] {
        switch manager {
        case .mise: ["\(home)/.local/share/mise"]
        case .fnm: fnmRoots
        case .nvm: ["\(home)/.nvm"]
        case .volta: ["\(home)/.volta"]
        case .asdf: ["\(home)/.asdf"]
        case .nodenv: ["\(home)/.nodenv"]
        }
    }

    /// The bin directory of nvm's default Node: the newest installed version
    /// matching the `default` alias (`22`, `v22.11.0`), or the newest
    /// overall for symbolic aliases such as `lts/*` or `node`.
    func nvmDefaultBin() -> String? {
        let versionsDir = "\(home)/.nvm/versions/node"
        guard let installed = try? FileManager.default.contentsOfDirectory(atPath: versionsDir)
        else { return nil }
        let versions = installed.filter { $0.hasPrefix("v") }.map { String($0.dropFirst()) }
        let alias = (try? String(contentsOfFile: "\(home)/.nvm/alias/default", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var matching = versions
        if let alias, alias.wholeMatch(of: #/v?\d+(\.\d+){0,2}/#) != nil {
            let wanted = alias.hasPrefix("v") ? String(alias.dropFirst()) : alias
            matching = versions.filter { $0 == wanted || $0.hasPrefix(wanted + ".") }
        }
        let newest = matching.max { !CapabilityDetector.version($0, isAtLeast: $1) }
        return newest.map { "\(versionsDir)/v\($0)/bin" }
    }
}
