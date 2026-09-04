use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Hash, Serialize, Deserialize)]
pub struct AgentId(pub String);

impl AgentId {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }
}

/// Where an agent's global skills directory is rooted.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub enum GlobalBase {
    /// `$HOME` (or `%USERPROFILE%`).
    #[default]
    Home,
    /// `$XDG_CONFIG_HOME`, else `$HOME/.config`.
    Xdg,
    /// `$env_home` when set, else `$HOME/<env_fallback>`.
    Env,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct AgentDefinition {
    pub id: AgentId,
    pub display_name: String,
    pub project_skills_dir: PathBuf,
    /// Path relative to the resolved global base.
    pub global_skills_dir: PathBuf,
    /// Marker checked against the resolved global base (or home for Home-based agents).
    pub detection_marker: PathBuf,
    pub env_home: Option<String>,
    pub env_fallback: Option<PathBuf>,
    pub extra_markers: Vec<PathBuf>,
    pub global_base: GlobalBase,
    pub detect_in_project: bool,
    pub show_in_universal_list: bool,
}

impl AgentDefinition {
    pub fn project_skills_path(&self, project_root: &Path) -> PathBuf {
        project_root.join(&self.project_skills_dir)
    }

    pub fn config_home(&self, default_home: &Path) -> PathBuf {
        self.config_home_with(default_home, env_lookup)
    }

    fn config_home_with<F>(&self, default_home: &Path, get_env: F) -> PathBuf
    where
        F: Fn(&str) -> Option<std::ffi::OsString>,
    {
        match self.global_base {
            GlobalBase::Home => default_home.to_path_buf(),
            GlobalBase::Xdg => get_env("XDG_CONFIG_HOME")
                .filter(|value| !value.is_empty())
                .map(PathBuf::from)
                .unwrap_or_else(|| default_home.join(".config")),
            GlobalBase::Env => {
                if let Some(env_name) = &self.env_home {
                    if let Some(value) = get_env(env_name) {
                        if !value.is_empty() {
                            return PathBuf::from(value);
                        }
                    }
                }
                match &self.env_fallback {
                    Some(fallback) => default_home.join(fallback),
                    None => default_home.to_path_buf(),
                }
            }
        }
    }

    pub fn global_skills_path(&self, default_home: &Path) -> PathBuf {
        self.global_skills_path_with(default_home, env_lookup)
    }

    fn global_skills_path_with<F>(&self, default_home: &Path, get_env: F) -> PathBuf
    where
        F: Fn(&str) -> Option<std::ffi::OsString> + Copy,
    {
        if self.id.0 == "openclaw" {
            for marker in [".openclaw", ".clawdbot", ".moltbot"] {
                if default_home.join(marker).exists() {
                    return default_home.join(marker).join("skills");
                }
            }
            return default_home.join(".openclaw/skills");
        }
        self.config_home_with(default_home, get_env)
            .join(&self.global_skills_dir)
    }

    pub fn is_detected(&self, home: &Path) -> bool {
        self.is_detected_with(home, env_lookup)
    }

    pub fn is_detected_with<F>(&self, home: &Path, get_env: F) -> bool
    where
        F: Fn(&str) -> Option<std::ffi::OsString> + Copy,
    {
        self.is_detected_at(home, &std::env::current_dir().unwrap_or_default(), get_env)
    }

