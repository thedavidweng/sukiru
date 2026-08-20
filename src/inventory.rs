use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use sha2::{Digest, Sha256};

use crate::agents::AgentId;
use crate::error::{Result, io_error};
use crate::protocol::{
    LockFile, LockScope, SkillLockEntry, SkillMetadata, parse_skill_metadata, read_lock_file,
    skill_folder_hash,
};

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum WorkspaceKind {
    Global,
    Project,
    Agent,
    Custom,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct LockReference {
    pub path: PathBuf,
    pub scope: LockScope,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct Workspace {
    pub id: String,
    pub display_name: String,
    pub kind: WorkspaceKind,
    pub root: PathBuf,
    pub agent_id: Option<AgentId>,
    pub lock: Option<LockReference>,
}

impl Workspace {
    pub fn new(
        id: impl Into<String>,
        display_name: impl Into<String>,
        kind: WorkspaceKind,
        root: impl Into<PathBuf>,
    ) -> Self {
        Self {
            id: id.into(),
            display_name: display_name.into(),
            kind,
            root: root.into(),
            agent_id: None,
            lock: None,
        }
    }

    pub fn with_agent(mut self, agent_id: AgentId) -> Self {
        self.agent_id = Some(agent_id);
        self
    }

    pub fn with_lock(mut self, path: impl Into<PathBuf>, scope: LockScope) -> Self {
        self.lock = Some(LockReference {
            path: path.into(),
            scope,
        });
        self
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum PlacementKind {
    Directory,
    Symlink,
    BrokenSymlink,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum SkillState {
    Managed,
    Untracked,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SkillPlacement {
    pub name: String,
    pub description: String,
    pub metadata: SkillMetadata,
    pub workspace_id: String,
    pub workspace_kind: WorkspaceKind,
    pub workspace_root: PathBuf,
    pub lock_file: Option<PathBuf>,
    pub lock_scope: Option<LockScope>,
    pub agent_id: Option<AgentId>,
    pub path: PathBuf,
    pub canonical_path: Option<PathBuf>,
    pub link_target: Option<PathBuf>,
    pub placement_kind: PlacementKind,
    pub content_hash: Option<String>,
    pub state: SkillState,
    pub lock_entry: Option<SkillLockEntry>,
}

impl SkillPlacement {
    pub fn physical_identity(&self) -> Option<&Path> {
        self.canonical_path.as_deref()
    }

    pub fn source_identity(&self) -> Option<String> {
        self.lock_entry
            .as_ref()
            .filter(|entry| entry.managed() && self.state == SkillState::Managed)
            .map(SkillLockEntry::source_identity)
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct InventoryIssue {
    pub path: PathBuf,
    pub reason: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Inventory {
    pub generation: u64,
    pub placements: Vec<SkillPlacement>,
    pub duplicate_groups: Vec<DuplicateGroup>,
    pub issues: Vec<InventoryIssue>,
}

impl Inventory {
    pub fn empty() -> Self {
        Self {
            generation: 0,
            placements: Vec::new(),
            duplicate_groups: Vec::new(),
            issues: Vec::new(),
        }
    }

    pub fn with_issue(generation: u64, path: PathBuf, reason: impl Into<String>) -> Self {
        Self {
            generation,
            placements: Vec::new(),
            duplicate_groups: Vec::new(),
            issues: vec![InventoryIssue {
                path,
                reason: reason.into(),
            }],
        }
    }

    pub fn by_name(&self, name: &str) -> Vec<&SkillPlacement> {
        self.placements
            .iter()
            .filter(|placement| placement.name == name)
            .collect()
    }

    pub fn rescan(&self, workspaces: &[Workspace]) -> Result<Self> {
        InventoryScanner::new(workspaces).scan(self.generation.saturating_add(1))
    }
}

pub struct InventoryScanner<'a> {
    workspaces: &'a [Workspace],
}

impl<'a> InventoryScanner<'a> {
    pub fn new(workspaces: &'a [Workspace]) -> Self {
        Self { workspaces }
    }

    pub fn scan(&self, generation: u64) -> Result<Inventory> {
        let mut inventory = Inventory {
            generation,
            placements: Vec::new(),
            duplicate_groups: Vec::new(),
            issues: Vec::new(),
        };
        for workspace in self.workspaces {
            let lock = match &workspace.lock {
                Some(reference) => match read_lock_file(&reference.path, reference.scope) {
                    Ok(lock) => Some(lock),
                    Err(error) => {
                        inventory.issues.push(InventoryIssue {
                            path: reference.path.clone(),
                            reason: error.to_string(),
                        });
                        None
                    }
                },
                None => None,
            };
            self.scan_workspace(workspace, lock.as_ref(), &mut inventory)?;
        }
        resolve_ambiguous_lock_entries(&mut inventory.placements);
        inventory.duplicate_groups = duplicate_groups(&inventory.placements);
        Ok(inventory)
    }

    fn scan_workspace(
        &self,
        workspace: &Workspace,
        lock: Option<&LockFile>,
        inventory: &mut Inventory,
    ) -> Result<()> {
        let root_metadata = match fs::symlink_metadata(&workspace.root) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(error) => return Err(io_error(&workspace.root, error)),
        };
        if root_metadata.file_type().is_symlink() {
            match fs::metadata(&workspace.root) {
                Ok(target) if target.is_dir() => {}
                Ok(_) => {
                    inventory.issues.push(InventoryIssue {
                        path: workspace.root.clone(),
                        reason: "workspace link does not target a directory".to_owned(),
                    });
                    return Ok(());
                }
                Err(error) => {
                    inventory.issues.push(InventoryIssue {
                        path: workspace.root.clone(),
                        reason: error.to_string(),
                    });
                    return Ok(());
                }
            }
        } else if !root_metadata.is_dir() {
            inventory.issues.push(InventoryIssue {
                path: workspace.root.clone(),
                reason: "workspace root is not a directory".to_owned(),
            });
            return Ok(());
        }
        self.scan_container(&workspace.root, workspace, lock, inventory)
    }

    fn scan_container(
        &self,
        container: &Path,
        workspace: &Workspace,
        lock: Option<&LockFile>,
        inventory: &mut Inventory,
    ) -> Result<()> {
        if container.join("SKILL.md").is_file() {
            self.inspect_placement(workspace, container, lock, inventory);
            return Ok(());
        }
        let mut children = Vec::new();
        for entry in fs::read_dir(container).map_err(|source| io_error(container, source))? {
            let entry = entry.map_err(|source| io_error(container, source))?;
            children.push(entry.path());
        }
        children.sort();
        for child in children {
            let metadata = match fs::symlink_metadata(&child) {
                Ok(metadata) => metadata,
                Err(source) => {
                    inventory.issues.push(InventoryIssue {
                        path: child.clone(),
                        reason: source.to_string(),
                    });
                    continue;
                }
            };
            if metadata.file_type().is_symlink() {
                match fs::metadata(&child) {
                    Ok(target) if target.is_dir() && child.join("SKILL.md").is_file() => {
                        self.inspect_placement(workspace, &child, lock, inventory);
                    }
                    Ok(_) => {}
                    Err(_) => {
                        let link_target = fs::read_link(&child).ok();
                        self.record_broken_symlink(workspace, &child, link_target, lock, inventory);
                    }
                }
                continue;
            }
            if !metadata.is_dir() || is_ignored_container(&child) {
                continue;
            }
            self.scan_container(&child, workspace, lock, inventory)?;
        }
        Ok(())
    }

    fn inspect_placement(
        &self,
        workspace: &Workspace,
        path: &Path,
        lock: Option<&LockFile>,
        inventory: &mut Inventory,
    ) {
        let metadata = match parse_skill_metadata(path) {
            Ok(metadata) => metadata,
            Err(error) => {
                inventory.issues.push(InventoryIssue {
                    path: path.to_path_buf(),
                    reason: error.to_string(),
                });
                return;
            }
        };
        let link_metadata = match fs::symlink_metadata(path) {
            Ok(metadata) => metadata,
            Err(error) => {
                inventory.issues.push(InventoryIssue {
                    path: path.to_path_buf(),
                    reason: error.to_string(),
                });
                return;
            }
        };
        let link_target = if link_metadata.file_type().is_symlink() {
            match fs::read_link(path) {
                Ok(target) => Some(target),
                Err(error) => {
                    inventory.issues.push(InventoryIssue {
                        path: path.to_path_buf(),
                        reason: error.to_string(),
                    });
                    return;
                }
            }
        } else {
            None
        };
        let placement_kind = if link_target.is_some() {
            PlacementKind::Symlink
        } else {
            PlacementKind::Directory
        };
        let canonical_path = match fs::canonicalize(path) {
            Ok(path) => Some(path),
            Err(error) => {
                inventory.issues.push(InventoryIssue {
                    path: path.to_path_buf(),
                    reason: error.to_string(),
                });
                None
            }
        };
        let content_hash = match skill_folder_hash(path) {
            Ok(hash) => Some(hash),
            Err(error) => {
                inventory.issues.push(InventoryIssue {
                    path: path.to_path_buf(),
                    reason: error.to_string(),
                });
                None
            }
        };
        let lock_entry = lock.and_then(|lock| lock.skills.get(&metadata.name).cloned());
        let state = lock_entry
            .as_ref()
            .filter(|entry| entry.managed())
            .map(|_| SkillState::Managed)
            .unwrap_or(SkillState::Untracked);
        inventory.placements.push(SkillPlacement {
            name: metadata.name.clone(),
            description: metadata.description.clone(),
            metadata,
            workspace_id: workspace.id.clone(),
            workspace_kind: workspace.kind.clone(),
            workspace_root: workspace.root.clone(),
            lock_file: workspace
                .lock
                .as_ref()
                .map(|reference| reference.path.clone()),
            lock_scope: workspace.lock.as_ref().map(|reference| reference.scope),
            agent_id: workspace.agent_id.clone(),
            path: path.to_path_buf(),
            canonical_path,
            link_target,
            placement_kind,
            content_hash,
            state,
            lock_entry,
        });
    }

    /// Record a broken symlink as a placement so it is visible in the Library
    /// and can be queued for cleanup. The metadata cannot be parsed (the target
    /// is gone), so the name is derived from the link's file name and the
    /// description reports the dangling target. A friendly issue is also pushed
    /// so the issue bar shows what happened.
    fn record_broken_symlink(
        &self,
        workspace: &Workspace,
        path: &Path,
        link_target: Option<PathBuf>,
        lock: Option<&LockFile>,
        inventory: &mut Inventory,
    ) {
        let name = path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("unknown")
            .to_owned();
        let target_display = link_target
            .as_ref()
            .map(|target| target.display().to_string())
            .unwrap_or_else(|| "<unreadable>".to_owned());
        let description = format!("Broken symlink → {}", target_display);
        let lock_entry = lock.and_then(|lock| lock.skills.get(&name).cloned());
        let state = lock_entry
            .as_ref()
            .filter(|entry| entry.managed())
            .map(|_| SkillState::Managed)
            .unwrap_or(SkillState::Untracked);
        inventory.placements.push(SkillPlacement {
            name: name.clone(),
            description: description.clone(),
            metadata: SkillMetadata {
                name: name.clone(),
                description: description.clone(),
                path: path.to_path_buf(),
                skill_file: String::new(),
                internal: false,
            },
            workspace_id: workspace.id.clone(),
            workspace_kind: workspace.kind.clone(),
            workspace_root: workspace.root.clone(),
            lock_file: workspace
                .lock
                .as_ref()
                .map(|reference| reference.path.clone()),
            lock_scope: workspace.lock.as_ref().map(|reference| reference.scope),
            agent_id: workspace.agent_id.clone(),
            path: path.to_path_buf(),
            canonical_path: None,
            link_target,
            placement_kind: PlacementKind::BrokenSymlink,
            content_hash: None,
            state,
            lock_entry,
        });
        inventory.issues.push(InventoryIssue {
            path: path.to_path_buf(),
            reason: format!("broken symlink → {}", target_display),
        });
    }
}

fn is_ignored_container(path: &Path) -> bool {
    matches!(
        path.file_name().and_then(|name| name.to_str()),
        Some(".git" | "node_modules" | "__pycache__" | "__pypackages__" | "dist" | "build")
    )
}

fn resolve_ambiguous_lock_entries(placements: &mut [SkillPlacement]) {
    let mut counts = BTreeMap::new();
    for placement in placements.iter() {
        *counts.entry(placement.name.clone()).or_insert(0usize) += 1;
    }
    for placement in placements {
        let Some(count) = counts.get(&placement.name) else {
            continue;
        };
        if *count > 1 && placement.lock_entry.is_some() {
            placement.state = SkillState::Untracked;
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum DuplicateClass {
    ExactDuplicate,
    SourceDuplicate,
    NameCollision,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DuplicateGroup {
    pub class: DuplicateClass,
    pub skill_name: String,
    pub placement_indexes: Vec<usize>,
    pub identity: String,
    /// Deterministic fingerprint of the group's member source/content
    /// identities. Any change to a member's source identity or content hash
    /// changes this value, so ignored duplicate decisions keyed on it stop
    /// hiding the group when the underlying identities change.
    pub fingerprint: String,
}

pub fn duplicate_groups(placements: &[SkillPlacement]) -> Vec<DuplicateGroup> {
    let mut groups = Vec::new();
    let mut exact: BTreeMap<(String, String), Vec<usize>> = BTreeMap::new();
    let mut source: BTreeMap<(String, String), Vec<usize>> = BTreeMap::new();
    let mut names: BTreeMap<String, Vec<usize>> = BTreeMap::new();
    for (index, placement) in placements.iter().enumerate() {
        names.entry(placement.name.clone()).or_default().push(index);
        if let Some(hash) = &placement.content_hash {
            exact
                .entry((placement.name.clone(), hash.clone()))
                .or_default()
                .push(index);
        }
        if let Some(source_identity) = placement.source_identity() {
            source
                .entry((placement.name.clone(), source_identity))
                .or_default()
                .push(index);
        }
    }

    for ((name, hash), indexes) in exact {
        let physical: BTreeSet<Option<PathBuf>> = indexes
            .iter()
            .map(|index| placements[*index].canonical_path.clone())
            .collect();
        if indexes.len() > 1 && physical.len() > 1 {
            let fingerprint = group_fingerprint(&indexes, placements);
            groups.push(DuplicateGroup {
                class: DuplicateClass::ExactDuplicate,
                skill_name: name,
                placement_indexes: indexes,
                identity: hash.clone(),
                fingerprint,
            });
        }
    }
    for ((name, source_identity), indexes) in source {
        let hashes: BTreeSet<Option<String>> = indexes
            .iter()
            .map(|index| placements[*index].content_hash.clone())
            .collect();
        if indexes.len() > 1 && hashes.len() > 1 {
            let fingerprint = group_fingerprint(&indexes, placements);
            groups.push(DuplicateGroup {
                class: DuplicateClass::SourceDuplicate,
                skill_name: name,
                placement_indexes: indexes,
                identity: source_identity,
                fingerprint,
            });
        }
    }
    for (name, indexes) in names {
        let source_identities: BTreeSet<Option<String>> = indexes
            .iter()
            .map(|index| placements[*index].source_identity())
            .collect();
        let hashes: BTreeSet<Option<String>> = indexes
            .iter()
            .map(|index| placements[*index].content_hash.clone())
            .collect();
        if indexes.len() > 1 && (source_identities.len() > 1 || hashes.len() > 1) {
            let fingerprint = group_fingerprint(&indexes, placements);
            groups.push(DuplicateGroup {
                class: DuplicateClass::NameCollision,
                skill_name: name,
                placement_indexes: indexes,
                identity: "name".to_owned(),
                fingerprint,
            });
        }
    }
    groups.sort_by(|left, right| {
        left.skill_name
            .cmp(&right.skill_name)
            .then_with(|| left.identity.cmp(&right.identity))
    });
    groups
}

/// Deterministic group fingerprint: SHA-256 over the sorted member
/// `source_identity|content_hash` pairs. Paths and workspace placement do not
/// participate, so moving a Skill does not invalidate an ignore decision, but
/// any source or content change does.
fn group_fingerprint(indexes: &[usize], placements: &[SkillPlacement]) -> String {
    let mut identities = indexes
        .iter()
        .map(|index| {
            let placement = &placements[*index];
            format!(
                "{}|{}",
                placement.source_identity().unwrap_or_default(),
                placement.content_hash.clone().unwrap_or_default()
            )
        })
        .collect::<Vec<_>>();
    identities.sort();
    let mut hasher = Sha256::new();
    for identity in identities {
        hasher.update(identity.as_bytes());
        hasher.update(b"\n");
    }
    format!("{:x}", hasher.finalize())
}

#[cfg(test)]
mod tests {
    use std::fs;
    #[cfg(unix)]
    use std::os::unix::fs::symlink;

    use tempfile::tempdir;

    use super::*;

    fn write_skill(root: &Path, name: &str, body: &str) {
        let skill = root.join(name);
        fs::create_dir_all(&skill).expect("skill dir");
        fs::write(
            skill.join("SKILL.md"),
            format!("---\nname: {name}\ndescription: {name} description\n---\n{body}\n"),
        )
        .expect("skill file");
    }

    #[test]
    fn scan_discovers_external_skills_and_marks_untracked_state() {
        let root = tempdir().expect("root");
        write_skill(root.path(), "demo", "hello");
        let workspace = Workspace::new("custom", "Custom", WorkspaceKind::Custom, root.path());
        let inventory = InventoryScanner::new(&[workspace]).scan(1).expect("scan");
        assert_eq!(inventory.placements.len(), 1);
        assert_eq!(inventory.placements[0].name, "demo");
        assert_eq!(inventory.placements[0].state, SkillState::Untracked);
    }

    #[test]
    fn scan_discovers_nested_skill_directories() {
        let root = tempdir().expect("root");
        let nested_root = root.path().join("catalog/category");
        write_skill(&nested_root, "demo", "nested");
        let workspace = Workspace::new("custom", "Custom", WorkspaceKind::Custom, root.path());

        let inventory = InventoryScanner::new(&[workspace]).scan(1).expect("scan");

        assert_eq!(inventory.placements.len(), 1);
        assert_eq!(inventory.placements[0].path, nested_root.join("demo"));
    }

    #[test]
    fn shared_name_lock_entry_is_not_assigned_to_ambiguous_placements() {
        let first_root = tempdir().expect("first root");
        let second_root = tempdir().expect("second root");
        write_skill(first_root.path(), "demo", "first");
        write_skill(second_root.path(), "demo", "second");
        let lock_path = first_root.path().join(".skill-lock.json");
        fs::write(
            &lock_path,
            r#"{
              "version": 3,
              "skills": {
                "demo": {"source": "owner/repo", "sourceType": "github"}
              }
            }"#,
        )
        .expect("lockfile");
        let first = Workspace::new("first", "First", WorkspaceKind::Custom, first_root.path())
            .with_lock(&lock_path, LockScope::Global);
        let second = Workspace::new(
            "second",
            "Second",
            WorkspaceKind::Custom,
            second_root.path(),
        )
        .with_lock(&lock_path, LockScope::Global);

        let inventory = InventoryScanner::new(&[first, second])
            .scan(1)
            .expect("scan");

        assert_eq!(inventory.placements.len(), 2);
        assert!(
            inventory
                .placements
                .iter()
                .all(|placement| placement.state == SkillState::Untracked)
        );
    }

    #[cfg(unix)]
    #[test]
    fn shared_symlink_is_not_reported_as_an_exact_duplicate() {
        let root = tempdir().expect("root");
        write_skill(root.path(), "canonical", "same");
        symlink(root.path().join("canonical"), root.path().join("linked")).expect("link");
        let workspace = Workspace::new("custom", "Custom", WorkspaceKind::Custom, root.path());
        let inventory = InventoryScanner::new(&[workspace]).scan(1).expect("scan");
        assert!(
            inventory
                .duplicate_groups
                .iter()
                .all(|group| group.class != DuplicateClass::ExactDuplicate)
        );
    }

    #[cfg(unix)]
    #[test]
    fn broken_symlink_becomes_placement_with_friendly_issue() {
        let root = tempdir().expect("root");
        write_skill(root.path(), "real", "body");
        // Create a broken symlink: target does not exist.
        symlink(
            root.path().join("nonexistent-target"),
            root.path().join("dangling"),
        )
        .expect("broken link");
        let workspace = Workspace::new("custom", "Custom", WorkspaceKind::Custom, root.path());

        let inventory = InventoryScanner::new(&[workspace]).scan(1).expect("scan");

        let broken = inventory
            .placements
            .iter()
            .find(|placement| placement.name == "dangling")
            .expect("broken symlink placement");
        assert_eq!(broken.placement_kind, PlacementKind::BrokenSymlink);
        assert!(
            broken
                .link_target
                .as_ref()
                .map(|t| t.ends_with("nonexistent-target"))
                .unwrap_or(false)
        );
        assert!(broken.description.contains("Broken symlink"));
        assert!(broken.content_hash.is_none());
        assert_eq!(broken.state, SkillState::Untracked);

        let issue = inventory
            .issues
            .iter()
            .find(|issue| issue.path == root.path().join("dangling"))
            .expect("issue for broken symlink");
        assert!(issue.reason.starts_with("broken symlink →"));
        assert!(issue.reason.contains("nonexistent-target"));
    }
}
