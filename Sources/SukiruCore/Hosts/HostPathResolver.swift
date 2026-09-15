/// Resolves host directory paths through the environment-abstraction seam.
///
/// Base resolution (architecture §4.1, port-reference §1):
/// - `Home` → `$HOME` (the resolved `SukiruEnvironment.home`).
/// - `Xdg` → `$XDG_CONFIG_HOME` if set and non-empty, else `$HOME/.config`.
/// - `Env` → `$<envHomeVar>` if set and non-empty, else `$HOME/<envFallbackDir>`
///   (or `$HOME` itself when there is no fallback dir).
///
/// Every env read goes through `SukiruEnvironment`, which suppresses external
/// variables under a `SUKIRU_HOME` override, so resolution stays hermetic.
public struct HostPathResolver: Sendable {
    private let environment: SukiruEnvironment
    private let fileSystem: FileSystemProbe

    public init(environment: SukiruEnvironment, fileSystem: FileSystemProbe) {
        self.environment = environment
        self.fileSystem = fileSystem
    }

    /// Joins a base directory with a relative subpath using `/`, tolerating a
    /// trailing slash on the base and an empty subpath.
    public static func join(_ base: String, _ relative: String) -> String {
        if relative.isEmpty { return base }
        var result = base
        if result.hasSuffix("/") { result.removeLast() }
        return result + "/" + relative
    }

    /// The resolved XDG config base: SUKIRU override, else the real
    /// `XDG_CONFIG_HOME` (never under a home override), else `$HOME/.config`.
    public func xdgConfigBase() -> String {
        if let override = environment.xdgConfigHome {
            return override
        }
        if let real = environment.externalValue(for: "XDG_CONFIG_HOME") {
            return real
        }
        return Self.join(environment.home, ".config")
    }

    /// The resolved config base directory for a host.
    public func configHome(for host: HostSpec) -> String {
        switch host.globalBase {
        case .home:
            return environment.home
        case .xdg:
            return xdgConfigBase()
        case .env:
            if let key = host.envHomeVar, let value = environment.externalValue(for: key) {
                return value
            }
            if let fallback = host.envFallbackDir {
                return Self.join(environment.home, fallback)
            }
            return environment.home
        }
    }

    /// The resolved absolute global skills root for a host.
    ///
    /// `openclaw` is special-cased (port-reference §1): it probes `.openclaw`,
    /// `.clawdbot`, `.moltbot` under `$HOME` in order and returns
    /// `<first existing>/skills`, falling back to `.openclaw/skills`.
    public func globalSkillsRoot(for host: HostSpec) -> String {
        if host.id == "openclaw" {
            let legacy = [".openclaw", ".clawdbot", ".moltbot"]
            for name in legacy {
                let base = Self.join(environment.home, name)
                if fileSystem.exists(atPath: base) {
                    return Self.join(base, "skills")
                }
            }
            return Self.join(Self.join(environment.home, ".openclaw"), "skills")
        }
        return Self.join(configHome(for: host), host.globalSkillDirRelative)
    }

    /// The resolved project skills root for a host under a project root.
    public func projectSkillsRoot(for host: HostSpec, projectRoot: String) -> String {
        Self.join(projectRoot, host.projectSkillDir)
    }

    /// The canonical user store, `$HOME/.agents/skills`.
    public func canonicalUserRoot() -> String {
        Self.join(environment.home, ".agents/skills")
    }

    /// The canonical project store, `<projectRoot>/.agents/skills`.
    public func canonicalProjectRoot(projectRoot: String) -> String {
        Self.join(projectRoot, ".agents/skills")
    }
}