    /// Upstream `detectInstalled` with an injectable cwd (Replit / CodeBuddy / Continue).
    ///
    /// Deliberately stricter than upstream on one point: a directory whose
    /// sole content is a `skills` entry is treated as residue left by the
    /// skills CLI spraying symlinks into every known agent layout, not as
    /// proof that the client itself is installed.
    pub fn is_detected_at<F>(&self, home: &Path, cwd: &Path, get_env: F) -> bool
    where
        F: Fn(&str) -> Option<std::ffi::OsString> + Copy,
    {
        if self.id.0 == "universal" {
            return false;
        }
        if self.id.0 == "codex" && marks_installation(Path::new("/etc/codex")) {
            return true;
        }
        // Replit is cwd-only: `existsSync(join(process.cwd(), '.replit'))`.
        if self.id.0 == "replit" {
            return cwd.join(".replit").exists();
        }
        if self.id.0 == "zed" {
            let xdg = get_env("XDG_CONFIG_HOME")
                .filter(|value| !value.is_empty())
                .map(PathBuf::from)
                .unwrap_or_else(|| home.join(".config"));
            if xdg.join("zed").exists() {
                return true;
            }
            if get_env("APPDATA")
                .filter(|value| !value.is_empty())
                .is_some_and(|appdata| PathBuf::from(appdata).join("Zed").exists())
            {
                return true;
            }
            return get_env("FLATPAK_XDG_CONFIG_HOME")
                .filter(|value| !value.is_empty())
                .is_some_and(|flatpak| PathBuf::from(flatpak).join("zed").exists());
        }
        if self.detect_in_project
            && (marks_installation(&cwd.join(&self.detection_marker))
                || marks_installation(&cwd.join(&self.project_skills_dir)))
        {
            return true;
        }
        let base = self.config_home_with(home, get_env);
        // Env-home agents (Claude / Codex / Vibe) detect the config root itself.
        // An empty marker must not fall through to `home.join("")`, which is `$HOME`.
        if self.detection_marker.as_os_str().is_empty() {
            return marks_installation(&base);
        }
        if marks_installation(&base.join(&self.detection_marker))
            || marks_installation(&home.join(&self.detection_marker))
        {
            return true;
        }
        self.extra_markers
            .iter()
            .any(|marker| marks_installation(&home.join(marker)))
    }
}

/// Whether a path is real evidence that an agent client exists. A plain file
/// always counts; a directory counts unless its entire content is a bare
/// `skills` entry — that exact layout is what the skills CLI leaves behind in
/// every known agent home when spraying symlinks, installed or not.
fn marks_installation(path: &Path) -> bool {
    if path.is_file() {
        return true;
    }
    if !path.is_dir() {
        return false;
    }
    let Ok(entries) = std::fs::read_dir(path) else {
        // Unreadable directories fall back to plain existence.
        return true;
    };
    let mut saw_skills = false;
    let mut saw_other = false;
    for entry in entries.flatten() {
        let name = entry.file_name();
        if name == "skills" {
            saw_skills = true;
        } else if name != ".DS_Store" && name != ".localized" {
            // macOS metadata noise never counts as content.
            saw_other = true;
        }
    }
    !(saw_skills && !saw_other)
}

#[derive(Clone, Debug)]
pub struct AgentRegistry {
    home: PathBuf,
    definitions: Vec<AgentDefinition>,
}

impl AgentRegistry {
    pub fn from_home(home: impl Into<PathBuf>) -> Self {
        Self {
            home: home.into(),
            definitions: definitions(),
        }
    }

    pub fn home(&self) -> &Path {
        &self.home
    }

    pub fn all(&self) -> &[AgentDefinition] {
        &self.definitions
    }

    pub fn by_id(&self, id: &str) -> Option<&AgentDefinition> {
        self.definitions.iter().find(|agent| agent.id.0 == id)
    }

    pub fn detected(&self) -> Vec<&AgentDefinition> {
        self.definitions
            .iter()
            .filter(|agent| agent.is_detected(&self.home))
            .collect()
    }

    pub fn global_skill_roots(&self) -> Vec<(&AgentDefinition, PathBuf)> {
        self.detected()
            .into_iter()
            .map(|agent| (agent, agent.global_skills_path(&self.home)))
            .collect()
    }

    /// Global skill roots of agents that are *not* detected but whose skills
    /// directory exists on disk — typically residue from a previous install
    /// or from the skills CLI spraying links. They stay scannable so leftover
    /// placements remain visible and cleanable, while the UI hides the agent
    /// itself.
    pub fn leftover_global_skill_roots(&self) -> Vec<(&AgentDefinition, PathBuf)> {
        self.definitions
            .iter()
            .filter_map(|agent| {
                let root = agent.global_skills_path(&self.home);
                (root.exists() && !agent.is_detected(&self.home)).then_some((agent, root))
            })
            .collect()
    }

    pub fn project_skill_roots(&self, project_root: &Path) -> Vec<(&AgentDefinition, PathBuf)> {
        self.definitions
            .iter()
            .filter(|agent| {
                project_root.join(&agent.project_skills_dir).exists()
                    || project_root.join(&agent.detection_marker).exists()
            })
            .map(|agent| (agent, agent.project_skills_path(project_root)))
            .collect()
    }
}

