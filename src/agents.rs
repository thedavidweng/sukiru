use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Hash, Serialize, Deserialize)]
pub struct AgentId(pub String);

impl AgentId {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct AgentDefinition {
    pub id: AgentId,
    pub display_name: String,
    pub project_skills_dir: PathBuf,
    pub global_skills_dir: PathBuf,
    pub detection_marker: PathBuf,
}

impl AgentDefinition {
    pub fn project_skills_path(&self, project_root: &Path) -> PathBuf {
        project_root.join(&self.project_skills_dir)
    }

    pub fn is_detected(&self, home: &Path) -> bool {
        home.join(&self.detection_marker).exists()
    }
}

#[derive(Clone, Debug)]
pub struct AgentRegistry {
    home: PathBuf,
    definitions: Vec<AgentDefinition>,
}

impl AgentRegistry {
    pub fn from_home(home: impl Into<PathBuf>) -> Self {
        let home = home.into();
        let definitions = definitions();
        Self { home, definitions }
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
            .map(|agent| (agent, self.home.join(&agent.global_skills_dir)))
            .collect()
    }

    pub fn project_skill_roots(&self, project_root: &Path) -> Vec<(&AgentDefinition, PathBuf)> {
        self.definitions
            .iter()
            .filter(|agent| {
                let marker = project_root.join(&agent.project_skills_dir);
                marker.exists() || project_root.join(&agent.detection_marker).exists()
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

fn definitions() -> Vec<AgentDefinition> {
    [
        (
            "aider-desk",
            "AiderDesk",
            ".aider-desk/skills",
            ".aider-desk",
            ".aider-desk",
        ),
        (
            "amp",
            "Amp",
            ".agents/skills",
            ".config/agents/skills",
            ".config/amp",
        ),
        (
            "antigravity",
            "Antigravity",
            ".agents/skills",
            ".gemini/antigravity/skills",
            ".gemini/antigravity",
        ),
        (
            "augment",
            "Augment",
            ".augment/skills",
            ".augment/skills",
            ".augment",
        ),
        ("bob", "IBM Bob", ".bob/skills", ".bob/skills", ".bob"),
        (
            "claude-code",
            "Claude Code",
            ".claude/skills",
            ".claude/skills",
            ".claude",
        ),
        (
            "cline",
            "Cline",
            ".agents/skills",
            ".agents/skills",
            ".cline",
        ),
        (
            "codebuddy",
            "CodeBuddy",
            ".codebuddy/skills",
            ".codebuddy/skills",
            ".codebuddy",
        ),
        (
            "codex",
            "Codex",
            ".agents/skills",
            ".codex/skills",
            ".codex",
        ),
        (
            "command-code",
            "Command Code",
            ".commandcode/skills",
            ".commandcode/skills",
            ".commandcode",
        ),
        (
            "continue",
            "Continue",
            ".continue/skills",
            ".continue/skills",
            ".continue",
        ),
        (
            "cursor",
            "Cursor",
            ".agents/skills",
            ".cursor/skills",
            ".cursor",
        ),
        ("devin", "Devin", ".devin/skills", ".devin/skills", ".devin"),
        (
            "gemini-cli",
            "Gemini CLI",
            ".agents/skills",
            ".gemini/skills",
            ".gemini",
        ),
        (
            "github-copilot",
            "GitHub Copilot",
            ".agents/skills",
            ".copilot/skills",
            ".copilot",
        ),
        (
            "goose",
            "Goose",
            ".goose/skills",
            ".config/goose/skills",
            ".config/goose",
        ),
        (
            "kimi-cli",
            "Kimi Code CLI",
            ".agents/skills",
            ".config/agents/skills",
            ".config/kimi",
        ),
        (
            "neovate",
            "Neovate",
            ".neovate/skills",
            ".neovate/skills",
            ".neovate",
        ),
        (
            "openclaw",
            "OpenClaw",
            "skills",
            ".openclaw/skills",
            ".openclaw",
        ),
        (
            "opencode",
            "OpenCode",
            ".agents/skills",
            ".config/opencode/skills",
            ".config/opencode",
        ),
        (
            "openhands",
            "OpenHands",
            ".openhands/skills",
            ".openhands/skills",
            ".openhands",
        ),
        ("pi", "Pi", ".pi/skills", ".pi/agent/skills", ".pi"),
        ("pochi", "Pochi", ".pochi/skills", ".pochi/skills", ".pochi"),
        ("qoder", "Qoder", ".qoder/skills", ".qoder/skills", ".qoder"),
        (
            "qwen-code",
            "Qwen Code",
            ".qwen/skills",
            ".qwen/skills",
            ".qwen",
        ),
        (
            "replit",
            "Replit",
            ".agents/skills",
            ".config/agents/skills",
            ".config/replit",
        ),
        ("roo", "Roo Code", ".roo/skills", ".roo/skills", ".roo"),
        ("trae", "Trae", ".trae/skills", ".trae/skills", ".trae"),
        (
            "universal",
            "Universal",
            ".agents/skills",
            ".config/agents/skills",
            ".config/agents",
        ),
        (
            "windsurf",
            "Windsurf",
            ".windsurf/skills",
            ".codeium/windsurf/skills",
            ".codeium",
        ),
        (
            "zencoder",
            "Zencoder",
            ".zencoder/skills",
            ".zencoder/skills",
            ".zencoder",
        ),
    ]
    .into_iter()
    .map(
        |(id, display_name, project, global, marker)| AgentDefinition {
            id: AgentId::new(id),
            display_name: display_name.to_owned(),
            project_skills_dir: PathBuf::from(project),
            global_skills_dir: PathBuf::from(global),
            detection_marker: PathBuf::from(marker),
        },
    )
    .collect()
}

#[cfg(test)]
mod tests {
    use std::fs;

    use tempfile::tempdir;

    use super::*;

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
            home.path().join(&codex.global_skills_dir),
            home.path().join(".codex/skills")
        );
        assert!(
            registry
                .detected()
                .iter()
                .any(|agent| agent.id.0 == "codex")
        );
    }
}
