import Foundation

/// Agents whose standalone hook configuration Sukiru reads. Raw values match `PluginHost`
/// where both exist, so plugin-defined hooks keep their host.
public enum HookHost: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case cursor
    case antigravity
    case gemini
    case droid
    case openclaude
    case qoder
    case qoderCN = "qoder-cn"
    case qwenCode = "qwen-code"
    case codebuddy
    case commandCode = "command-code"
    case devin
    case copilot
    case grok
    case kimi
    case kiro
    case jcode
    case zcode
    case muse
    case dsh

    init?(_ plugin: PluginHost) { self.init(rawValue: plugin.rawValue) }

    /// The host table id, for `--host` and agent artwork.
    public var agentID: String {
        switch self {
        case .claude: "claude-code"
        case .gemini: "gemini-cli"
        case .copilot: "github-copilot"
        case .kimi: "kimi-code-cli"
        case .kiro: "kiro-cli"
        default: rawValue
        }
    }

    /// Hosts whose definitions may be a command handler themselves, without `type` or a
    /// nested `hooks` list (Cursor, Antigravity direct events, Copilot, Kiro, Kimi, jcode).
    var acceptsBareHandlers: Bool {
        [.cursor, .antigravity, .copilot, .kiro, .kimi, .jcode].contains(self)
    }

    /// The handler keys that carry a shell command; Copilot uses `bash` and `powershell`.
    var commandKeys: [String] { self == .copilot ? ["command", "bash", "powershell"] : ["command"] }

    var tomlLayout: HookTOMLDocument.Layout {
        switch self {
        case .kimi: .hookArray
        case .jcode: .commandTable
        default: .eventTables
        }
    }

    func command(_ details: [String: JSONValue]) -> String? {
        commandKeys.lazy.compactMap { details[$0]?.stringValue }.first
    }
}
