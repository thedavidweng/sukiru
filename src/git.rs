use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use serde::Serialize;

use crate::error::{GinoError, Result, io_error};
use crate::inventory::Inventory;
use crate::protocol::{sanitize_skill_name, write_atomic};

#[derive(Clone, Debug)]
pub struct GitRepository {
    root: PathBuf,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PushMode {
    CommitLocally,
    CommitAndPush,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PushStatus {
    NotConfigured,
    NotRequested,
    Pushed,
    NotPushed(String),
}

#[derive(Clone, Debug, Serialize)]
struct BackupManifest {
    version: u64,
    skills: BTreeMap<String, BackupSkill>,
}

#[derive(Clone, Debug, Serialize)]
struct BackupSkill {
    source: Option<String>,
    source_type: Option<String>,
    source_ref: Option<String>,
    content_hash: Option<String>,
    placements: Vec<BackupPlacement>,
}

#[derive(Clone, Debug, Serialize)]
struct BackupPlacement {
    workspace_id: String,
    workspace_kind: String,
    agent_id: Option<String>,
}

impl GitRepository {
    pub fn open_or_init(root: impl Into<PathBuf>) -> Result<Self> {
        let root = root.into();
        fs::create_dir_all(&root).map_err(|source| io_error(&root, source))?;
        let repository = Self { root };
        if !repository.root.join(".git").exists() {
            repository.run(&["init", "--quiet"])?;
        }
        Ok(repository)
    }

    pub fn open(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn commit_count(&self) -> Result<usize> {
        let count = self.run(&["rev-list", "--count", "HEAD"])?;
        String::from_utf8_lossy(&count)
            .trim()
            .parse::<usize>()
            .map_err(|source| GinoError::Git {
                directory: self.root.clone(),
                command: "git rev-list --count HEAD".to_owned(),
                cause: source.to_string(),
            })
    }

    pub fn materialize_inventory(&self, inventory: &Inventory) -> Result<()> {
        let skills_root = self.root.join("skills");
        if skills_root.exists() {
            fs::remove_dir_all(&skills_root).map_err(|source| io_error(&skills_root, source))?;
        }
        fs::create_dir_all(&skills_root).map_err(|source| io_error(&skills_root, source))?;

        let mut manifest = BTreeMap::new();
        for placement in &inventory.placements {
            let entry = manifest
                .entry(placement.name.clone())
                .or_insert_with(|| BackupSkill {
                    source: placement
                        .lock_entry
                        .as_ref()
                        .map(|lock| lock.source.clone()),
                    source_type: placement
                        .lock_entry
                        .as_ref()
                        .map(|lock| lock.source_type.clone()),
                    source_ref: placement
                        .lock_entry
                        .as_ref()
                        .and_then(|lock| lock.ref_name.clone()),
                    content_hash: placement.content_hash.clone(),
                    placements: Vec::new(),
                });
            entry.placements.push(BackupPlacement {
                workspace_id: placement.workspace_id.clone(),
                workspace_kind: format!("{:?}", placement.workspace_kind),
                agent_id: placement.agent_id.as_ref().map(|agent| agent.0.clone()),
            });
            let destination_name = sanitize_skill_name(&placement.name)?;
            let destination = skills_root.join(destination_name);
            if !destination.exists() {
                copy_tree_dereferenced(&placement.path, &destination)?;
            }
        }
        let manifest_path = self.root.join("manifest.json");
        let bytes = serde_json::to_vec_pretty(&BackupManifest {
            version: 1,
            skills: manifest,
        })
        .map_err(|source| crate::error::json_error(&manifest_path, source))?;
        write_atomic(&manifest_path, &bytes)
    }

    pub fn commit(&self, message: &str, push_mode: PushMode) -> Result<(String, PushStatus)> {
        self.run(&["add", "--all"])?;
        self.run_with_env(&[
            "-c",
            "user.name=Gino",
            "-c",
            "user.email=gino@localhost",
            "commit",
            "--quiet",
            "--allow-empty",
            "--no-gpg-sign",
            "-m",
            message,
        ])?;
        let commit = self.run(&["rev-parse", "HEAD"])?;
        let commit = String::from_utf8_lossy(&commit).trim().to_owned();
        let push_status = match push_mode {
            PushMode::CommitLocally => PushStatus::NotRequested,
            PushMode::CommitAndPush => match self.run(&["push"]) {
                Ok(_) => PushStatus::Pushed,
                Err(error) => PushStatus::NotPushed(error.to_string()),
            },
        };
        Ok((commit, push_status))
    }

    pub fn discard_uncommitted(&self) -> Result<()> {
        if self.run(&["rev-parse", "--verify", "HEAD"]).is_ok() {
            self.run(&["reset", "--hard", "--quiet", "HEAD"])?;
        }
        self.run(&["clean", "-fd", "--quiet"])?;
        Ok(())
    }

    fn run(&self, args: &[&str]) -> Result<Vec<u8>> {
        self.run_with_env(args)
    }

    fn run_with_env(&self, args: &[&str]) -> Result<Vec<u8>> {
        let output = Command::new("git")
            .args(args)
            .current_dir(&self.root)
            .output()
            .map_err(|source| GinoError::Git {
                directory: self.root.clone(),
                command: format!("git {}", args.join(" ")),
                cause: source.to_string(),
            })?;
        if !output.status.success() {
            return Err(GinoError::Git {
                directory: self.root.clone(),
                command: format!("git {}", args.join(" ")),
                cause: String::from_utf8_lossy(&output.stderr).trim().to_owned(),
            });
        }
        Ok(output.stdout)
    }
}

fn copy_tree_dereferenced(source: &Path, destination: &Path) -> Result<()> {
    let metadata = fs::metadata(source).map_err(|source_error| io_error(source, source_error))?;
    if metadata.is_dir() {
        fs::create_dir_all(destination)
            .map_err(|source_error| io_error(destination, source_error))?;
        let entries =
            fs::read_dir(source).map_err(|source_error| io_error(source, source_error))?;
        for entry in entries {
            let entry = entry.map_err(|source_error| io_error(source, source_error))?;
            copy_tree_dereferenced(&entry.path(), &destination.join(entry.file_name()))?;
        }
    } else {
        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent).map_err(|source_error| io_error(parent, source_error))?;
        }
        fs::copy(source, destination)
            .map_err(|source_error| io_error(destination, source_error))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::fs;

    use tempfile::tempdir;

    use super::*;
    use crate::inventory::{InventoryScanner, Workspace, WorkspaceKind};

    #[test]
    fn successful_commit_creates_one_local_revision() {
        let source = tempdir().expect("source");
        fs::create_dir_all(source.path().join("demo")).expect("skill");
        fs::write(
            source.path().join("demo/SKILL.md"),
            "---\nname: demo\ndescription: demo\n---\nbody\n",
        )
        .expect("skill file");
        let workspace = Workspace::new("custom", "Custom", WorkspaceKind::Custom, source.path());
        let inventory = InventoryScanner::new(&[workspace]).scan(1).expect("scan");
        let backup = tempdir().expect("backup");
        let repository = GitRepository::open_or_init(backup.path()).expect("git init");
        repository
            .materialize_inventory(&inventory)
            .expect("materialize");
        let (commit, status) = repository
            .commit("Apply 1 change", PushMode::CommitLocally)
            .expect("commit");

        assert_eq!(commit.len(), 40);
        assert_eq!(status, PushStatus::NotRequested);
        assert_eq!(repository.commit_count().expect("count"), 1);
    }
}
