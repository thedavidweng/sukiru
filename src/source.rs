use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::discovery::{DiscoveryResult, discover_skills, discover_source_root};
use crate::error::{GinoError, Result, io_error};
use crate::protocol::{SkillSource, SourceType, parse_skill_metadata, sha256_bytes};

#[derive(Clone, Debug)]
pub struct SourceCache {
    root: PathBuf,
}

#[derive(Clone, Debug)]
pub struct ResolvedSource {
    pub source: SkillSource,
    pub root: PathBuf,
}

impl SourceCache {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn resolve(&self, source: &SkillSource) -> Result<ResolvedSource> {
        if source.source_type == SourceType::Local {
            let root = PathBuf::from(&source.input);
            if !root.exists() {
                return Err(io_error(
                    &root,
                    std::io::Error::new(
                        std::io::ErrorKind::NotFound,
                        "local source does not exist",
                    ),
                ));
            }
            return Ok(ResolvedSource {
                source: source.clone(),
                root,
            });
        }

        fs::create_dir_all(&self.root).map_err(|error| io_error(&self.root, error))?;
        let key = sha256_bytes(
            format!(
                "{}|{}",
                source.normalized,
                source.ref_name.as_deref().unwrap_or("")
            )
            .as_bytes(),
        );
        let root = self.root.join(&key);
        if !root.exists() {
            let clone_url = clone_url(source)?;
            let mut command = Command::new("git");
            command.arg("clone").arg("--quiet").arg("--depth").arg("1");
            if let Some(reference) = &source.ref_name {
                command.arg("--branch").arg(reference);
            }
            command.arg(&clone_url).arg(&root);
            let output = command.output().map_err(|error| GinoError::Git {
                directory: self.root.clone(),
                command: "git clone <source> <cache>".to_owned(),
                cause: error.to_string(),
            })?;
            if !output.status.success() {
                let _ = fs::remove_dir_all(&root);
                return Err(GinoError::Git {
                    directory: self.root.clone(),
                    command: "git clone <source> <cache>".to_owned(),
                    cause: String::from_utf8_lossy(&output.stderr).trim().to_owned(),
                });
            }
        }
        Ok(ResolvedSource {
            source: source.clone(),
            root,
        })
    }

    pub fn discover(&self, source: &SkillSource, full_depth: bool) -> Result<DiscoveryResult> {
        let resolved = self.resolve(source)?;
        let root = source
            .skill_path
            .as_deref()
            .map(|path| resolved.root.join(path))
            .unwrap_or_else(|| resolved.root.clone());
        if root.join("SKILL.md").exists() {
            let metadata = parse_skill_metadata(&root)?;
            return Ok(DiscoveryResult {
                skills: vec![crate::discovery::DiscoveredSkill {
                    metadata,
                    path: root,
                }],
                issues: Vec::new(),
            });
        }
        let discovered = discover_skills(&root, full_depth)?;
        if discovered.skills.is_empty() && discovered.issues.is_empty() {
            discover_source_root(root, full_depth)
        } else {
            Ok(discovered)
        }
    }
}

fn clone_url(source: &SkillSource) -> Result<String> {
    match source.source_type {
        SourceType::Github => Ok(format!("https://github.com/{}.git", source.normalized)),
        SourceType::Gitlab => Ok(format!("https://gitlab.com/{}.git", source.normalized)),
        SourceType::Git | SourceType::Direct => Ok(source.source_url.clone()),
        SourceType::Local => Err(GinoError::InvalidSource {
            input: source.input.clone(),
            reason: "local sources do not use a Git clone".to_owned(),
        }),
    }
}

#[cfg(test)]
mod tests {
    use std::fs;

    use tempfile::tempdir;

    use super::*;

    #[test]
    fn resolves_local_source_and_discovers_one_skill() {
        let source_root = tempdir().expect("source");
        fs::create_dir_all(source_root.path().join("demo")).expect("skill");
        fs::write(
            source_root.path().join("demo/SKILL.md"),
            "---\nname: demo\ndescription: demo\n---\n",
        )
        .expect("skill file");
        let cache = SourceCache::new(tempdir().expect("cache").path());
        let source = SkillSource::parse(&source_root.path().to_string_lossy()).expect("source");

        let discovered = cache.discover(&source, false).expect("discover");

        assert_eq!(discovered.skills.len(), 1);
        assert_eq!(discovered.skills[0].metadata.name, "demo");
    }
}
