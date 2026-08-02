use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::error::{GinoError, Result, io_error};
use crate::inventory::{Inventory, SkillPlacement, Workspace};
use crate::protocol::{
    LockScope, SkillLockEntry, SkillSource, parse_skill_metadata, read_lock_file, skill_folder_hash,
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
    pub fn is_write(&self) -> bool {
        true
    }

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
        for operation in &self.operations {
            for path in operation.paths() {
                if !path_allowed(path, &self.declared_roots) {
                    return Err(GinoError::UnsafePath {
                        path: path.to_path_buf(),
                        reason:
                            "operation is outside the explicitly declared workspace/source roots"
                                .to_owned(),
                    });
                }
            }
        }
        Ok(())
    }

    pub fn mark_missing_inputs(&mut self) {
        for change in &mut self.changes {
            let missing = change
                .source
                .as_ref()
                .filter(|source| !source.exists())
                .cloned()
                .or_else(|| {
                    (change.source.is_none()
                        && matches!(change.action, PlanAction::Remove)
                        && !change.destination.exists())
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
            if let (Some(lock_path), Some(scope)) = (&placement.lock_file, placement.lock_scope) {
                lock_edits.push(LockEdit::Remove {
                    path: lock_path.clone(),
                    scope,
                    skill_name: placement.name.clone(),
                });
            }
        }
        self.finish_lock_edits(&mut plan, lock_edits)?;
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
        let destination = destination.into();
        let metadata = parse_skill_metadata(&source_dir)?;
        let source_hash = skill_folder_hash(&source_dir)?;
        let source = SkillSource::parse(&source_dir.to_string_lossy())?;
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
        });
        plan.operations.push(FileOperation {
            id,
            action: PlanAction::Install,
            skill_name: metadata.name.clone(),
            source: Some(source_dir),
            destination,
            kind: match mode {
                InstallMode::Copy => OperationKind::CopyTree { overwrite: false },
                InstallMode::Link => OperationKind::LinkTree { overwrite: false },
            },
        });
        if let Some((path, scope)) = lock {
            let entry = source.lock_entry(source_hash);
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
                    entry: source.lock_entry(source_hash),
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

    pub fn move_placement(
        &self,
        placement: &SkillPlacement,
        destination: impl Into<PathBuf>,
        mode: InstallMode,
    ) -> Result<ApplyPlan> {
        self.copy_or_move(placement, destination.into(), mode, PlanAction::Move)
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
            ) && operation.destination.exists()
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
        entry: SkillLockEntry,
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
            } => lock.set_skill(skill_name.clone(), entry.clone()),
            LockEdit::Remove { skill_name, .. } => {
                lock.remove_skill(skill_name);
            }
        }
    }
    let bytes = serde_json::to_vec_pretty(&lock)
        .map_err(|source| crate::error::json_error(path, source))?;
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
            .unwrap_or("lockfile")
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
            if !path_allowed(path, &plan.declared_roots) {
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

fn path_allowed(path: &Path, roots: &[PathBuf]) -> bool {
    roots.iter().any(|root| {
        let root = security_path(root);
        let candidate = security_path(path);
        candidate.starts_with(root)
    })
}

fn security_path(path: &Path) -> PathBuf {
    if path.exists() {
        return fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    }
    let mut missing = Vec::new();
    let mut existing = path;
    while !existing.exists() {
        if let Some(name) = existing.file_name() {
            missing.push(name.to_owned());
        }
        let Some(parent) = existing.parent() else {
            return path.to_path_buf();
        };
        existing = parent;
    }
    let mut resolved = fs::canonicalize(existing).unwrap_or_else(|_| existing.to_path_buf());
    for component in missing.iter().rev() {
        resolved.push(component);
    }
    resolved
}

/// Session-only plan collection. The collection intentionally stores plans,
/// never an inferred filesystem state, so Refresh can mark only missing inputs
/// unavailable without silently changing user intent.
#[derive(Clone, Debug, Default)]
pub struct PendingChanges {
    next_id: u64,
    items: Vec<PendingChange>,
    operations: Vec<FileOperation>,
}

impl PendingChanges {
    pub fn add_plan(&mut self, plan: &ApplyPlan) -> Vec<u64> {
        let mut ids = Vec::new();
        for change in &plan.changes {
            self.next_id = self.next_id.saturating_add(1);
            let mut change = change.clone();
            let previous_id = change.id;
            change.id = self.next_id;
            ids.push(change.id);
            self.items.push(change);
            self.operations.extend(
                plan.operations
                    .iter()
                    .filter(|operation| operation.id == previous_id)
                    .cloned()
                    .map(|mut operation| {
                        operation.id = self.next_id;
                        operation
                    }),
            );
        }
        ids
    }

    pub fn items(&self) -> &[PendingChange] {
        &self.items
    }

    pub fn remove(&mut self, id: u64) -> bool {
        let before = self.items.len();
        self.items.retain(|item| item.id != id);
        self.operations.retain(|operation| operation.id != id);
        before != self.items.len()
    }

    pub fn clear(&mut self) {
        self.items.clear();
        self.operations.clear();
    }

    pub fn operations(&self) -> &[FileOperation] {
        &self.operations
    }

    pub fn plan(&self, inventory_generation: u64, declared_roots: Vec<PathBuf>) -> ApplyPlan {
        ApplyPlan {
            inventory_generation,
            declared_roots,
            changes: self.items.clone(),
            operations: self.operations.clone(),
            warnings: Vec::new(),
            blockers: Vec::new(),
        }
    }

    pub fn mark_unavailable(&mut self) {
        for item in &mut self.items {
            let missing = item
                .source
                .as_ref()
                .filter(|source| !source.exists())
                .cloned()
                .or_else(|| {
                    (item.source.is_none()
                        && matches!(item.action, PlanAction::Remove)
                        && !item.destination.exists())
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
}
