use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

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
            .filter(|entry| entry.managed())
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
        inventory.duplicate_groups = duplicate_groups(&inventory.placements);
        Ok(inventory)
    }

    fn scan_workspace(
        &self,
        workspace: &Workspace,
        lock: Option<&LockFile>,
        inventory: &mut Inventory,
    ) -> Result<()> {
        if !workspace.root.exists() {
            return Ok(());
        }
        let root_metadata = fs::symlink_metadata(&workspace.root)
            .map_err(|source| io_error(&workspace.root, source))?;
        if root_metadata.file_type().is_symlink() {
            if fs::metadata(&workspace.root).is_err() {
                inventory.issues.push(InventoryIssue {
                    path: workspace.root.clone(),
                    reason: "broken workspace symlink".to_owned(),
                });
                return Ok(());
            }
        }
        if workspace.root.join("SKILL.md").exists() {
            self.inspect_placement(workspace, &workspace.root, lock, inventory);
            return Ok(());
        }
        let entries =
            fs::read_dir(&workspace.root).map_err(|source| io_error(&workspace.root, source))?;
        let mut children: Vec<PathBuf> = entries
            .filter_map(|entry| entry.ok().map(|entry| entry.path()))
            .collect();
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
                if fs::metadata(&child)
                    .map(|target| target.is_dir())
                    .unwrap_or(false)
                {
                    self.inspect_placement(workspace, &child, lock, inventory);
                } else {
                    inventory.issues.push(InventoryIssue {
                        path: child.clone(),
                        reason: "broken or non-directory Skill link".to_owned(),
                    });
                }
                continue;
            }
            if metadata.is_dir() && child.join("SKILL.md").exists() {
                self.inspect_placement(workspace, &child, lock, inventory);
            }
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
        let link_target = fs::symlink_metadata(path)
            .ok()
            .filter(|metadata| metadata.file_type().is_symlink())
            .and_then(|_| fs::read_link(path).ok());
        let placement_kind = if link_target.is_some() {
            PlacementKind::Symlink
        } else {
            PlacementKind::Directory
        };
        let canonical_path = fs::canonicalize(path).ok();
        let content_hash = skill_folder_hash(path).ok();
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
            groups.push(DuplicateGroup {
                class: DuplicateClass::ExactDuplicate,
                skill_name: name,
                placement_indexes: indexes,
                identity: hash,
            });
        }
    }
    for ((name, source_identity), indexes) in source {
        let hashes: BTreeSet<Option<String>> = indexes
            .iter()
            .map(|index| placements[*index].content_hash.clone())
            .collect();
        if indexes.len() > 1 && hashes.len() > 1 {
            groups.push(DuplicateGroup {
                class: DuplicateClass::SourceDuplicate,
                skill_name: name,
                placement_indexes: indexes,
                identity: source_identity,
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
            groups.push(DuplicateGroup {
                class: DuplicateClass::NameCollision,
                skill_name: name,
                placement_indexes: indexes,
                identity: "name".to_owned(),
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
}
