use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::error::{Result, io_error};
use crate::protocol::{SkillMetadata, parse_skill_metadata};

const CONTAINERS: &[&str] = &[
    "skills",
    "skills/.curated",
    "skills/.experimental",
    "skills/.system",
    ".aider-desk/skills",
    ".agents/skills",
    "data/skills",
    ".autohand/skills",
    ".augment/skills",
    ".bob/skills",
    ".claude/skills",
    ".codebuddy/skills",
    ".codemaker/skills",
    ".continue/skills",
    ".crush/skills",
    ".devin/skills",
    ".factory/skills",
    ".goose/skills",
    ".openhands/skills",
    ".opencode/skills",
    ".pi/skills",
    ".qoder/skills",
    ".qwen/skills",
    ".roo/skills",
    ".trae/skills",
    ".windsurf/skills",
    ".zencoder/skills",
];

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DiscoveredSkill {
    pub metadata: SkillMetadata,
    pub path: PathBuf,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DiscoveryIssue {
    pub path: PathBuf,
    pub reason: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DiscoveryResult {
    pub skills: Vec<DiscoveredSkill>,
    pub issues: Vec<DiscoveryIssue>,
}

pub fn discover_skills(base: impl AsRef<Path>, full_depth: bool) -> Result<DiscoveryResult> {
    let base = base.as_ref();
    let mut result = DiscoveryResult {
        skills: Vec::new(),
        issues: Vec::new(),
    };
    let mut names = BTreeSet::new();
    if base.join("SKILL.md").exists() {
        record_skill(base, &mut names, &mut result);
    }
    let containers = CONTAINERS.iter().map(|relative| base.join(relative));
    for container in containers {
        discover_container(&container, full_depth, &mut names, &mut result)?;
    }
    result
        .skills
        .sort_by(|left, right| left.metadata.name.cmp(&right.metadata.name));
    Ok(result)
}

fn discover_container(
    container: &Path,
    full_depth: bool,
    names: &mut BTreeSet<String>,
    result: &mut DiscoveryResult,
) -> Result<()> {
    if !container.exists() {
        return Ok(());
    }
    let metadata = fs::symlink_metadata(container).map_err(|source| io_error(container, source))?;
    if !metadata.is_dir() {
        return Ok(());
    }
    if container.join("SKILL.md").exists() {
        record_skill(container, names, result);
    }
    let entries = fs::read_dir(container).map_err(|source| io_error(container, source))?;
    let mut children = entries
        .map(|entry| {
            entry
                .map(|entry| entry.path())
                .map_err(|source| io_error(container, source))
        })
        .collect::<Result<Vec<_>>>()?;
    children.sort();
    for path in children
        .iter()
        .filter(|path| path.is_dir() && path.join("SKILL.md").exists())
    {
        record_skill(path, names, result);
    }
    for path in children {
        if !path.is_dir() {
            continue;
        }
        if path.join("SKILL.md").exists() {
            continue;
        }
        if full_depth {
            discover_all(&path, names, result)?;
        } else if path.file_name().is_some_and(|name| name != ".git") {
            let nested = fs::read_dir(&path).map_err(|source| io_error(&path, source))?;
            for nested in nested {
                let nested = nested.map_err(|source| io_error(&path, source))?.path();
                if nested.is_dir() && nested.join("SKILL.md").exists() {
                    record_skill(&nested, names, result);
                }
            }
        }
    }
    Ok(())
}

fn discover_all(
    path: &Path,
    names: &mut BTreeSet<String>,
    result: &mut DiscoveryResult,
) -> Result<()> {
    if path.join("SKILL.md").exists() {
        record_skill(path, names, result);
        return Ok(());
    }
    if matches!(
        path.file_name().and_then(|name| name.to_str()),
        Some(".git" | "node_modules" | "dist" | "build")
    ) {
        return Ok(());
    }
    for entry in fs::read_dir(path).map_err(|source| io_error(path, source))? {
        discover_all(
            &entry.map_err(|source| io_error(path, source))?.path(),
            names,
            result,
        )?;
    }
    Ok(())
}

fn record_skill(path: &Path, names: &mut BTreeSet<String>, result: &mut DiscoveryResult) {
    match parse_skill_metadata(path) {
        Ok(metadata) if !metadata.internal => {
            if names.insert(metadata.name.clone()) {
                result.skills.push(DiscoveredSkill {
                    path: path.to_path_buf(),
                    metadata,
                });
            }
        }
        Ok(_) => {}
        Err(error) => result.issues.push(DiscoveryIssue {
            path: path.to_path_buf(),
            reason: error.to_string(),
        }),
    }
}

#[cfg(test)]
mod tests {
    use std::fs;

    use tempfile::tempdir;

    use super::*;

    #[test]
    fn discovery_matches_flat_and_catalog_layouts_with_shallow_shadowing() {
        let root = tempdir().expect("repo");
        fs::create_dir_all(root.path().join("skills/category/demo")).expect("catalog");
        fs::write(
            root.path().join("skills/category/demo/SKILL.md"),
            "---\nname: demo\ndescription: nested\n---\n",
        )
        .expect("nested skill");
        fs::create_dir_all(root.path().join("skills/demo")).expect("flat");
        fs::write(
            root.path().join("skills/demo/SKILL.md"),
            "---\nname: demo\ndescription: flat\n---\n",
        )
        .expect("flat skill");
        fs::create_dir_all(root.path().join("skills/.system/internal")).expect("internal");
        fs::write(
            root.path().join("skills/.system/internal/SKILL.md"),
            "---\nname: internal\ndescription: hidden\nmetadata:\n  internal: true\n---\n",
        )
        .expect("internal skill");

        let result = discover_skills(root.path(), false).expect("discover");
        assert_eq!(result.skills.len(), 1);
        assert_eq!(result.skills[0].metadata.description, "flat");
    }
}