impl Default for AgentRegistry {
    fn default() -> Self {
        let home = std::env::var_os("HOME")
            .or_else(|| std::env::var_os("USERPROFILE"))
            .map(PathBuf::from)
            .expect("a home directory is required to detect agent workspaces");
        Self::from_home(home)
    }
}

fn env_lookup(name: &str) -> Option<std::ffi::OsString> {
    std::env::var_os(name)
}

struct Spec {
    id: &'static str,
    display: &'static str,
    project: &'static str,
    global: &'static str,
    marker: &'static str,
    env: Option<(&'static str, &'static str)>,
    extra: &'static [&'static str],
    base: GlobalBase,
    detect_in_project: bool,
    show_universal: bool,
}

fn definitions() -> Vec<AgentDefinition> {
    const SPECS: &[Spec] = &[
        Spec {
            id: "adal",
            display: "AdaL",
            project: ".adal/skills",
            global: ".adal/skills",
            marker: ".adal",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "aider-desk",
            display: "AiderDesk",
            project: ".aider-desk/skills",
            global: ".aider-desk/skills",
            marker: ".aider-desk",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "amp",
            display: "Amp",
            project: ".agents/skills",
            global: "agents/skills",
            marker: "amp",
            env: None,
            extra: &[],
            base: GlobalBase::Xdg,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "antigravity",
            display: "Antigravity",
            project: ".agents/skills",
            global: ".gemini/antigravity/skills",
            marker: ".gemini/antigravity",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "augment",
            display: "Augment",
            project: ".augment/skills",
            global: ".augment/skills",
            marker: ".augment",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "bob",
            display: "IBM Bob",
            project: ".bob/skills",
            global: ".bob/skills",
            marker: ".bob",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "claude-code",
            display: "Claude Code",
            project: ".claude/skills",
            global: "skills",
            marker: "",
            env: Some(("CLAUDE_CONFIG_DIR", ".claude")),
            extra: &[],
            base: GlobalBase::Env,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "cline",
            display: "Cline",
            project: ".agents/skills",
            global: ".agents/skills",
            marker: ".cline",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "codearts-agent",
            display: "CodeArts Agent",
            project: ".codeartsdoer/skills",
            global: ".codeartsdoer/skills",
            marker: ".codeartsdoer",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "codebuddy",
            display: "CodeBuddy",
            project: ".codebuddy/skills",
            global: ".codebuddy/skills",
            marker: ".codebuddy",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: true,
            show_universal: true,
        },
        Spec {
            id: "codemaker",
            display: "Codemaker",
            project: ".codemaker/skills",
            global: ".codemaker/skills",
            marker: ".codemaker",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "codestudio",
            display: "Code Studio",
            project: ".codestudio/skills",
            global: ".codestudio/skills",
            marker: ".codestudio",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "codex",
            display: "Codex",
            project: ".agents/skills",
            global: "skills",
            marker: "",
            env: Some(("CODEX_HOME", ".codex")),
            extra: &[],
            base: GlobalBase::Env,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "command-code",
            display: "Command Code",
            project: ".commandcode/skills",
            global: ".commandcode/skills",
            marker: ".commandcode",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "continue",
            display: "Continue",
            project: ".continue/skills",
            global: ".continue/skills",
            marker: ".continue",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: true,
            show_universal: true,
        },
        Spec {
            id: "cortex",
            display: "Cortex Code",
            project: ".cortex/skills",
            global: ".snowflake/cortex/skills",
            marker: ".snowflake/cortex",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "crush",
            display: "Crush",
            project: ".crush/skills",
            global: ".config/crush/skills",
            marker: ".config/crush",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "cursor",
            display: "Cursor",
            project: ".agents/skills",
            global: ".cursor/skills",
            marker: ".cursor",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "deepagents",
            display: "Deep Agents",
            project: ".agents/skills",
            global: ".deepagents/agent/skills",
            marker: ".deepagents",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "devin",
            display: "Devin for Terminal",
            project: ".devin/skills",
            global: "devin/skills",
            marker: "devin",
            env: None,
            extra: &[],
            base: GlobalBase::Xdg,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "dexto",
            display: "Dexto",
            project: ".agents/skills",
            global: ".agents/skills",
            marker: ".dexto",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "droid",
            display: "Droid",
            project: ".factory/skills",
            global: ".factory/skills",
            marker: ".factory",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "firebender",
            display: "Firebender",
            project: ".agents/skills",
            global: ".firebender/skills",
            marker: ".firebender",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "forgecode",
            display: "ForgeCode",
            project: ".forge/skills",
            global: ".forge/skills",
            marker: ".forge",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "gemini-cli",
            display: "Gemini CLI",
            project: ".agents/skills",
            global: ".gemini/skills",
            marker: ".gemini",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "github-copilot",
            display: "GitHub Copilot",
            project: ".agents/skills",
            global: ".copilot/skills",
            marker: ".copilot",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "goose",
            display: "Goose",
            project: ".goose/skills",
            global: "goose/skills",
            marker: "goose",
            env: None,
            extra: &[],
            base: GlobalBase::Xdg,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "hermes-agent",
            display: "Hermes Agent",
            project: ".hermes/skills",
            global: ".hermes/skills",
            marker: ".hermes",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "iflow-cli",
            display: "iFlow CLI",
            project: ".iflow/skills",
            global: ".iflow/skills",
            marker: ".iflow",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "junie",
            display: "Junie",
            project: ".junie/skills",
            global: ".junie/skills",
            marker: ".junie",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "kilo",
            display: "Kilo Code",
            project: ".kilocode/skills",
            global: ".kilocode/skills",
            marker: ".kilocode",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "kimi-cli",
            display: "Kimi Code CLI",
            project: ".agents/skills",
            global: ".config/agents/skills",
            marker: ".kimi",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "kiro-cli",
            display: "Kiro CLI",
            project: ".kiro/skills",
            global: ".kiro/skills",
            marker: ".kiro",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "kode",
            display: "Kode",
            project: ".kode/skills",
            global: ".kode/skills",
            marker: ".kode",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "mcpjam",
            display: "MCPJam",
            project: ".mcpjam/skills",
            global: ".mcpjam/skills",
            marker: ".mcpjam",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "mistral-vibe",
            display: "Mistral Vibe",
            project: ".vibe/skills",
            global: "skills",
            marker: "",
            env: Some(("VIBE_HOME", ".vibe")),
            extra: &[],
            base: GlobalBase::Env,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "mux",
            display: "Mux",
            project: ".mux/skills",
            global: ".mux/skills",
            marker: ".mux",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "neovate",
            display: "Neovate",
            project: ".neovate/skills",
            global: ".neovate/skills",
            marker: ".neovate",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "openclaw",
            display: "OpenClaw",
            project: "skills",
            global: ".openclaw/skills",
            marker: ".openclaw",
            env: None,
            extra: &[".clawdbot", ".moltbot"],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "opencode",
            display: "OpenCode",
            project: ".agents/skills",
            global: "opencode/skills",
            marker: "opencode",
            env: None,
            extra: &[],
            base: GlobalBase::Xdg,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "openhands",
            display: "OpenHands",
            project: ".openhands/skills",
            global: ".openhands/skills",
            marker: ".openhands",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "pi",
            display: "Pi",
            project: ".pi/skills",
            global: ".pi/agent/skills",
            marker: ".pi/agent",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "pochi",
            display: "Pochi",
            project: ".pochi/skills",
            global: ".pochi/skills",
            marker: ".pochi",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "qoder",
            display: "Qoder",
            project: ".qoder/skills",
            global: ".qoder/skills",
            marker: ".qoder",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "qwen-code",
            display: "Qwen Code",
            project: ".qwen/skills",
            global: ".qwen/skills",
            marker: ".qwen",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "replit",
            display: "Replit",
            project: ".agents/skills",
            global: "agents/skills",
            marker: ".replit",
            env: None,
            extra: &[],
            base: GlobalBase::Xdg,
            detect_in_project: true,
            show_universal: false,
        },
        Spec {
            id: "roo",
            display: "Roo Code",
            project: ".roo/skills",
            global: ".roo/skills",
            marker: ".roo",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "rovodev",
            display: "Rovo Dev",
            project: ".rovodev/skills",
            global: ".rovodev/skills",
            marker: ".rovodev",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "tabnine-cli",
            display: "Tabnine CLI",
            project: ".tabnine/agent/skills",
            global: ".tabnine/agent/skills",
            marker: ".tabnine",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "trae",
            display: "Trae",
            project: ".trae/skills",
            global: ".trae/skills",
            marker: ".trae",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "trae-cn",
            display: "Trae CN",
            project: ".trae/skills",
            global: ".trae-cn/skills",
            marker: ".trae-cn",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "universal",
            display: "Universal",
            project: ".agents/skills",
            global: "agents/skills",
            marker: "agents",
            env: None,
            extra: &[],
            base: GlobalBase::Xdg,
            detect_in_project: false,
            show_universal: false,
        },
        Spec {
            id: "warp",
            display: "Warp",
            project: ".agents/skills",
            global: ".agents/skills",
            marker: ".warp",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "windsurf",
            display: "Windsurf",
            project: ".windsurf/skills",
            global: ".codeium/windsurf/skills",
            marker: ".codeium/windsurf",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "zed",
            display: "Zed",
            project: ".agents/skills",
            global: ".agents/skills",
            marker: ".config/zed",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
        Spec {
            id: "zencoder",
            display: "Zencoder",
            project: ".zencoder/skills",
            global: ".zencoder/skills",
            marker: ".zencoder",
            env: None,
            extra: &[],
            base: GlobalBase::Home,
            detect_in_project: false,
            show_universal: true,
        },
    ];

    SPECS
        .iter()
        .map(|spec| AgentDefinition {
            id: AgentId::new(spec.id),
            display_name: spec.display.to_owned(),
            project_skills_dir: PathBuf::from(spec.project),
            global_skills_dir: PathBuf::from(spec.global),
            detection_marker: PathBuf::from(spec.marker),
            env_home: spec.env.map(|(name, _)| name.to_owned()),
            env_fallback: spec.env.map(|(_, fallback)| PathBuf::from(fallback)),
            extra_markers: spec.extra.iter().map(PathBuf::from).collect(),
            global_base: spec.base,
            detect_in_project: spec.detect_in_project,
            show_in_universal_list: spec.show_universal,
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use std::fs;

    use tempfile::tempdir;

    use super::*;

    const UPSTREAM_1_5_9_AGENTS: &[&str] = &[
        "adal",
        "aider-desk",
        "amp",
        "antigravity",
        "augment",
        "bob",
        "claude-code",
        "cline",
        "codearts-agent",
        "codebuddy",
        "codemaker",
        "codestudio",
        "codex",
        "command-code",
        "continue",
        "cortex",
        "crush",
        "cursor",
        "deepagents",
        "devin",
        "dexto",
        "droid",
        "firebender",
        "forgecode",
        "gemini-cli",
        "github-copilot",
        "goose",
        "hermes-agent",
        "iflow-cli",
        "junie",
        "kilo",
        "kimi-cli",
        "kiro-cli",
        "kode",
        "mcpjam",
        "mistral-vibe",
        "mux",
        "neovate",
        "openclaw",
        "opencode",
        "openhands",
        "pi",
        "pochi",
        "qoder",
        "qwen-code",
        "replit",
        "roo",
        "rovodev",
        "tabnine-cli",
        "trae",
        "trae-cn",
        "universal",
        "warp",
        "windsurf",
        "zed",
        "zencoder",
    ];

    #[test]
    fn registry_contains_every_pinned_1_5_9_agent() {
        let registry = AgentRegistry::from_home("/tmp");
        let ids: Vec<&str> = registry
            .all()
            .iter()
            .map(|agent| agent.id.0.as_str())
            .collect();
        assert_eq!(ids.len(), UPSTREAM_1_5_9_AGENTS.len());
        for id in UPSTREAM_1_5_9_AGENTS {
            assert!(registry.by_id(id).is_some(), "missing agent {id}");
        }
        for id in &ids {
            assert!(
                UPSTREAM_1_5_9_AGENTS.contains(id),
                "unexpected agent {id} not in vercel-labs/skills@1.5.9"
            );
        }
    }

    #[test]
    fn registry_resolves_upstream_project_and_global_paths() {
        let home = tempdir().expect("home");
        fs::create_dir_all(home.path().join(".codex")).expect("codex marker");
        let registry = AgentRegistry::from_home(home.path());
        let codex = registry.by_id("codex").expect("codex");
        assert_eq!(
            codex.project_skills_path(Path::new("/project")),
            PathBuf::from("/project/.agents/skills")
        );
        assert_eq!(
            codex.global_skills_path_with(home.path(), |_| None),
            home.path().join(".codex/skills")
        );
        assert!(codex.is_detected_with(home.path(), |_| None));
    }

    #[test]
    fn skills_only_directories_do_not_prove_installation() {
        let home = tempdir().expect("home");
        let registry = AgentRegistry::from_home(home.path());
        let adal = registry.by_id("adal").expect("adal");

        // Residue of the skills CLI spraying symlinks: ~/.adal holds nothing
        // but a skills directory.
        fs::create_dir_all(home.path().join(".adal/skills/store-entry")).expect("spray");
        assert!(!adal.is_detected_with(home.path(), |_| None));
        assert!(
            registry
                .leftover_global_skill_roots()
                .iter()
                .any(|(agent, _)| agent.id.0 == "adal"),
            "the leftover root must stay scannable"
        );

        // Any additional real content proves the client exists.
        fs::write(home.path().join(".adal/config.json"), "{}").expect("config");
        assert!(adal.is_detected_with(home.path(), |_| None));
        assert!(
            !registry
                .leftover_global_skill_roots()
                .iter()
                .any(|(agent, _)| agent.id.0 == "adal")
        );

        // macOS metadata noise never counts as content.
        let other = tempdir().expect("other");
        let bob = registry.by_id("bob").expect("bob");
        fs::create_dir_all(other.path().join(".bob/skills")).expect("spray");
        fs::write(other.path().join(".bob/.DS_Store"), b"").expect("metadata");
        assert!(!bob.is_detected_with(other.path(), |_| None));
    }

    #[test]
    fn claude_and_vibe_honour_their_env_homes() {
        let home = tempdir().expect("home");
        let registry = AgentRegistry::from_home(home.path());
        let claude = registry.by_id("claude-code").expect("claude-code");
        let vibe = registry.by_id("mistral-vibe").expect("mistral-vibe");
        let resolver = |name: &str| match name {
            "CLAUDE_CONFIG_DIR" => Some(std::ffi::OsString::from("/custom/claude")),
            "VIBE_HOME" => Some(std::ffi::OsString::from("/custom/vibe")),
            _ => None,
        };
        assert_eq!(
            claude.global_skills_path_with(home.path(), resolver),
            PathBuf::from("/custom/claude/skills")
        );
        assert_eq!(
            vibe.global_skills_path_with(home.path(), resolver),
            PathBuf::from("/custom/vibe/skills")
        );
    }

    #[test]
    fn agent_specific_home_environment_overrides_global_path() {
        let home = tempdir().expect("home");
        let registry = AgentRegistry::from_home(home.path());
        let codex = registry.by_id("codex").expect("codex");
        let resolver = |name: &str| {
            if name == "CODEX_HOME" {
                Some(std::ffi::OsString::from("/custom/codex"))
            } else {
                None
            }
        };
        assert_eq!(
            codex.config_home_with(home.path(), resolver),
            PathBuf::from("/custom/codex")
        );

        let amp = registry.by_id("amp").expect("amp");
        let xdg = |name: &str| {
            if name == "XDG_CONFIG_HOME" {
                Some(std::ffi::OsString::from("/xdg"))
            } else {
                None
            }
        };
        assert_eq!(
            amp.config_home_with(home.path(), xdg),
            PathBuf::from("/xdg")
        );
        assert_eq!(
            amp.global_skills_path_with(home.path(), xdg),
            PathBuf::from("/xdg/agents/skills")
        );
    }

    #[test]
    fn kimi_detects_home_dot_kimi_and_devin_uses_xdg() {
        let home = tempdir().expect("home");
        fs::create_dir_all(home.path().join(".kimi")).expect("kimi");
        let registry = AgentRegistry::from_home(home.path());
        let kimi = registry.by_id("kimi-cli").expect("kimi");
        assert!(kimi.is_detected_with(home.path(), |_| None));

        let devin = registry.by_id("devin").expect("devin");
        let xdg_root = home.path().join("xdg");
        fs::create_dir_all(xdg_root.join("devin")).expect("devin xdg");
        let xdg = |name: &str| {
            if name == "XDG_CONFIG_HOME" {
                Some(xdg_root.clone().into_os_string())
            } else {
                None
            }
        };
        assert!(devin.is_detected_with(home.path(), xdg));
        assert_eq!(
            devin.global_skills_path_with(home.path(), xdg),
            xdg_root.join("devin/skills")
        );
    }

    #[test]
    fn env_home_agents_are_not_detected_from_bare_home() {
        let home = tempdir().expect("home");
        let registry = AgentRegistry::from_home(home.path());
        let cwd = tempdir().expect("cwd");
        for id in ["claude-code", "codex", "mistral-vibe"] {
            let agent = registry.by_id(id).expect(id);
            assert!(
                !agent.is_detected_at(home.path(), cwd.path(), |_| None),
                "{id} must not treat $HOME as installed"
            );
        }
    }

    #[test]
    fn openclaw_prefers_legacy_home_aliases() {
        let home = tempdir().expect("home");
        let registry = AgentRegistry::from_home(home.path());
        let openclaw = registry.by_id("openclaw").expect("openclaw");
        assert_eq!(
            openclaw.project_skills_path(Path::new("/project")),
            PathBuf::from("/project/skills")
        );
        assert_eq!(
            openclaw.global_skills_path(home.path()),
            home.path().join(".openclaw/skills")
        );

        fs::create_dir_all(home.path().join(".moltbot")).expect("moltbot");
        assert_eq!(
            openclaw.global_skills_path(home.path()),
            home.path().join(".moltbot/skills")
        );
        assert!(openclaw.is_detected_with(home.path(), |_| None));

        fs::create_dir_all(home.path().join(".clawdbot")).expect("clawdbot");
        assert_eq!(
            openclaw.global_skills_path(home.path()),
            home.path().join(".clawdbot/skills")
        );

        fs::create_dir_all(home.path().join(".openclaw")).expect("openclaw");
        assert_eq!(
            openclaw.global_skills_path(home.path()),
            home.path().join(".openclaw/skills")
        );
    }

    #[test]
    fn zed_detects_xdg_appdata_and_flatpak_config() {
        let home = tempdir().expect("home");
        let registry = AgentRegistry::from_home(home.path());
        let zed = registry.by_id("zed").expect("zed");
        let cwd = tempdir().expect("cwd");
        assert!(!zed.is_detected_at(home.path(), cwd.path(), |_| None));
        assert_eq!(
            zed.global_skills_path_with(home.path(), |_| None),
            home.path().join(".agents/skills")
        );

        let xdg = home.path().join("xdg-config");
        fs::create_dir_all(xdg.join("zed")).expect("xdg zed");
        let xdg_env = |name: &str| {
            if name == "XDG_CONFIG_HOME" {
                Some(xdg.clone().into_os_string())
            } else {
                None
            }
        };
        assert!(zed.is_detected_at(home.path(), cwd.path(), xdg_env));

        let appdata = home.path().join("AppData/Roaming");
        fs::create_dir_all(appdata.join("Zed")).expect("appdata zed");
        let appdata_env = |name: &str| {
            if name == "APPDATA" {
                Some(appdata.clone().into_os_string())
            } else {
                None
            }
        };
        assert!(zed.is_detected_at(home.path(), cwd.path(), appdata_env));

        let flatpak = home.path().join("flatpak-config");
        fs::create_dir_all(flatpak.join("zed")).expect("flatpak zed");
        let flatpak_env = |name: &str| {
            if name == "FLATPAK_XDG_CONFIG_HOME" {
                Some(flatpak.clone().into_os_string())
            } else {
                None
            }
        };
        assert!(zed.is_detected_at(home.path(), cwd.path(), flatpak_env));
    }

    #[test]
    fn replit_detects_only_cwd_dot_replit() {
        let home = tempdir().expect("home");
        fs::create_dir_all(home.path().join(".replit")).expect("home replit");
        fs::create_dir_all(home.path().join(".agents/skills")).expect("agents");
        let registry = AgentRegistry::from_home(home.path());
        let replit = registry.by_id("replit").expect("replit");
        let empty_cwd = tempdir().expect("empty cwd");
        assert!(
            !replit.is_detected_at(home.path(), empty_cwd.path(), |_| None),
            "home .replit must not detect Replit"
        );

        let project = tempdir().expect("project");
        fs::create_dir_all(project.path().join(".agents/skills")).expect("project skills");
        assert!(
            !replit.is_detected_at(home.path(), project.path(), |_| None),
            "project .agents/skills must not detect Replit"
        );
        fs::write(project.path().join(".replit"), "run = \"echo\"").expect("replit marker");
        assert!(replit.is_detected_at(home.path(), project.path(), |_| None));
        assert!(!replit.show_in_universal_list);
        assert_eq!(
            replit.project_skills_path(project.path()),
            project.path().join(".agents/skills")
        );
    }

    #[test]
    fn pi_windsurf_and_kimi_use_upstream_homes() {
        let home = tempdir().expect("home");
        fs::create_dir_all(home.path().join(".pi/agent")).expect("pi");
        fs::create_dir_all(home.path().join(".codeium/windsurf")).expect("windsurf");
        fs::create_dir_all(home.path().join(".kimi")).expect("kimi");
        let registry = AgentRegistry::from_home(home.path());

        let pi = registry.by_id("pi").expect("pi");
        assert!(pi.is_detected_with(home.path(), |_| None));
        assert_eq!(
            pi.project_skills_path(Path::new("/project")),
            PathBuf::from("/project/.pi/skills")
        );
        assert_eq!(
            pi.global_skills_path(home.path()),
            home.path().join(".pi/agent/skills")
        );

        let windsurf = registry.by_id("windsurf").expect("windsurf");
        assert!(windsurf.is_detected_with(home.path(), |_| None));
        assert_eq!(
            windsurf.project_skills_path(Path::new("/project")),
            PathBuf::from("/project/.windsurf/skills")
        );
        assert_eq!(
            windsurf.global_skills_path(home.path()),
            home.path().join(".codeium/windsurf/skills")
        );

        let kimi = registry.by_id("kimi-cli").expect("kimi");
        assert_eq!(
            kimi.global_skills_path(home.path()),
            home.path().join(".config/agents/skills")
        );
    }

    #[test]
    fn xdg_and_named_homes_match_upstream() {
        let home = tempdir().expect("home");
        let registry = AgentRegistry::from_home(home.path());
        let xdg = |name: &str| {
            if name == "XDG_CONFIG_HOME" {
                Some(std::ffi::OsString::from("/xdg"))
            } else {
                None
            }
        };
        for (id, relative) in [
            ("amp", "agents/skills"),
            ("goose", "goose/skills"),
            ("opencode", "opencode/skills"),
            ("devin", "devin/skills"),
            ("universal", "agents/skills"),
        ] {
            let agent = registry.by_id(id).expect(id);
            assert_eq!(
                agent.global_skills_path_with(home.path(), xdg),
                PathBuf::from("/xdg").join(relative),
                "{id}"
            );
        }

        let named = |name: &str| match name {
            "CODEX_HOME" => Some(std::ffi::OsString::from("/custom/codex")),
            "CLAUDE_CONFIG_DIR" => Some(std::ffi::OsString::from("/custom/claude")),
            "VIBE_HOME" => Some(std::ffi::OsString::from("/custom/vibe")),
            _ => None,
        };
        assert_eq!(
            registry
                .by_id("codex")
                .expect("codex")
                .global_skills_path_with(home.path(), named),
            PathBuf::from("/custom/codex/skills")
        );
        assert_eq!(
            registry
                .by_id("claude-code")
                .expect("claude")
                .global_skills_path_with(home.path(), named),
            PathBuf::from("/custom/claude/skills")
        );
        assert_eq!(
            registry
                .by_id("mistral-vibe")
                .expect("vibe")
                .global_skills_path_with(home.path(), named),
            PathBuf::from("/custom/vibe/skills")
        );
    }
}
