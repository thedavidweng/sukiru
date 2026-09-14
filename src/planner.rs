use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::error::{GinoError, Result, io_error};
use crate::executor::{Snapshot, SnapshotState};
use crate::inventory::{Inventory, LockReference, PlacementKind, SkillPlacement, Workspace};
use crate::protocol::{
    LockScope, SkillLockEntry, SkillSource, parse_skill_metadata, project_computed_hash,
    read_lock_file, skill_folder_hash,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum InstallMode {
    Copy,
    Link,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum PlanAction {
    Install,
    Update,
    Remove,
    Move,
    Copy,
    Relink,
    AttachSource,
    Restore,
    Metadata,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum PresetMode {
    AddMissing,
    MatchExactly,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct Preset {
    pub id: String,
    pub name: String,
    pub skills: BTreeSet<String>,
    pub mode: PresetMode,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PendingChange {
    pub id: u64,
    pub action: PlanAction,
    pub skill_name: String,
    pub source: Option<PathBuf>,
    pub destination: PathBuf,
    pub mode: Option<InstallMode>,
    pub summary: String,
    pub unavailable_reason: Option<String>,
    /// Snapshot or commit the change's content originates from. Set only for
    /// restore operations and carried into Activity records (§21).
    #[serde(default)]
    pub restore_origin: Option<String>,
}

impl PendingChange {
    pub fn available(&self) -> bool {
        self.unavailable_reason.is_none()
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub enum OperationKind {
    CopyTree { overwrite: bool },
    LinkTree { overwrite: bool },
    MoveTree { overwrite: bool },
    RemovePath,
    WriteFile { bytes: Vec<u8> },
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct FileOperation {
    pub id: u64,
    pub action: PlanAction,
    pub skill_name: String,
    pub source: Option<PathBuf>,
    pub destination: PathBuf,
    pub kind: OperationKind,
}

impl FileOperation {
    pub fn paths(&self) -> impl Iterator<Item = &Path> {
        self.source
            .iter()
            .map(PathBuf::as_path)
            .chain(std::iter::once(self.destination.as_path()))
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ApplyPlan {
    pub inventory_generation: u64,
    pub declared_roots: Vec<PathBuf>,
    pub changes: Vec<PendingChange>,
    pub operations: Vec<FileOperation>,
    pub warnings: Vec<String>,
    pub blockers: Vec<String>,
}

impl ApplyPlan {
    pub fn new(inventory_generation: u64, declared_roots: Vec<PathBuf>) -> Self {
        Self {
            inventory_generation,
            declared_roots,
            changes: Vec::new(),
            operations: Vec::new(),
            warnings: Vec::new(),
            blockers: Vec::new(),
        }
    }

    pub fn can_apply(&self) -> bool {
        self.blockers.is_empty() && self.changes.iter().all(PendingChange::available)
    }

    pub fn unavailable_count(&self) -> usize {
        self.changes
            .iter()
            .filter(|change| !change.available())
            .count()
    }

    pub fn operation_count(&self) -> usize {
        self.changes.len()
    }

    pub fn filesystem_operation_count(&self) -> usize {
        self.operations.len()
    }

    pub fn validate(&self) -> Result<()> {
        if self.changes.is_empty() {
            return Err(GinoError::InvalidPlan(
                "plan contains no pending changes".to_owned(),
            ));
        }
        if !self.can_apply() {
            return Err(GinoError::InvalidPlan(
                self.blockers
                    .first()
                    .cloned()
                    .or_else(|| {
                        self.changes
                            .iter()
                            .find_map(|change| change.unavailable_reason.clone())
                    })
                    .unwrap_or_else(|| "plan contains unavailable changes".to_owned()),
            ));
        }
        validate_paths(self)?;
        Ok(())
    }

    pub fn mark_missing_inputs(&mut self) {
        for change in &mut self.changes {
            let missing = change
                .source
                .as_ref()
                .filter(|source| !path_present(source))
                .cloned()
                .or_else(|| {
                    (change.source.is_none()
                        && matches!(change.action, PlanAction::Remove)
                        && !path_present(&change.destination))
                    .then(|| change.destination.clone())
                });
            change.unavailable_reason = missing.map(|path| {
                format!(
                    "Missing after refresh: required Skill path does not exist: {}",
                    path.display()
                )
            });
        }
    }
}

pub struct Planner<'a> {
    inventory: &'a Inventory,
    declared_roots: Vec<PathBuf>,
}

impl<'a> Planner<'a> {
    pub fn new(inventory: &'a Inventory, declared_roots: Vec<PathBuf>) -> Self {
        Self {
            inventory,
            declared_roots,
        }
    }

    pub fn inventory(&self) -> &Inventory {
        self.inventory
    }

    pub fn remove(&self, placements: &[&SkillPlacement]) -> Result<ApplyPlan> {
        let mut plan = ApplyPlan::new(self.inventory.generation, self.declared_roots.clone());
        let mut lock_edits = Vec::new();
        let selected_paths = placements
            .iter()
            .map(|placement| placement.path.clone())
            .collect::<BTreeSet<_>>();
        for placement in placements {
            let id = plan.changes.len() as u64 + 1;
            let change = PendingChange {
                id,
                action: PlanAction::Remove,
                skill_name: placement.name.clone(),
                source: None,
                destination: placement.path.clone(),
                mode: None,
                summary: format!(
                    "Remove {} from {}",
                    placement.name,
                    placement.path.display()
                ),
                unavailable_reason: None,
                restore_origin: None,
            };
            plan.changes.push(change);
            plan.operations.push(FileOperation {
                id,
                action: PlanAction::Remove,
                skill_name: placement.name.clone(),
                source: None,
                destination: placement.path.clone(),
                kind: OperationKind::RemovePath,
            });
            let lock_still_referenced = self.inventory.placements.iter().any(|other| {
                other.name == placement.name
                    && other.lock_file == placement.lock_file
                    && other.lock_scope == placement.lock_scope
                    && !selected_paths.contains(&other.path)
            });
            if !lock_still_referenced {
                if let (Some(lock_path), Some(scope)) = (&placement.lock_file, placement.lock_scope)
                {
                    lock_edits.push(LockEdit::Remove {
                        path: lock_path.clone(),
                        scope,
                        skill_name: placement.name.clone(),
                    });
                }
            }
        }
        self.finish_lock_edits(&mut plan, lock_edits)?;
        self.validate_plan(&plan)
    }

    /// Plan removal of every broken symlink placement in the inventory. Each
    /// broken link becomes a single `RemovePath` operation (the executor's
    /// `remove_path` already handles dangling symlinks via `remove_file`).
    /// No lockfile edits are produced: a broken symlink has no readable
    /// SKILL.md, so the lock entry — if any — is left for the user to resolve
    /// in a separate step.
    pub fn cleanup_broken_symlinks(&self) -> Result<ApplyPlan> {
        let mut plan = ApplyPlan::new(self.inventory.generation, self.declared_roots.clone());
        let broken: Vec<&SkillPlacement> = self
            .inventory
            .placements
            .iter()
            .filter(|placement| placement.placement_kind == PlacementKind::BrokenSymlink)
            .collect();
        if broken.is_empty() {
            plan.warnings.push("No broken symlinks found".to_owned());
            return Ok(plan);
        }
        for placement in broken {
            let id = plan.changes.len() as u64 + 1;
            let target_display = placement
                .link_target
                .as_ref()
                .map(|target| target.display().to_string())
                .unwrap_or_else(|| "<unreadable>".to_owned());
            plan.changes.push(PendingChange {
                id,
                action: PlanAction::Remove,
                skill_name: placement.name.clone(),
                source: None,
                destination: placement.path.clone(),
                mode: None,
                summary: format!(
                    "Remove broken symlink {} → {}",
                    placement.path.display(),
                    target_display
                ),
                unavailable_reason: None,
                restore_origin: None,
            });
            plan.operations.push(FileOperation {
                id,
                action: PlanAction::Remove,
                skill_name: placement.name.clone(),
                source: None,
                destination: placement.path.clone(),
                kind: OperationKind::RemovePath,
            });
        }
        self.validate_plan(&plan)
    }

    /// Plan removal of redundant symlink entries that expose a shared Skill
    /// directory through multiple paths. The shared directory always remains
    /// in place; this repair never moves or removes Skill content.
    pub fn cleanup_alias_duplicates(&self) -> Result<ApplyPlan> {
        let mut plan = ApplyPlan::new(self.inventory.generation, self.declared_roots.clone());
        let mut selected_paths = BTreeSet::new();
        let mut next_id = 1u64;
        for group in self
            .inventory
            .duplicate_groups
            .iter()
            .filter(|group| group.class == crate::inventory::DuplicateClass::AliasDuplicate)
        {
            let members = group
                .placement_indexes
                .iter()
                .filter_map(|index| self.inventory.placements.get(*index))
                .collect::<Vec<_>>();
            let has_shared_directory = members
                .iter()
                .any(|placement| placement.placement_kind == PlacementKind::Directory);
            if !has_shared_directory {
                continue;
            }
            for placement in members {
                if placement.placement_kind != PlacementKind::Symlink
                    || !selected_paths.insert(placement.path.clone())
                {
                    continue;
                }
                plan.changes.push(PendingChange {
                    id: next_id,
                    action: PlanAction::Remove,
                    skill_name: placement.name.clone(),
                    source: None,
                    destination: placement.path.clone(),
                    mode: None,
                    summary: format!("Remove redundant alias {}", placement.path.display()),
                    unavailable_reason: None,
                    restore_origin: None,
                });
                plan.operations.push(FileOperation {
                    id: next_id,
                    action: PlanAction::Remove,
                    skill_name: placement.name.clone(),
                    source: None,
                    destination: placement.path.clone(),
                    kind: OperationKind::RemovePath,
                });
                next_id += 1;
            }
        }

        if plan.changes.is_empty() {
            plan.warnings
                .push("No redundant Skill aliases found".to_owned());
            return Ok(plan);
        }

        plan.warnings.push(format!(
            "Cleaned {} redundant shared Skill entr{}; shared content was kept",
            plan.changes.len(),
            if plan.changes.len() == 1 { "y" } else { "ies" }
        ));
        self.validate_plan(&plan)
    }

    pub fn install_local(
        &self,
        source_dir: impl Into<PathBuf>,
        destination: impl Into<PathBuf>,
        mode: InstallMode,
        lock: Option<(&Path, LockScope)>,
    ) -> Result<ApplyPlan> {
        let source_dir = source_dir.into();
        let source = SkillSource::parse(&source_dir.to_string_lossy())?;
        self.install_with_source(&source, source_dir, destination.into(), mode, lock)
    }

    pub fn install_source(
        &self,
        source: &SkillSource,
        source_dir: impl Into<PathBuf>,
        destination: impl Into<PathBuf>,
        mode: InstallMode,
        lock: Option<(&Path, LockScope)>,
    ) -> Result<ApplyPlan> {
        self.install_with_source(source, source_dir.into(), destination.into(), mode, lock)
    }

    fn install_with_source(
        &self,
        source: &SkillSource,
        source_dir: PathBuf,
        destination: PathBuf,
        mode: InstallMode,
        lock: Option<(&Path, LockScope)>,
    ) -> Result<ApplyPlan> {
        let metadata = parse_skill_metadata(&source_dir)?;
        let source_hash = skill_folder_hash(&source_dir)?;
        let mut declared_roots = self.declared_roots.clone();
        declared_roots.push(source_dir.clone());
        let mut plan = ApplyPlan::new(self.inventory.generation, declared_roots);
        let id = 1;
        plan.changes.push(PendingChange {
            id,
            action: PlanAction::Install,
            skill_name: metadata.name.clone(),
            source: Some(source_dir.clone()),
            destination: destination.clone(),
            mode: Some(mode),
            summary: format!("Install {} to {}", metadata.name, destination.display()),
            unavailable_reason: None,
            restore_origin: None,
        });
        plan.operations.push(FileOperation {
            id,
            action: PlanAction::Install,
            skill_name: metadata.name.clone(),
            source: Some(source_dir.clone()),
            destination,
            kind: match mode {
                InstallMode::Copy => OperationKind::CopyTree { overwrite: false },
                InstallMode::Link => OperationKind::LinkTree { overwrite: false },
            },
        });
        if let Some((path, scope)) = lock {
            let scope_hash = scope_hash_for(source_hash, &source_dir, scope)?;
            let entry = Box::new(source.lock_entry_for(scope_hash, scope));
            plan = self.with_lock_edit(
                plan,
                LockEdit::Upsert {
                    path: path.to_path_buf(),
                    scope,
                    skill_name: metadata.name,
                    entry,
                },
            )?;
        }
        self.validate_plan(&plan)
    }

    pub fn apply_preset(
        &self,
        preset: &Preset,
        target: &Workspace,
        source_dirs: &BTreeMap<String, PathBuf>,
    ) -> Result<ApplyPlan> {
        let mut plan = ApplyPlan::new(
            self.inventory.generation,
            self.declared_roots
                .iter()
                .cloned()
                .chain(std::iter::once(target.root.clone()))
                .collect(),
        );
        let target_placements = self
            .inventory
            .placements
            .iter()
            .filter(|placement| placement.workspace_id == target.id)
            .collect::<Vec<_>>();
        let existing_names: BTreeSet<String> = target_placements
            .iter()
            .map(|placement| placement.name.clone())
            .collect();
        let mut lock_edits = Vec::new();

        for skill_name in &preset.skills {
            if existing_names.contains(skill_name) {
                continue;
            }
            let Some(source_dir) = source_dirs.get(skill_name) else {
                plan.blockers.push(format!(
                    "Preset `{}` has no explicit source for Skill `{}`",
                    preset.name, skill_name
                ));
                continue;
            };
            let source_metadata = parse_skill_metadata(source_dir)?;
            let source_hash = skill_folder_hash(source_dir)?;
            let source = SkillSource::parse(&source_dir.to_string_lossy())?;
            let item = self.install_local(
                source_dir.clone(),
                target
                    .root
                    .join(crate::protocol::sanitize_skill_name(skill_name)?),
                InstallMode::Copy,
                None,
            )?;
            merge_plans(&mut plan, item);
            if let Some(lock) = &target.lock {
                lock_edits.push(LockEdit::Upsert {
                    path: lock.path.clone(),
                    scope: lock.scope,
                    skill_name: source_metadata.name,
                    entry: Box::new(source.lock_entry_for(
                        scope_hash_for(source_hash, source_dir, lock.scope)?,
                        lock.scope,
                    )),
                });
            }
        }

        if preset.mode == PresetMode::MatchExactly {
            for placement in target_placements {
                if !preset.skills.contains(&placement.name) {
                    let id = plan.changes.len() as u64 + 1;
                    plan.changes.push(PendingChange {
                        id,
                        action: PlanAction::Remove,
                        skill_name: placement.name.clone(),
                        source: None,
                        destination: placement.path.clone(),
                        mode: None,
                        summary: format!("Remove {} outside preset", placement.name),
                        unavailable_reason: None,
                        restore_origin: None,
                    });
                    plan.operations.push(FileOperation {
                        id,
                        action: PlanAction::Remove,
                        skill_name: placement.name.clone(),
                        source: None,
                        destination: placement.path.clone(),
                        kind: OperationKind::RemovePath,
                    });
                    if let (Some(path), Some(scope)) = (&placement.lock_file, placement.lock_scope)
                    {
                        lock_edits.push(LockEdit::Remove {
                            path: path.clone(),
                            scope,
                            skill_name: placement.name.clone(),
                        });
                    }
                }
            }
        }
        if let Some(lock) = &target.lock {
            if let Some(parent) = lock.path.parent() {
                plan.declared_roots.push(parent.to_path_buf());
            }
        }
        append_lock_edits(&mut plan, lock_edits)?;
        self.validate_plan(&plan)
    }

    pub fn copy(
        &self,
        placement: &SkillPlacement,
        destination: impl Into<PathBuf>,
    ) -> Result<ApplyPlan> {
        self.copy_or_move(
            placement,
            destination.into(),
            InstallMode::Copy,
            PlanAction::Copy,
        )
    }

    pub fn update_local(
        &self,
        source_dir: impl Into<PathBuf>,
        destination: impl Into<PathBuf>,
        lock: Option<(&Path, LockScope)>,
    ) -> Result<ApplyPlan> {
        let mut plan = self.install_local(source_dir, destination, InstallMode::Copy, lock)?;
        for change in &mut plan.changes {
            if change.action == PlanAction::Install {
                change.action = PlanAction::Update;
                change.summary = change.summary.replacen("Install", "Update", 1);
            }
        }
        for operation in &mut plan.operations {
            if operation.action == PlanAction::Install {
                operation.action = PlanAction::Update;
                if let OperationKind::CopyTree { overwrite } = &mut operation.kind {
                    *overwrite = true;
                }
            }
        }
        self.validate_plan(&plan)
    }

    /// Keep Both for a modified local Skill (§14): preserve the local
    /// placement untouched and install the upstream content as a separate
    /// placement. The alias destination must be free; the collision guard
    /// reports a blocker otherwise.
    pub fn keep_both(
        &self,
        upstream_dir: impl Into<PathBuf>,
        alias_destination: impl Into<PathBuf>,
        lock: Option<(&Path, LockScope)>,
    ) -> Result<ApplyPlan> {
        let upstream_dir = upstream_dir.into();
        let alias_destination = alias_destination.into();
        let metadata = parse_skill_metadata(&upstream_dir)?;
        let source_hash = skill_folder_hash(&upstream_dir)?;
        let source = SkillSource::parse(&upstream_dir.to_string_lossy())?;
        let mut plan = ApplyPlan::new(
            self.inventory.generation,
            self.declared_roots
                .iter()
                .cloned()
                .chain(std::iter::once(upstream_dir.clone()))
                .collect(),
        );
        let id = 1;
        plan.changes.push(PendingChange {
            id,
            action: PlanAction::Install,
            skill_name: metadata.name.clone(),
            source: Some(upstream_dir.clone()),
            destination: alias_destination.clone(),
            mode: Some(InstallMode::Copy),
            summary: format!(
                "Keep Both: install upstream copy of {} to {}",
                metadata.name,
                alias_destination.display()
            ),
            unavailable_reason: None,
            restore_origin: None,
        });
        let scope_hash = match lock {
            Some((_, scope)) => Some(scope_hash_for(source_hash, &upstream_dir, scope)?),
            None => None,
        };
        plan.operations.push(FileOperation {
            id,
            action: PlanAction::Install,
            skill_name: metadata.name.clone(),
            source: Some(upstream_dir),
            destination: alias_destination,
            kind: OperationKind::CopyTree { overwrite: false },
        });
        if let (Some((path, scope)), Some(scope_hash)) = (lock, scope_hash) {
            plan = self.with_lock_edit(
                plan,
                LockEdit::Upsert {
                    path: path.to_path_buf(),
                    scope,
                    skill_name: metadata.name,
                    entry: Box::new(source.lock_entry_for(scope_hash, scope)),
                },
            )?;
        }
        self.validate_plan(&plan)
    }

    /// Keep Local for a modified Skill (§14) creates no filesystem operation
    /// by definition: the caller records the ignored upstream identity in the
    /// metadata store so the update stays hidden until upstream content
    /// changes. No planner method exists because there is nothing to plan.
    ///
    /// Restore a local recovery snapshot into Pending Changes (§12.3,
    /// US-019). File and directory entries become overwriting copies of
    /// US-019). File and directory entries become overwriting copies of
    /// their captured payloads, symlink entries are recreated, and entries
    /// that were missing are scheduled for removal. Applying snapshots the
    /// current state first because every operation path is covered by the
    /// transaction snapshot. The lock file, when captured in the snapshot,
    /// is restored through its own entry.
    pub fn restore_snapshot(&self, snapshot: &Snapshot) -> Result<ApplyPlan> {
        let mut plan = ApplyPlan::new(
            self.inventory.generation,
            self.declared_roots
                .iter()
                .cloned()
                .chain(std::iter::once(snapshot.root.clone()))
                .collect(),
        );
        let origin = format!("snapshot {} ({})", snapshot.id, snapshot.created_at);
        for entry in &snapshot.entries {
            let id = plan.changes.len() as u64 + 1;
            let name = entry
                .path
                .file_name()
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or_else(|| entry.path.display().to_string());
            let (kind, action_summary) = match &entry.state {
                SnapshotState::Missing => (
                    OperationKind::RemovePath,
                    format!("Restore {} to missing", entry.path.display()),
                ),
                SnapshotState::File { .. } | SnapshotState::Directory { .. } => (
                    OperationKind::CopyTree { overwrite: true },
                    format!("Restore {} from snapshot", entry.path.display()),
                ),
                SnapshotState::Symlink { target } => (
                    OperationKind::LinkTree { overwrite: true },
                    format!(
                        "Restore symlink {} -> {}",
                        entry.path.display(),
                        target.display()
                    ),
                ),
            };
            let source = match &entry.state {
                SnapshotState::File { payload } | SnapshotState::Directory { payload } => {
                    Some(payload.clone())
                }
                SnapshotState::Symlink { target } => Some(target.clone()),
                SnapshotState::Missing => None,
            };
            plan.changes.push(PendingChange {
                id,
                action: PlanAction::Restore,
                skill_name: name.clone(),
                source: source.clone(),
                destination: entry.path.clone(),
                mode: None,
                summary: action_summary,
                unavailable_reason: None,
                restore_origin: Some(origin.clone()),
            });
            plan.operations.push(FileOperation {
                id,
                action: PlanAction::Restore,
                skill_name: name,
                source,
                destination: entry.path.clone(),
                kind,
            });
        }
        self.validate_plan(&plan)
    }

    /// Restore content materialized from a prior Git commit into a placement
    /// (US-019). `origin` identifies the commit for review and Activity.
    /// `entry` carries the restored placement's lock metadata from the backup
    /// manifest at that commit, if any.
    pub fn restore_from_dir(
        &self,
        source_dir: impl Into<PathBuf>,
        destination: impl Into<PathBuf>,
        lock: Option<(&Path, LockScope)>,
        entry: Option<SkillLockEntry>,
        origin: String,
    ) -> Result<ApplyPlan> {
        let source_dir = source_dir.into();
        let destination = destination.into();
        let metadata = parse_skill_metadata(&source_dir)?;
        let mut plan = ApplyPlan::new(
            self.inventory.generation,
            self.declared_roots
                .iter()
                .cloned()
                .chain(std::iter::once(source_dir.clone()))
                .collect(),
        );
        let id = 1;
        plan.changes.push(PendingChange {
            id,
            action: PlanAction::Restore,
            skill_name: metadata.name.clone(),
            source: Some(source_dir.clone()),
            destination: destination.clone(),
            mode: None,
            summary: format!("Restore {} from {}", metadata.name, destination.display()),
            unavailable_reason: None,
            restore_origin: Some(origin),
        });
        plan.operations.push(FileOperation {
            id,
            action: PlanAction::Restore,
            skill_name: metadata.name.clone(),
            source: Some(source_dir),
            destination,
            kind: OperationKind::CopyTree { overwrite: true },
        });
        if let (Some((path, scope)), Some(entry)) = (lock, entry) {
            plan = self.with_lock_edit(
                plan,
                LockEdit::Upsert {
                    path: path.to_path_buf(),
                    scope,
                    skill_name: metadata.name,
                    entry: Box::new(entry),
                },
            )?;
        }
        self.validate_plan(&plan)
    }

    /// Resolve a duplicate group (US-007/008/009): keep the placement at
    /// `keep_index` and schedule every other member for removal through
    /// normal Apply semantics. Lock entries are dropped only when no other
    /// placement still references them.
    pub fn resolve_duplicate_group(
        &self,
        group: &crate::inventory::DuplicateGroup,
        keep_index: usize,
    ) -> Result<ApplyPlan> {
        if !group.placement_indexes.contains(&keep_index) {
            return Err(GinoError::InvalidPlan(format!(
                "keep index {keep_index} is not a member of duplicate group `{}`",
                group.skill_name
            )));
        }
        let placements = self.inventory.placements.clone();
        if group.class == crate::inventory::DuplicateClass::AliasDuplicate
            && placements.get(keep_index).is_some_and(|placement| {
                placement.placement_kind != PlacementKind::Directory
                    && group.placement_indexes.iter().any(|index| {
                        placements
                            .get(*index)
                            .is_some_and(|member| member.placement_kind == PlacementKind::Directory)
                    })
            })
        {
            return Err(GinoError::InvalidPlan(format!(
                "alias duplicate `{}` must keep its real directory; remove the redundant symlink instead",
                group.skill_name
            )));
        }
        let removed = group
            .placement_indexes
            .iter()
            .filter(|index| **index != keep_index)
            .map(|index| {
                placements.get(*index).ok_or_else(|| {
                    GinoError::InvalidPlan(format!(
                        "duplicate group `{}` references missing placement index {index}",
                        group.skill_name
                    ))
                })
            })
            .collect::<Result<Vec<_>>>()?;
        let mut plan = self.remove(&removed)?;
        plan.warnings.push(format!(
            "Kept placement for `{}` at index {keep_index}; removed {} duplicate(s)",
            group.skill_name,
            removed.len()
        ));
        self.validate_plan(&plan)
    }

    pub fn attach_source(
        &self,
        placement: &SkillPlacement,
        source: &SkillSource,
        source_dir: impl Into<PathBuf>,
        lock: (&Path, LockScope),
    ) -> Result<ApplyPlan> {
        let source_dir = source_dir.into();
        let source_metadata = parse_skill_metadata(&source_dir)?;
        if source_metadata.name != placement.name {
            return Err(GinoError::InvalidPlan(format!(
                "source Skill `{}` does not match placement `{}`",
                source_metadata.name, placement.name
            )));
        }
        let source_hash = skill_folder_hash(&source_dir)?;
        let mut plan = ApplyPlan::new(self.inventory.generation, self.declared_roots.clone());
        plan.declared_roots.push(source_dir.clone());
        if placement.content_hash.as_deref() != Some(source_hash.as_str()) {
            plan.blockers.push(format!(
                "Local content for `{}` differs from the selected source; choose Keep Local or Use Upstream",
                placement.name
            ));
        }
        let entry = Box::new(
            source.lock_entry_for(scope_hash_for(source_hash, &source_dir, lock.1)?, lock.1),
        );
        plan = self.with_lock_edit(
            plan,
            LockEdit::Upsert {
                path: lock.0.to_path_buf(),
                scope: lock.1,
                skill_name: placement.name.clone(),
                entry,
            },
        )?;
        let id = plan.changes.len() as u64 + 1;
        plan.changes.push(PendingChange {
            id,
            action: PlanAction::AttachSource,
            skill_name: placement.name.clone(),
            source: Some(source_dir),
            destination: placement.path.clone(),
            mode: None,
            summary: format!("Attach source to {}", placement.name),
            unavailable_reason: None,
            restore_origin: None,
        });
        self.validate_plan(&plan)
    }

    pub fn move_placement(
        &self,
        placement: &SkillPlacement,
        destination: impl Into<PathBuf>,
        mode: InstallMode,
    ) -> Result<ApplyPlan> {
        self.copy_or_move(placement, destination.into(), mode, PlanAction::Move)
    }

    pub fn move_placement_with_lock(
        &self,
        placement: &SkillPlacement,
        destination: impl Into<PathBuf>,
        mode: InstallMode,
        target_lock: Option<&LockReference>,
    ) -> Result<ApplyPlan> {
        let mut plan = self.copy_or_move(placement, destination.into(), mode, PlanAction::Move)?;
        let Some(target_lock) = target_lock else {
            return Ok(plan);
        };
        let source_lock = placement.lock_file.as_ref().zip(placement.lock_scope);
        let same_lock = source_lock
            .is_some_and(|(path, scope)| path == &target_lock.path && scope == target_lock.scope);
        if !same_lock {
            if let Some((path, scope)) = source_lock {
                let still_referenced = self.inventory.placements.iter().any(|other| {
                    other.path != placement.path
                        && other.name == placement.name
                        && other.lock_file.as_ref() == Some(path)
                        && other.lock_scope == Some(scope)
                });
                if !still_referenced {
                    append_lock_edits(
                        &mut plan,
                        vec![LockEdit::Remove {
                            path: path.clone(),
                            scope,
                            skill_name: placement.name.clone(),
                        }],
                    )?;
                }
            }
            if let Some(entry) = &placement.lock_entry {
                append_lock_edits(
                    &mut plan,
                    vec![LockEdit::Upsert {
                        path: target_lock.path.clone(),
                        scope: target_lock.scope,
                        skill_name: placement.name.clone(),
                        entry: Box::new(entry.clone()),
                    }],
                )?;
            }
        }
        if let Some(parent) = target_lock.path.parent() {
            plan.declared_roots.push(parent.to_path_buf());
        }
        if let Some((path, _)) = source_lock {
            if let Some(parent) = path.parent() {
                plan.declared_roots.push(parent.to_path_buf());
            }
        }
        self.validate_plan(&plan)
    }

    pub fn relink(
        &self,
        placement: &SkillPlacement,
        destination: impl Into<PathBuf>,
    ) -> Result<ApplyPlan> {
        self.copy_or_move(
            placement,
            destination.into(),
            InstallMode::Link,
            PlanAction::Relink,
        )
    }

    fn copy_or_move(
        &self,
        placement: &SkillPlacement,
        destination: PathBuf,
        mode: InstallMode,
        action: PlanAction,
    ) -> Result<ApplyPlan> {
        let mut plan = ApplyPlan::new(self.inventory.generation, self.declared_roots.clone());
        let id = 1;
        plan.changes.push(PendingChange {
            id,
            action,
            skill_name: placement.name.clone(),
            source: Some(placement.path.clone()),
            destination: destination.clone(),
            mode: Some(mode),
            summary: format!("{action:?} {} to {}", placement.name, destination.display()),
            unavailable_reason: None,
            restore_origin: None,
        });
        plan.operations.push(FileOperation {
            id,
            action,
            skill_name: placement.name.clone(),
            source: Some(placement.path.clone()),
            destination,
            kind: if action == PlanAction::Move {
                OperationKind::MoveTree { overwrite: false }
            } else {
                match mode {
                    InstallMode::Copy => OperationKind::CopyTree { overwrite: false },
                    InstallMode::Link => OperationKind::LinkTree { overwrite: false },
                }
            },
        });
        self.validate_plan(&plan)
    }

    fn with_lock_edit(&self, mut plan: ApplyPlan, edit: LockEdit) -> Result<ApplyPlan> {
        if let Some(parent) = edit.path().parent() {
            plan.declared_roots.push(parent.to_path_buf());
        }
        append_lock_edits(&mut plan, vec![edit])?;
        Ok(plan)
    }

    fn finish_lock_edits(&self, plan: &mut ApplyPlan, edits: Vec<LockEdit>) -> Result<()> {
        for edit in &edits {
            if let Some(parent) = edit.path().parent() {
                plan.declared_roots.push(parent.to_path_buf());
            }
        }
        append_lock_edits(plan, edits)?;
        Ok(())
    }

    fn validate_plan(&self, plan: &ApplyPlan) -> Result<ApplyPlan> {
        let mut plan = plan.clone();
        for operation in &plan.operations {
            if matches!(
                operation.kind,
                OperationKind::CopyTree { overwrite: false }
                    | OperationKind::LinkTree { overwrite: false }
                    | OperationKind::MoveTree { overwrite: false }
            ) && path_present(&operation.destination)
            {
                plan.blockers.push(format!(
                    "Destination already exists for Skill `{}`: {}",
                    operation.skill_name,
                    operation.destination.display()
                ));
            }
        }
        validate_paths(&plan)?;
        Ok(plan)
    }
}

#[derive(Clone, Debug)]
enum LockEdit {
    Upsert {
        path: PathBuf,
        scope: LockScope,
        skill_name: String,
        entry: Box<SkillLockEntry>,
    },
    Remove {
        path: PathBuf,
        scope: LockScope,
        skill_name: String,
    },
}

impl LockEdit {
    fn path(&self) -> &Path {
        match self {
            Self::Upsert { path, .. } | Self::Remove { path, .. } => path,
        }
    }

    fn skill_name(&self) -> &str {
        match self {
            Self::Upsert { skill_name, .. } | Self::Remove { skill_name, .. } => skill_name,
        }
    }
}

/// Choose the content hash that matches the lock scope. Global locks use the
/// deterministic local proxy; project locks use the scope-limited `computedHash`.
fn scope_hash_for(global_hash: String, source_dir: &Path, scope: LockScope) -> Result<String> {
    Ok(match scope {
        LockScope::Global => global_hash,
        LockScope::Project => project_computed_hash(source_dir)?,
    })
}

struct PendingLockWrite {
    path: PathBuf,
    bytes: Vec<u8>,
}

fn lock_edits_operation(edits: &[LockEdit]) -> Result<Option<PendingLockWrite>> {
    let first = edits
        .first()
        .ok_or_else(|| GinoError::InvalidPlan("empty lock edit group".to_owned()))?;
    let (path, scope) = match first {
        LockEdit::Upsert { path, scope, .. } | LockEdit::Remove { path, scope, .. } => {
            (path, *scope)
        }
    };
    let original = path
        .exists()
        .then(|| fs::read(path).map_err(|source| io_error(path, source)))
        .transpose()?;
    let mut lock = read_lock_file(path, scope)?;
    for edit in edits {
        match edit {
            LockEdit::Upsert {
                skill_name, entry, ..
            } => lock.set_skill(skill_name.clone(), (**entry).clone()),
            LockEdit::Remove { skill_name, .. } => {
                lock.remove_skill(skill_name);
            }
        }
    }
    lock.normalize_for_scope(scope);
    let bytes = lock.to_bytes_for_scope(path, scope)?;
    if original.as_deref() == Some(bytes.as_slice()) {
        return Ok(None);
    }
    Ok(Some(PendingLockWrite {
        path: path.clone(),
        bytes,
    }))
}

fn append_lock_edits(plan: &mut ApplyPlan, edits: Vec<LockEdit>) -> Result<()> {
    let mut by_path: BTreeMap<PathBuf, Vec<LockEdit>> = BTreeMap::new();
    for edit in edits {
        by_path
            .entry(edit.path().to_path_buf())
            .or_default()
            .push(edit);
    }
    for (_, edits) in by_path {
        let Some(operation) = lock_edits_operation(&edits)? else {
            continue;
        };
        let id = plan.operations.len() as u64 + 1;
        let skill_name = edits
            .first()
            .map(LockEdit::skill_name)
            .ok_or_else(|| GinoError::InvalidPlan("lock edit group is empty".to_owned()))?
            .to_owned();
        let path = operation.path;
        plan.operations.push(FileOperation {
            id,
            action: PlanAction::Metadata,
            skill_name: skill_name.clone(),
            source: None,
            destination: path.clone(),
            kind: OperationKind::WriteFile {
                bytes: operation.bytes,
            },
        });
        plan.changes.push(PendingChange {
            id,
            action: PlanAction::Metadata,
            skill_name: skill_name.clone(),
            source: None,
            destination: path,
            mode: None,
            summary: format!("Update lockfile for {}", skill_name),
            unavailable_reason: None,
            restore_origin: None,
        });
    }
    Ok(())
}

fn merge_plans(destination: &mut ApplyPlan, source: ApplyPlan) {
    destination.declared_roots.extend(source.declared_roots);
    destination.warnings.extend(source.warnings);
    destination.blockers.extend(source.blockers);
    for change in source.changes {
        let id = destination.changes.len() as u64 + 1;
        let mut change = change;
        change.id = id;
        destination.changes.push(change);
    }
    for operation in source.operations {
        let id = destination.operations.len() as u64 + 1;
        let mut operation = operation;
        operation.id = id;
        destination.operations.push(operation);
    }
}

fn validate_paths(plan: &ApplyPlan) -> Result<()> {
    for operation in &plan.operations {
        for path in operation.paths() {
            if !path_allowed(path, &plan.declared_roots)? {
                return Err(GinoError::UnsafePath {
                    path: path.to_path_buf(),
                    reason: "operation is outside the explicitly declared workspace/source roots"
                        .to_owned(),
                });
            }
        }
    }
    Ok(())
}

fn path_allowed(path: &Path, roots: &[PathBuf]) -> Result<bool> {
    let candidate = security_path(path)?;
    roots
        .iter()
        .map(|root| security_path(root).map(|root| candidate.starts_with(root)))
        .collect::<Result<Vec<_>>>()
        .map(|allowed| allowed.into_iter().any(|allowed| allowed))
}

fn path_present(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok()
}

fn security_path(path: &Path) -> Result<PathBuf> {
    // A path that exists on disk (or is a symlink) can usually be canonicalized
    // directly. A broken symlink is the exception: `symlink_metadata` succeeds
    // (the link itself exists) but `canonicalize` fails (the target is gone).
    // In that case fall through to the ancestor-walk below, treating the
    // dangling link name as a "missing" suffix on top of its parent.
    if fs::symlink_metadata(path).is_ok() && fs::metadata(path).is_ok() {
        return fs::canonicalize(path).map_err(|source| io_error(path, source));
    }

    // A destination may not exist yet, or is a broken symlink. Resolve its
    // nearest existing ancestor before appending the missing suffix so `..`
    // and symlinked parents cannot escape the declared root during the
    // containment check.
    let mut missing = Vec::new();
    let mut existing = path;
    loop {
        // `metadata` (not `symlink_metadata`) follows symlinks, so a broken
        // symlink reports NotFound here and we walk up to its parent.
        match fs::metadata(existing) {
            Ok(_) => break,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(io_error(existing, error)),
        }
        if let Some(name) = existing.file_name() {
            missing.push(name.to_owned());
        }
        let Some(parent) = existing.parent() else {
            return Err(GinoError::UnsafePath {
                path: path.to_path_buf(),
                reason: "path has no existing ancestor".to_owned(),
            });
        };
        existing = parent;
    }
    let mut resolved = fs::canonicalize(existing).map_err(|source| io_error(existing, source))?;
    for component in missing.iter().rev() {
        resolved.push(component);
    }
    Ok(resolved)
}

/// Session-only plan collection. The collection stores the complete immutable
/// plans exactly as the Planner verified them — including `blockers`,
/// `warnings` and `declared_roots` — so Apply re-evaluates the same constraints
/// that the review showed. Each added plan is atomic: removing one contained
/// change removes the whole plan, so a lockfile write can never be applied
/// without the file operations it guards (or vice versa).
#[derive(Clone, Debug, Default)]
pub struct PendingChanges {
    next_id: u64,
    plans: Vec<ApplyPlan>,
}

impl PendingChanges {
    pub fn add_plan(&mut self, plan: &ApplyPlan) -> Vec<u64> {
        let mut plan = plan.clone();
        let mut id_map: BTreeMap<u64, u64> = BTreeMap::new();
        for change in &mut plan.changes {
            self.next_id = self.next_id.saturating_add(1);
            id_map.insert(change.id, self.next_id);
            change.id = self.next_id;
        }
        let mut ids = id_map.values().copied().collect::<Vec<_>>();
        ids.sort_unstable();
        for operation in &mut plan.operations {
            match id_map.get(&operation.id) {
                Some(replacement) => operation.id = *replacement,
                None => {
                    self.next_id = self.next_id.saturating_add(1);
                    operation.id = self.next_id;
                }
            }
        }
        self.plans.push(plan);
        ids
    }

    pub fn items(&self) -> Vec<PendingChange> {
        self.plans
            .iter()
            .flat_map(|plan| plan.changes.iter().cloned())
            .collect()
    }

    pub fn operations(&self) -> Vec<FileOperation> {
        self.plans
            .iter()
            .flat_map(|plan| plan.operations.iter().cloned())
            .collect()
    }

    pub fn blockers(&self) -> Vec<String> {
        self.plans
            .iter()
            .flat_map(|plan| plan.blockers.iter().cloned())
            .collect()
    }

    pub fn warnings(&self) -> Vec<String> {
        self.plans
            .iter()
            .flat_map(|plan| plan.warnings.iter().cloned())
            .collect()
    }

    pub fn is_empty(&self) -> bool {
        self.plans.iter().all(|plan| plan.changes.is_empty())
    }

    /// Ids that share an atomic plan with `id`. Deselecting one excludes every
    /// sibling so a lockfile write cannot apply without its file operations.
    pub fn sibling_ids(&self, id: u64) -> Vec<u64> {
        self.plans
            .iter()
            .find(|plan| plan.changes.iter().any(|change| change.id == id))
            .map(|plan| plan.changes.iter().map(|change| change.id).collect())
            .unwrap_or_else(|| vec![id])
    }

    /// Remove the complete atomic plan that contains `id`, preventing a split
    /// between file operations and their lockfile writes.
    pub fn remove(&mut self, id: u64) -> bool {
        let before = self.plans.len();
        self.plans
            .retain(|plan| !plan.changes.iter().any(|change| change.id == id));
        before != self.plans.len()
    }

    pub fn clear(&mut self) {
        self.plans.clear();
    }

    /// Rebuild an ApplyPlan preserving every plan's declared roots, blockers
    /// and warnings. The passed `declared_roots` are unioned with the roots
    /// each plan declared (which may include external source directories).
    pub fn plan(&self, inventory_generation: u64, declared_roots: Vec<PathBuf>) -> ApplyPlan {
        let mut merged = ApplyPlan::new(inventory_generation, declared_roots);
        for plan in &self.plans {
            merged.declared_roots.extend(plan.declared_roots.clone());
            merged.warnings.extend(plan.warnings.iter().cloned());
            merged.blockers.extend(plan.blockers.iter().cloned());
            merged.changes.extend(plan.changes.iter().cloned());
            merged.operations.extend(plan.operations.iter().cloned());
        }
        merged
    }

    pub fn mark_unavailable(&mut self) {
        for plan in &mut self.plans {
            for item in &mut plan.changes {
                let missing = item
                    .source
                    .as_ref()
                    .filter(|source| !path_present(source))
                    .cloned()
                    .or_else(|| {
                        (item.source.is_none()
                            && matches!(item.action, PlanAction::Remove)
                            && !path_present(&item.destination))
                        .then(|| item.destination.clone())
                    });
                item.unavailable_reason = missing.map(|path| {
                    format!(
                        "Missing after refresh: required path does not exist: {}",
                        path.display()
                    )
                });
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::fs;

    use tempfile::tempdir;

    use super::*;
    use crate::inventory::{InventoryScanner, Workspace, WorkspaceKind};

    fn write_skill(root: &Path, name: &str) -> PathBuf {
        let skill = root.join(name);
        fs::create_dir_all(&skill).expect("skill dir");
        fs::write(
            skill.join("SKILL.md"),
            format!("---\nname: {name}\ndescription: demo\n---\nbody\n"),
        )
        .expect("skill");
        skill
    }

    #[test]
    fn remove_is_only_a_plan_until_apply() {
        let root = tempdir().expect("root");
        let skill = write_skill(root.path(), "demo");
        let workspace = Workspace::new("custom", "Custom", WorkspaceKind::Custom, root.path());
        let inventory = InventoryScanner::new(&[workspace]).scan(1).expect("scan");
        let planner = Planner::new(&inventory, vec![root.path().to_path_buf()]);
        let plan = planner.remove(&[&inventory.placements[0]]).expect("plan");

        assert!(skill.exists());
        assert_eq!(plan.operation_count(), 1);
        assert!(plan.can_apply());
    }

    #[test]
    fn install_plan_reports_destination_collision_without_mutating_it() {
        let source_root = tempdir().expect("source");
        let destination_root = tempdir().expect("destination");
        let source = write_skill(source_root.path(), "demo");
        let destination = destination_root.path().join("demo");
        write_skill(destination_root.path(), "demo");
        let inventory = Inventory::empty();
        let planner = Planner::new(&inventory, vec![destination_root.path().to_path_buf()]);

        let plan = planner
            .install_local(&source, &destination, InstallMode::Copy, None)
            .expect("plan");
        assert!(!plan.can_apply());
        assert!(plan.blockers[0].contains("Destination already exists"));
        assert!(destination.join("SKILL.md").exists());
    }

    #[test]
    fn preset_add_missing_and_match_exactly_are_pending_only() {
        let target_root = tempdir().expect("target");
        let source_root = tempdir().expect("sources");
        write_skill(target_root.path(), "old");
        let wanted = write_skill(source_root.path(), "wanted");
        let target = Workspace::new(
            "custom",
            "Custom",
            WorkspaceKind::Custom,
            target_root.path(),
        );
        let inventory = InventoryScanner::new(std::slice::from_ref(&target))
            .scan(1)
            .expect("scan");
        let planner = Planner::new(
            &inventory,
            vec![
                target_root.path().to_path_buf(),
                source_root.path().to_path_buf(),
            ],
        );
        let preset = Preset {
            id: "preset".to_owned(),
            name: "Core".to_owned(),
            skills: BTreeSet::from(["wanted".to_owned()]),
            mode: PresetMode::MatchExactly,
        };
        let plan = planner
            .apply_preset(
                &preset,
                &target,
                &BTreeMap::from([("wanted".to_owned(), wanted)]),
            )
            .expect("preset plan");

        assert!(target_root.path().join("old").exists());
        assert!(!target_root.path().join("wanted").exists());
        assert!(
            plan.changes
                .iter()
                .any(|change| change.action == PlanAction::Install)
        );
        assert!(
            plan.changes
                .iter()
                .any(|change| change.action == PlanAction::Remove)
        );
    }

    #[test]
    fn removing_multiple_skills_coalesces_one_lockfile_write_and_preserves_unknown_data() {
        let root = tempdir().expect("root");
        write_skill(root.path(), "first");
        write_skill(root.path(), "second");
        let lock_path = root.path().join(".skill-lock.json");
        fs::write(
            &lock_path,
            r#"{
              "version": 3,
              "skills": {
                "first": {"source": "owner/repo", "sourceType": "github", "future": true},
                "second": {"source": "owner/repo", "sourceType": "github"}
              },
              "futureTopLevel": "kept"
            }"#,
        )
        .expect("lockfile");
        let workspace = Workspace::new("global", "Global", WorkspaceKind::Global, root.path())
            .with_lock(&lock_path, crate::protocol::LockScope::Global);
        let inventory = InventoryScanner::new(&[workspace]).scan(1).expect("scan");
        let planner = Planner::new(&inventory, vec![root.path().to_path_buf()]);
        let plan = planner
            .remove(&[&inventory.placements[0], &inventory.placements[1]])
            .expect("plan");

        assert_eq!(
            plan.operations
                .iter()
                .filter(|operation| matches!(operation.kind, OperationKind::WriteFile { .. }))
                .count(),
            1
        );
        assert!(root.path().join("first").exists());
        assert!(root.path().join("second").exists());
    }

    #[test]
    fn session_pending_changes_keep_executable_operations_until_removed_or_cleared() {
        let root = tempdir().expect("root");
        let skill = write_skill(root.path(), "demo");
        let workspace = Workspace::new("custom", "Custom", WorkspaceKind::Custom, root.path());
        let inventory = InventoryScanner::new(&[workspace]).scan(1).expect("scan");
        let planner = Planner::new(&inventory, vec![root.path().to_path_buf()]);
        let plan = planner.remove(&[&inventory.placements[0]]).expect("plan");
        let mut pending = PendingChanges::default();
        let ids = pending.add_plan(&plan);

        assert_eq!(ids.len(), 1);
        assert_eq!(pending.items().len(), 1);
        assert_eq!(pending.operations().len(), 1);
        assert!(skill.exists());
        pending.remove(ids[0]);
        assert!(pending.operations().is_empty());
    }

    #[test]
    fn pending_changes_preserve_blockers_warnings_and_declared_roots() {
        let mut plan = ApplyPlan::new(1, vec![PathBuf::from("/external/source")]);
        plan.warnings.push("preview warning".to_owned());
        plan.blockers.push("destination collision".to_owned());
        plan.changes.push(PendingChange {
            id: 1,
            action: PlanAction::Install,
            skill_name: "demo".to_owned(),
            source: Some(PathBuf::from("/external/source")),
            destination: PathBuf::from("/workspace/demo"),
            mode: Some(InstallMode::Copy),
            summary: "install demo".to_owned(),
            unavailable_reason: None,
            restore_origin: None,
        });
        plan.operations.push(FileOperation {
            id: 1,
            action: PlanAction::Install,
            skill_name: "demo".to_owned(),
            source: Some(PathBuf::from("/external/source")),
            destination: PathBuf::from("/workspace/demo"),
            kind: OperationKind::CopyTree { overwrite: true },
        });

        let mut pending = PendingChanges::default();
        pending.add_plan(&plan);
        let rebuilt = pending.plan(7, vec![PathBuf::from("/workspace")]);

        assert_eq!(rebuilt.inventory_generation, 7);
        assert!(
            rebuilt
                .declared_roots
                .iter()
                .any(|root| root == &PathBuf::from("/external/source"))
        );
        assert!(
            rebuilt
                .declared_roots
                .iter()
                .any(|root| root == &PathBuf::from("/workspace"))
        );
        assert!(
            rebuilt
                .blockers
                .iter()
                .any(|b| b.contains("destination collision"))
        );
        assert!(
            rebuilt
                .warnings
                .iter()
                .any(|w| w.contains("preview warning"))
        );
        assert_eq!(rebuilt.changes.len(), 1);
    }

    #[test]
    fn removing_one_change_removes_the_whole_atomic_plan() {
        // A plan pairs a file operation with its lockfile write. Deselecting any
        // one contained change must remove the lock write too, so the filesystem
        // and lock cannot diverge.
        let mut plan = ApplyPlan::new(1, vec![]);
        plan.changes.push(PendingChange {
            id: 1,
            action: PlanAction::Install,
            skill_name: "demo".to_owned(),
            source: Some(PathBuf::from("/src/demo")),
            destination: PathBuf::from("/ws/demo"),
            mode: Some(InstallMode::Copy),
            summary: "install demo".to_owned(),
            unavailable_reason: None,
            restore_origin: None,
        });
        plan.operations.push(FileOperation {
            id: 1,
            action: PlanAction::Install,
            skill_name: "demo".to_owned(),
            source: Some(PathBuf::from("/src/demo")),
            destination: PathBuf::from("/ws/demo"),
            kind: OperationKind::CopyTree { overwrite: false },
        });
        plan.changes.push(PendingChange {
            id: 2,
            action: PlanAction::Metadata,
            skill_name: "demo".to_owned(),
            source: None,
            destination: PathBuf::from("/ws/.skill-lock.json"),
            mode: None,
            summary: "update lockfile".to_owned(),
            unavailable_reason: None,
            restore_origin: None,
        });
        plan.operations.push(FileOperation {
            id: 2,
            action: PlanAction::Metadata,
            skill_name: "demo".to_owned(),
            source: None,
            destination: PathBuf::from("/ws/.skill-lock.json"),
            kind: OperationKind::WriteFile {
                bytes: b"{}".to_vec(),
            },
        });

        let mut pending = PendingChanges::default();
        let ids = pending.add_plan(&plan);
        assert_eq!(ids.len(), 2);

        pending.remove(ids[0]);
        assert!(pending.is_empty());
        assert!(pending.operations().is_empty());
        assert!(pending.blockers().is_empty());
    }

    #[test]
    fn attach_source_only_writes_compatible_metadata() {
        let root = tempdir().expect("root");
        let source_root = tempdir().expect("source");
        let skill = write_skill(root.path(), "demo");
        let source = write_skill(source_root.path(), "demo");
        let workspace = Workspace::new("custom", "Custom", WorkspaceKind::Custom, root.path());
        let lock_path = root.path().join(".skill-lock.json");
        let inventory = InventoryScanner::new(&[workspace]).scan(1).expect("scan");
        let planner = Planner::new(
            &inventory,
            vec![root.path().to_path_buf(), source_root.path().to_path_buf()],
        );
        let source_identity = SkillSource::parse(&source.to_string_lossy()).expect("source");

        let plan = planner
            .attach_source(
                &inventory.placements[0],
                &source_identity,
                source,
                (&lock_path, LockScope::Global),
            )
            .expect("attach plan");

        assert!(skill.exists());
        assert!(plan.can_apply());
        assert!(
            plan.changes
                .iter()
                .any(|change| change.action == PlanAction::AttachSource)
        );
        assert!(
            plan.operations
                .iter()
                .all(|operation| matches!(operation.kind, OperationKind::WriteFile { .. }))
        );
    }

    #[test]
    fn keep_both_installs_upstream_separately_and_preserves_local() {
        let root = tempdir().expect("root");
        let local = write_skill(root.path(), "demo");
        let upstream_root = tempdir().expect("upstream");
        let upstream = write_skill(upstream_root.path(), "demo");
        let alias = root.path().join("demo-upstream");
        let inventory = Inventory::empty();
        let planner = Planner::new(&inventory, vec![root.path().to_path_buf()]);

        let plan = planner
            .keep_both(&upstream, &alias, None)
            .expect("keep both plan");

        assert!(!alias.exists(), "nothing written before Apply");
        assert_eq!(
            fs::read_to_string(local.join("SKILL.md")).expect("local"),
            "---\nname: demo\ndescription: demo\n---\nbody\n"
        );
        assert!(plan.can_apply());
        assert!(
            plan.changes
                .iter()
                .all(|change| change.action == PlanAction::Install)
        );
        assert!(plan.changes[0].summary.contains("Keep Both"));
        assert!(plan.operations.iter().all(|operation| matches!(
            operation.kind,
            OperationKind::CopyTree { overwrite: false }
        )));
    }

    #[test]
    fn restore_snapshot_produces_pending_overwrite_changes_with_origin() {
        let root = tempdir().expect("root");
        let skill = write_skill(root.path(), "demo");
        let inventory = InventoryScanner::new(&[Workspace::new(
            "custom",
            "Custom",
            WorkspaceKind::Custom,
            root.path(),
        )])
        .scan(1)
        .expect("scan");
        let planner = Planner::new(&inventory, vec![root.path().to_path_buf()]);
        let snapshot_root = tempdir().expect("snapshots");
        let store = crate::executor::SnapshotStore::new(snapshot_root.path(), 10);
        let snapshot = store
            .create([skill.join("SKILL.md"), skill.join("missing.txt")])
            .expect("snapshot");

        let plan = planner.restore_snapshot(&snapshot).expect("restore plan");
        assert_eq!(plan.operation_count(), 2);
        assert!(plan.can_apply());
        for change in &plan.changes {
            assert_eq!(change.action, PlanAction::Restore);
            let origin = change.restore_origin.as_deref().expect("restore origin");
            assert!(origin.starts_with("snapshot "));
        }
        assert!(plan.operations.iter().any(|operation| {
            matches!(operation.kind, OperationKind::CopyTree { overwrite: true })
                && operation.destination == skill.join("SKILL.md")
        }));
        assert!(plan.operations.iter().any(|operation| {
            matches!(operation.kind, OperationKind::RemovePath)
                && operation.destination == skill.join("missing.txt")
        }));
    }

    #[test]
    fn restore_from_dir_plans_overwrite_and_carries_commit_origin() {
        let root = tempdir().expect("root");
        write_skill(root.path(), "demo");
        let restored_root = tempdir().expect("restored");
        let restored = write_skill(restored_root.path(), "demo");
        let inventory = Inventory::empty();
        let planner = Planner::new(&inventory, vec![root.path().to_path_buf()]);

        let plan = planner
            .restore_from_dir(
                &restored,
                root.path().join("demo"),
                None,
                None,
                "commit abc123".to_owned(),
            )
            .expect("restore plan");

        assert_eq!(plan.operation_count(), 1);
        assert!(plan.can_apply());
        assert_eq!(plan.changes[0].action, PlanAction::Restore);
        assert_eq!(
            plan.changes[0].restore_origin.as_deref(),
            Some("commit abc123")
        );
        assert!(matches!(
            plan.operations[0].kind,
            OperationKind::CopyTree { overwrite: true }
        ));
    }

    #[test]
    fn resolve_duplicate_group_keeps_one_and_removes_the_rest() {
        let first_root = tempdir().expect("first");
        let second_root = tempdir().expect("second");
        write_skill(first_root.path(), "demo");
        write_skill(second_root.path(), "demo");
        let workspaces = [
            Workspace::new("first", "First", WorkspaceKind::Custom, first_root.path()),
            Workspace::new(
                "second",
                "Second",
                WorkspaceKind::Custom,
                second_root.path(),
            ),
        ];
        let inventory = InventoryScanner::new(&workspaces).scan(1).expect("scan");
        let planner = Planner::new(
            &inventory,
            vec![
                first_root.path().to_path_buf(),
                second_root.path().to_path_buf(),
            ],
        );
        let group = inventory
            .duplicate_groups
            .iter()
            .find(|group| group.skill_name == "demo")
            .expect("duplicate group");
        assert!(group.placement_indexes.len() >= 2);

        let plan = planner
            .resolve_duplicate_group(group, group.placement_indexes[0])
            .expect("resolve plan");

        assert!(plan.can_apply());
        assert_eq!(
            plan.changes.len(),
            group.placement_indexes.len() - 1,
            "only the non-kept members are removed"
        );
        assert!(
            plan.changes
                .iter()
                .all(|change| change.action == PlanAction::Remove)
        );
        assert!(
            plan.warnings
                .iter()
                .any(|warning| warning.contains("Kept placement"))
        );
        assert!(
            planner.resolve_duplicate_group(group, usize::MAX).is_err(),
            "a non-member keep index is rejected"
        );
    }

    #[cfg(unix)]
    #[test]
    fn cleanup_broken_symlinks_plans_removal_of_dangling_links() {
        use std::os::unix::fs::symlink;

        let root = tempdir().expect("root");
        write_skill(root.path(), "real");
        // Broken symlink: target does not exist.
        symlink(
            root.path().join("nonexistent"),
            root.path().join("dangling"),
        )
        .expect("broken link");
        let workspace = Workspace::new("custom", "Custom", WorkspaceKind::Custom, root.path());
        let inventory = InventoryScanner::new(&[workspace]).scan(1).expect("scan");
        let planner = Planner::new(&inventory, vec![root.path().to_path_buf()]);

        let plan = planner.cleanup_broken_symlinks().expect("cleanup plan");

        assert!(plan.can_apply());
        assert_eq!(plan.operation_count(), 1);
        assert_eq!(plan.changes[0].action, PlanAction::Remove);
        assert!(plan.changes[0].summary.contains("broken symlink"));
        assert!(plan.changes[0].summary.contains("dangling"));
        assert!(plan.changes[0].summary.contains("nonexistent"));
        // Nothing is written until Apply — the broken link is still on disk.
        assert!(fs::symlink_metadata(root.path().join("dangling")).is_ok());
    }

    #[test]
    fn cleanup_broken_symlinks_warns_when_none_found() {
        let root = tempdir().expect("root");
        write_skill(root.path(), "demo");
        let workspace = Workspace::new("custom", "Custom", WorkspaceKind::Custom, root.path());
        let inventory = InventoryScanner::new(&[workspace]).scan(1).expect("scan");
        let planner = Planner::new(&inventory, vec![root.path().to_path_buf()]);

        let plan = planner.cleanup_broken_symlinks().expect("cleanup plan");

        assert!(plan.changes.is_empty());
        assert!(
            plan.warnings
                .iter()
                .any(|w| w.contains("No broken symlinks"))
        );
    }

    #[cfg(unix)]
    #[test]
    fn cleanup_alias_duplicates_only_removes_the_symlink_entry() {
        use std::os::unix::fs::symlink;

        let root = tempdir().expect("root");
        let real = write_skill(root.path(), "demo");
        let alias = root.path().join("alias");
        symlink(&real, &alias).expect("alias");
        let workspace = Workspace::new("custom", "Custom", WorkspaceKind::Custom, root.path());
        let inventory = InventoryScanner::new(&[workspace]).scan(1).expect("scan");
        let planner = Planner::new(&inventory, vec![root.path().to_path_buf()]);

        let plan = planner
            .cleanup_alias_duplicates()
            .expect("cleanup alias plan");

        assert!(plan.can_apply());
        assert_eq!(plan.operation_count(), 1);
        assert_eq!(plan.changes[0].action, PlanAction::Remove);
        assert_eq!(plan.changes[0].destination, alias);
        assert!(real.join("SKILL.md").is_file());
        assert!(fs::symlink_metadata(root.path().join("alias")).is_ok());
    }

    #[cfg(unix)]
    #[test]
    fn alias_group_cannot_keep_the_symlink_member() {
        use std::os::unix::fs::symlink;

        let root = tempdir().expect("root");
        let real = write_skill(root.path(), "demo");
        symlink(&real, root.path().join("alias")).expect("alias");
        let workspace = Workspace::new("custom", "Custom", WorkspaceKind::Custom, root.path());
        let inventory = InventoryScanner::new(&[workspace]).scan(1).expect("scan");
        let planner = Planner::new(&inventory, vec![root.path().to_path_buf()]);
        let group = inventory
            .duplicate_groups
            .iter()
            .find(|group| group.class == crate::inventory::DuplicateClass::AliasDuplicate)
            .expect("alias group");
        let symlink_index = group
            .placement_indexes
            .iter()
            .copied()
            .find(|index| inventory.placements[*index].placement_kind == PlacementKind::Symlink)
            .expect("symlink member");

        assert!(
            planner
                .resolve_duplicate_group(group, symlink_index)
                .is_err()
        );
    }
}
