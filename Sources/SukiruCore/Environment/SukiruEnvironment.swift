/// The sole fatal environment condition: the process exits
/// with code 2 when this is present.
public enum FatalEnvironmentProblem: Error, Equatable, Sendable {
    /// `SUKIRU_HOME` was set to a path that does not exist.
    case sukiruHomeMissing(path: String)
}

/// Resolved Sukiru environment overrides.
///
/// All path-affecting environment reads flow through this single seam:
/// `SUKIRU_HOME` replaces `$HOME`, `SUKIRU_ROOTS` supplies a colon-separated
/// project-root list, and `SUKIRU_XDG_CONFIG_HOME` / `SUKIRU_XDG_STATE_HOME`
/// replace the XDG base lookups. Empty-string values are treated as unset,
/// guarding the archive's `XDG_STATE_HOME=""` relative-path resolution bug.
public struct SukiruEnvironment: Equatable, Sendable {
    /// Home directory used for all path resolution.
    public let home: String
    /// True when a non-empty `SUKIRU_HOME` supplied the home.
    public let homeIsOverridden: Bool
    /// Extra project roots from `SUKIRU_ROOTS`, in the order given.
    public let projectRoots: [String]
    /// XDG config base override, or nil when unset/empty.
    public let xdgConfigHome: String?
    /// XDG state base override, or nil when unset/empty.
    public let xdgStateHome: String?

    /// Non-empty values of host-relevant external environment variables,
    /// captured ONLY when `SUKIRU_HOME` is NOT overriding home. Under an
    /// override (tests and validation), this is empty so that nothing outside
    /// the fixture is read — the sole permitted external probe is `/etc/codex`
    /// existence, which keeps fixture scans hermetic.
    private let externalEnv: [String: String]

    public static let sukiruHomeKey = "SUKIRU_HOME"
    public static let sukiruRootsKey = "SUKIRU_ROOTS"
    public static let xdgConfigHomeKey = "SUKIRU_XDG_CONFIG_HOME"
    public static let xdgStateHomeKey = "SUKIRU_XDG_STATE_HOME"
    public static let homeKey = "HOME"

    /// External environment variables consulted by host detection and lock
    /// resolution when scanning the real machine: the three Env-base host
    /// homes, the real XDG config/state bases, and Zed's custom probe
    /// variables. Space-listed to avoid a multi-line collection literal (repo
    /// lint gates conflict on those).
    public static let externalEnvKeys: [String] =
        "CLAUDE_CONFIG_DIR CODEX_HOME VIBE_HOME XDG_CONFIG_HOME XDG_STATE_HOME APPDATA FLATPAK_XDG_CONFIG_HOME"
        .split(separator: " ").map(String.init)

    public init(reader: EnvironmentReader) {
        if let overridden = Self.nonEmpty(reader.value(for: Self.sukiruHomeKey)) {
            self.home = overridden
            self.homeIsOverridden = true
        } else {
            self.home = reader.value(for: Self.homeKey) ?? ""
            self.homeIsOverridden = false
        }

        if let roots = Self.nonEmpty(reader.value(for: Self.sukiruRootsKey)) {
            let parts = roots.split(separator: ":", omittingEmptySubsequences: true)
            self.projectRoots = parts.map(String.init)
        } else {
            self.projectRoots = []
        }

        self.xdgConfigHome = Self.nonEmpty(reader.value(for: Self.xdgConfigHomeKey))
        self.xdgStateHome = Self.nonEmpty(reader.value(for: Self.xdgStateHomeKey))

        if self.homeIsOverridden {
            self.externalEnv = [:]
        } else {
            var captured: [String: String] = [:]
            for key in Self.externalEnvKeys {
                if let value = Self.nonEmpty(reader.value(for: key)) {
                    captured[key] = value
                }
            }
            self.externalEnv = captured
        }
    }

    /// The non-empty value of an external (non-`SUKIRU_*`) environment variable
    /// used in host detection, or nil. Always nil under a `SUKIRU_HOME`
    /// override, preserving scan hermeticity.
    public func externalValue(for key: String) -> String? {
        externalEnv[key]
    }

    /// Returns the fatal environment problem, if any: an
    /// overridden `SUKIRU_HOME` pointing at a path that does not exist.
    public func fatalProblem(fileSystem: FileSystemProbe) -> FatalEnvironmentProblem? {
        guard homeIsOverridden, !fileSystem.exists(atPath: home) else {
            return nil
        }
        return .sukiruHomeMissing(path: home)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else {
            return nil
        }
        return value
    }
}
