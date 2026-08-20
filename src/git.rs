use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::error::{GinoError, Result, io_error};
use crate::inventory::Inventory;
use crate::metadata::BackupMetadata;
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

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct BackupManifest {
    pub version: u64,
    pub metadata: BackupMetadata,
    pub skills: BTreeMap<String, BackupSkill>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct BackupSkill {
    pub source: Option<String>,
    pub source_type: Option<String>,
    pub source_ref: Option<String>,
    pub content_hash: Option<String>,
    pub placements: Vec<BackupPlacement>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct BackupPlacement {
    pub workspace_id: String,
    pub workspace_kind: String,
    pub agent_id: Option<String>,
    pub source: Option<String>,
    pub source_type: Option<String>,
    pub source_ref: Option<String>,
    pub content_hash: Option<String>,
    pub repository_path: String,
    pub relative_path: String,
}

/// One Skill placement as seen through the remote backup manifest (US-017).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RemoteSkillChange {
    pub skill_name: String,
    pub workspace_id: String,
    pub relative_path: String,
    pub status: RemoteChangeStatus,
    pub remote_content_hash: Option<String>,
    pub local_content_hash: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RemoteChangeStatus {
    /// Present on the remote, not installed locally.
    Available,
    /// Same placement installed locally with different content.
    Conflict,
    /// Identical on both sides.
    Unchanged,
    /// Installed locally but absent from the remote manifest.
    Removed,
}

/// Read-only remote comparison (US-017): remote differences are proposed,
/// never applied, until the user selects a resolution and applies the batch.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SyncProposal {
    pub remote_commit: String,
    pub changes: Vec<RemoteSkillChange>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CommitInfo {
    pub id: String,
    pub created_at: String,
    pub subject: String,
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

    pub fn ensure_materialization_clean(&self) -> Result<()> {
        let status = self.run(&[
            "status",
            "--porcelain",
            "--ignored",
            "--",
            "skills",
            "manifest.json",
        ])?;
        if status.iter().any(|byte| !byte.is_ascii_whitespace()) {
            return Err(GinoError::Git {
                directory: self.root.clone(),
                command: "git status --porcelain --ignored -- skills manifest.json".to_owned(),
                cause: "backup-generated paths contain uncommitted changes".to_owned(),
            });
        }
        Ok(())
    }

    pub fn materialize_inventory(&self, inventory: &Inventory) -> Result<()> {
        self.materialize_inventory_with_metadata(inventory, &BackupMetadata::default())
    }

    pub fn materialize_inventory_with_metadata(
        &self,
        inventory: &Inventory,
        metadata: &BackupMetadata,
    ) -> Result<()> {
        self.ensure_materialization_clean()?;
        let result = self.materialize_inventory_unchecked(inventory, metadata);
        if let Err(error) = result {
            return match self.discard_materialized_changes() {
                Ok(()) => Err(error),
                Err(cleanup) => Err(GinoError::InvalidPlan(format!(
                    "{error}; backup cleanup failed: {cleanup}"
                ))),
            };
        }
        Ok(())
    }

    fn materialize_inventory_unchecked(
        &self,
        inventory: &Inventory,
        metadata: &BackupMetadata,
    ) -> Result<()> {
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
            let placement_key = placement_repository_key(placement)?;
            let relative_path = placement_relative_path(placement)?;
            let repository_path = format!(
                "skills/{}/{}",
                sanitize_skill_name(&placement.name)?,
                placement_key
            );
            entry.placements.push(BackupPlacement {
                workspace_id: placement.workspace_id.clone(),
                workspace_kind: format!("{:?}", placement.workspace_kind),
                agent_id: placement.agent_id.as_ref().map(|agent| agent.0.clone()),
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
                repository_path: repository_path.clone(),
                relative_path,
            });
            let destination = skills_root
                .join(sanitize_skill_name(&placement.name)?)
                .join(placement_key);
            if destination.exists() {
                return Err(GinoError::InvalidPlan(format!(
                    "backup placement path already exists: {}",
                    destination.display()
                )));
            }
            copy_tree_dereferenced(&placement.path, &destination)?;
        }
        let manifest_path = self.root.join("manifest.json");
        let bytes = serde_json::to_vec_pretty(&BackupManifest {
            version: 1,
            metadata: metadata.clone(),
            skills: manifest,
        })
        .map_err(|source| crate::error::json_error(&manifest_path, source))?;
        write_atomic(&manifest_path, &bytes)
    }

    pub fn commit(&self, message: &str, push_mode: PushMode) -> Result<(String, PushStatus)> {
        let staged = self.run(&["diff", "--cached", "--name-only"])?;
        if staged.iter().any(|byte| !byte.is_ascii_whitespace()) {
            return Err(GinoError::Git {
                directory: self.root.clone(),
                command: "git diff --cached --name-only".to_owned(),
                cause: "unrelated changes are already staged in the backup repository".to_owned(),
            });
        }
        self.run(&["add", "--all", "--", "skills", "manifest.json"])?;
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

    pub fn discard_materialized_changes(&self) -> Result<()> {
        if self.run(&["rev-parse", "--verify", "HEAD"]).is_ok() {
            let tracked = self.run(&["ls-files", "--", "skills", "manifest.json"])?;
            if !tracked.is_empty() {
                self.run(&[
                    "restore",
                    "--source=HEAD",
                    "--staged",
                    "--worktree",
                    "--",
                    "skills",
                    "manifest.json",
                ])?;
            }
            self.run(&["clean", "-fd", "--", "skills", "manifest.json"])?;
        } else {
            remove_path(&self.root.join("skills"))?;
            remove_path(&self.root.join("manifest.json"))?;
        }
        Ok(())
    }

    /// One `git fetch` per session (§16.5): refreshes remote refs without
    /// touching the working tree.
    pub fn fetch(&self) -> Result<()> {
        self.run(&["fetch", "--quiet", "--all"])?;
        Ok(())
    }

    /// The remote tracking ref for the current branch, e.g. `origin/main`.
    /// `None` when the repository has no upstream configured.
    pub fn upstream_ref(&self) -> Result<Option<String>> {
        let output = self.run(&[
            "rev-parse",
            "--abbrev-ref",
            "--symbolic-full-name",
            "@{upstream}",
        ])?;
        let reference = String::from_utf8_lossy(&output).trim().to_owned();
        if reference.is_empty() {
            return Ok(None);
        }
        Ok(Some(reference))
    }

    /// Read the backup manifest recorded at `revision` (US-017/US-019).
    pub fn manifest_from_ref(&self, revision: &str) -> Result<BackupManifest> {
        let target = format!("{revision}:manifest.json");
        let bytes = self.run(&["show", &target])?;
        let manifest: BackupManifest =
            serde_json::from_slice(&bytes).map_err(|source| GinoError::Git {
                directory: self.root.clone(),
                command: format!("git show {revision}:manifest.json"),
                cause: format!("manifest at `{revision}` is not valid backup JSON: {source}"),
            })?;
        if manifest.version != 1 {
            return Err(GinoError::Git {
                directory: self.root.clone(),
                command: format!("git show {revision}:manifest.json"),
                cause: format!(
                    "manifest at `{revision}` uses unsupported version {}",
                    manifest.version
                ),
            });
        }
        Ok(manifest)
    }

    /// Materialize the tree at `repository_path` (e.g. `skills/demo/abc123`)
    /// from `revision` into `destination`. The tree's leading path components
    /// are stripped so the Skill contents land directly in `destination`.
    pub fn extract_tree(
        &self,
        revision: &str,
        repository_path: &str,
        destination: &Path,
    ) -> Result<()> {
        fs::create_dir_all(destination).map_err(|source| io_error(destination, source))?;
        let tar_bytes = self.run(&["archive", "--format=tar", revision, "--", repository_path])?;
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_nanos())
            .map_err(|source| GinoError::Clock {
                cause: source.to_string(),
            })?;
        let tar_path = self.root.join(format!(".gino-extract-{stamp}.tar"));
        fs::write(&tar_path, &tar_bytes).map_err(|source| io_error(&tar_path, source))?;
        let strip = repository_path.split('/').count().to_string();
        let output = Command::new("tar")
            .args(["-xf", tar_path.to_string_lossy().as_ref()])
            .arg("--strip-components")
            .arg(&strip)
            .arg("-C")
            .arg(destination)
            .output()
            .map_err(|source| io_error(&tar_path, source))?;
        let _ = fs::remove_file(&tar_path);
        if !output.status.success() {
            return Err(GinoError::Git {
                directory: self.root.clone(),
                command: format!("tar -xf ... --strip-components={strip}"),
                cause: String::from_utf8_lossy(&output.stderr).trim().to_owned(),
            });
        }
        Ok(())
    }

    /// Recent backup history for restore proposals (US-019).
    pub fn log(&self, limit: usize) -> Result<Vec<CommitInfo>> {
        let format = "%H%x1f%cI%x1f%s";
        let bytes = self.run(&["log", &format!("--format={format}"), &format!("-n {limit}")])?;
        let text = String::from_utf8_lossy(&bytes);
        Ok(text
            .lines()
            .filter(|line| !line.is_empty())
            .map(|line| {
                let mut parts = line.split('\u{1f}');
                CommitInfo {
                    id: parts.next().unwrap_or_default().to_owned(),
                    created_at: parts.next().unwrap_or_default().to_owned(),
                    subject: parts.next().unwrap_or_default().to_owned(),
                }
            })
            .collect())
    }

    /// Compare the local inventory against the remote backup manifest
    /// (§16.5/16.6, US-017). Read-only: differences are proposed per Skill
    /// and become Pending Changes only after the user selects a resolution.
    pub fn propose_sync(&self, inventory: &Inventory) -> Result<SyncProposal> {
        let reference = self.upstream_ref()?.ok_or_else(|| GinoError::Git {
            directory: self.root.clone(),
            command: "git rev-parse @{upstream}".to_owned(),
            cause: "no upstream remote is configured for the backup repository".to_owned(),
        })?;
        let remote_commit = String::from_utf8_lossy(&self.run(&["rev-parse", &reference])?)
            .trim()
            .to_owned();
        let manifest = self.manifest_from_ref(&reference)?;
        let mut remote_placements = BTreeMap::<(String, String), (String, Option<String>)>::new();
        for (skill_name, skill) in &manifest.skills {
            for placement in &skill.placements {
                remote_placements.insert(
                    (
                        placement.workspace_id.clone(),
                        placement.relative_path.clone(),
                    ),
                    (skill_name.clone(), placement.content_hash.clone()),
                );
            }
        }
        let mut changes = Vec::new();
        for ((workspace_id, relative_path), (skill_name, remote_hash)) in &remote_placements {
            let local = inventory.placements.iter().find(|placement| {
                placement.workspace_id == *workspace_id
                    && placement_relative_path(placement)
                        .map(|relative| relative == *relative_path)
                        .unwrap_or(false)
            });
            changes.push(match local {
                None => RemoteSkillChange {
                    skill_name: skill_name.clone(),
                    workspace_id: workspace_id.clone(),
                    relative_path: relative_path.clone(),
                    status: RemoteChangeStatus::Available,
                    remote_content_hash: remote_hash.clone(),
                    local_content_hash: None,
                },
                Some(local) => {
                    let local_hash = local.content_hash.clone();
                    let status = if local_hash == *remote_hash {
                        RemoteChangeStatus::Unchanged
                    } else {
                        RemoteChangeStatus::Conflict
                    };
                    RemoteSkillChange {
                        skill_name: skill_name.clone(),
                        workspace_id: workspace_id.clone(),
                        relative_path: relative_path.clone(),
                        status,
                        remote_content_hash: remote_hash.clone(),
                        local_content_hash: local_hash,
                    }
                }
            });
        }
        for placement in &inventory.placements {
            let key = (
                placement.workspace_id.clone(),
                placement_relative_path(placement)?,
            );
            if !remote_placements.contains_key(&key) {
                changes.push(RemoteSkillChange {
                    skill_name: placement.name.clone(),
                    workspace_id: placement.workspace_id.clone(),
                    relative_path: key.1,
                    status: RemoteChangeStatus::Removed,
                    remote_content_hash: None,
                    local_content_hash: placement.content_hash.clone(),
                });
            }
        }
        changes.sort_by(|left, right| {
            left.skill_name
                .cmp(&right.skill_name)
                .then_with(|| left.workspace_id.cmp(&right.workspace_id))
                .then_with(|| left.relative_path.cmp(&right.relative_path))
        });
        Ok(SyncProposal {
            remote_commit,
            changes,
        })
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

fn placement_relative_path(placement: &crate::inventory::SkillPlacement) -> Result<String> {
    let relative = placement
        .path
        .strip_prefix(&placement.workspace_root)
        .map_err(|_| GinoError::UnsafePath {
            path: placement.path.clone(),
            reason: "Skill placement is outside its workspace root".to_owned(),
        })?;
    Ok(relative
        .components()
        .filter_map(|component| match component {
            std::path::Component::Normal(value) => Some(value.to_string_lossy().into_owned()),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("/"))
}

fn placement_repository_key(placement: &crate::inventory::SkillPlacement) -> Result<String> {
    let relative_path = placement_relative_path(placement)?;
    let logical_identity = format!("{}:{relative_path}", placement.workspace_id);
    let digest = crate::protocol::sha256_bytes(logical_identity.as_bytes());
    let workspace = placement
        .workspace_id
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || matches!(character, '-' | '_' | '.') {
                character
            } else {
                '_'
            }
        })
        .collect::<String>();
    if workspace.is_empty() {
        return Err(GinoError::InvalidPlan(
            "backup placement requires a non-empty workspace id".to_owned(),
        ));
    }
    Ok(format!("{workspace}-{}", &digest[..12]))
}

fn remove_path(path: &Path) -> Result<()> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(io_error(path, error)),
    };
    if metadata.file_type().is_symlink() || metadata.is_file() {
        fs::remove_file(path).map_err(|source| io_error(path, source))
    } else {
        fs::remove_dir_all(path).map_err(|source| io_error(path, source))
    }
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

    #[test]
    fn backup_keeps_same_name_placements_separate() {
        let first_root = tempdir().expect("first root");
        let second_root = tempdir().expect("second root");
        fs::create_dir_all(first_root.path().join("demo")).expect("first skill");
        fs::create_dir_all(second_root.path().join("demo")).expect("second skill");
        fs::write(
            first_root.path().join("demo/SKILL.md"),
            "---\nname: demo\ndescription: first\n---\nfirst\n",
        )
        .expect("first skill file");
        fs::write(
            second_root.path().join("demo/SKILL.md"),
            "---\nname: demo\ndescription: second\n---\nsecond\n",
        )
        .expect("second skill file");
        let first = Workspace::new("first", "First", WorkspaceKind::Custom, first_root.path());
        let second = Workspace::new(
            "second",
            "Second",
            WorkspaceKind::Custom,
            second_root.path(),
        );
        let inventory = InventoryScanner::new(&[first, second])
            .scan(1)
            .expect("scan");
        let backup = tempdir().expect("backup");
        let repository = GitRepository::open_or_init(backup.path()).expect("git init");

        repository
            .materialize_inventory(&inventory)
            .expect("materialize");

        let entries = fs::read_dir(backup.path().join("skills/demo"))
            .expect("backup placements")
            .collect::<std::result::Result<Vec<_>, _>>()
            .expect("placement entries");
        assert_eq!(entries.len(), 2);
        assert!(
            entries
                .iter()
                .all(|entry| { entry.path().join("SKILL.md").is_file() })
        );
        let manifest = fs::read_to_string(backup.path().join("manifest.json")).expect("manifest");
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&manifest).expect("manifest json")["skills"]
                ["demo"]["placements"]
                .as_array()
                .expect("placements")
                .len(),
            2
        );
    }

    #[test]
    fn materialization_failure_does_not_remove_unrelated_files() {
        let backup = tempdir().expect("backup");
        let repository = GitRepository::open_or_init(backup.path()).expect("git init");
        fs::create_dir_all(backup.path().join("skills")).expect("skills root");
        fs::write(backup.path().join("skills/user-change.txt"), "keep").expect("user file");

        let error = repository
            .materialize_inventory(&Inventory::empty())
            .expect_err("dirty generated path");

        assert!(error.to_string().contains("uncommitted changes"));
        assert_eq!(
            fs::read_to_string(backup.path().join("skills/user-change.txt")).expect("user file"),
            "keep"
        );
    }

    fn write_skill(root: &Path, name: &str, body: &str) {
        fs::create_dir_all(root.join(name)).expect("skill dir");
        fs::write(
            root.join(name).join("SKILL.md"),
            format!("---\nname: {name}\ndescription: demo\n---\n{body}\n"),
        )
        .expect("skill file");
    }

    fn scan(root: &Path) -> Inventory {
        let workspace = Workspace::new("dev", "Dev", WorkspaceKind::Custom, root);
        InventoryScanner::new(&[workspace]).scan(1).expect("scan")
    }

    #[test]
    fn fetch_and_propose_sync_report_available_unchanged_and_removed_skills() {
        let remote_root = tempdir().expect("remote device");
        let remote_repo = GitRepository::open_or_init(remote_root.path()).expect("git init");
        write_skill(remote_root.path(), "demo", "remote body");
        write_skill(remote_root.path(), "remote-extra", "remote extra");
        let remote_inventory = scan(remote_root.path());
        remote_repo
            .materialize_inventory(&remote_inventory)
            .expect("remote materialize");
        remote_repo
            .run(&["branch", "-M", "main"])
            .expect("remote branch");
        remote_repo
            .commit("Apply 1 change", PushMode::CommitLocally)
            .expect("remote commit");

        // The backup repository clones the remote device's repository and
        // installs its own Skill set locally.
        let local_root = tempdir().expect("local device");
        let local_repo = GitRepository::open_or_init(local_root.path()).expect("git init");
        let _ = local_repo.run(&[
            "remote",
            "add",
            "origin",
            remote_root.path().to_string_lossy().as_ref(),
        ]);
        write_skill(local_root.path(), "demo", "remote body");
        write_skill(local_root.path(), "local-only", "local only");
        let local_inventory = scan(local_root.path());
        local_repo
            .materialize_inventory(&local_inventory)
            .expect("local materialize");
        local_repo
            .run(&["branch", "-M", "main"])
            .expect("local branch");
        local_repo
            .commit("Apply 1 change", PushMode::CommitLocally)
            .expect("local commit");
        local_repo.fetch().expect("fetch");
        local_repo
            .run(&["branch", "--set-upstream-to=origin/main", "main"])
            .expect("set upstream");

        let proposal = local_repo.propose_sync(&local_inventory).expect("proposal");
        assert_eq!(proposal.remote_commit.len(), 40);
        let status_of = |name: &str| {
            proposal
                .changes
                .iter()
                .find(|change| change.skill_name == name)
                .map(|change| change.status)
        };
        assert_eq!(status_of("demo"), Some(RemoteChangeStatus::Unchanged));
        assert_eq!(
            status_of("remote-extra"),
            Some(RemoteChangeStatus::Available)
        );
        assert_eq!(status_of("local-only"), Some(RemoteChangeStatus::Removed));
    }

    #[test]
    fn manifest_from_ref_and_extract_tree_restore_remote_content() {
        let device_root = tempdir().expect("device");
        let device_repo = GitRepository::open_or_init(device_root.path()).expect("git init");
        write_skill(device_root.path(), "demo", "backup body");
        let inventory = scan(device_root.path());
        device_repo
            .materialize_inventory(&inventory)
            .expect("materialize");
        device_repo.run(&["branch", "-M", "main"]).expect("branch");
        device_repo
            .commit("Apply 1 change", PushMode::CommitLocally)
            .expect("commit");

        let head = device_repo.run(&["rev-parse", "HEAD"]).expect("head");
        let head = String::from_utf8_lossy(&head).trim().to_owned();
        let manifest = device_repo.manifest_from_ref(&head).expect("manifest");
        assert_eq!(manifest.version, 1);
        let placement = manifest.skills["demo"].placements[0].clone();
        let restored = tempdir().expect("restored");
        device_repo
            .extract_tree(&head, &placement.repository_path, restored.path())
            .expect("extract");

        let contents = fs::read_to_string(restored.path().join("SKILL.md")).expect("restored file");
        assert!(contents.contains("backup body"));

        let history = device_repo.log(5).expect("log");
        assert!(!history.is_empty());
        assert_eq!(history[0].id, head);
    }
}
