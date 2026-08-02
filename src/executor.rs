use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use chrono::Utc;
use serde::{Deserialize, Serialize};

use crate::error::{GinoError, Result, io_error};
use crate::git::{GitRepository, PushMode, PushStatus};
use crate::inventory::{InventoryScanner, Workspace};
use crate::metadata::BackupMetadata;
use crate::planner::{ApplyPlan, FileOperation, OperationKind};
use crate::protocol::write_atomic;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Snapshot {
    pub id: String,
    pub created_at: String,
    pub root: PathBuf,
    pub entries: Vec<SnapshotEntry>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SnapshotEntry {
    pub path: PathBuf,
    pub state: SnapshotState,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub enum SnapshotState {
    Missing,
    File { payload: PathBuf },
    Directory { payload: PathBuf },
    Symlink { target: PathBuf },
}

#[derive(Clone, Debug)]
pub struct SnapshotStore {
    root: PathBuf,
    retention: usize,
}

impl SnapshotStore {
    pub fn new(root: impl Into<PathBuf>, retention: usize) -> Self {
        Self {
            root: root.into(),
            retention,
        }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn create(&self, paths: impl IntoIterator<Item = PathBuf>) -> Result<Snapshot> {
        fs::create_dir_all(&self.root).map_err(|source| io_error(&self.root, source))?;
        let id = snapshot_id()?;
        let snapshot_root = self.root.join(&id);
        fs::create_dir(&snapshot_root).map_err(|source| io_error(&snapshot_root, source))?;
        let payload_root = snapshot_root.join("payload");
        fs::create_dir(&payload_root).map_err(|source| io_error(&payload_root, source))?;

        let mut unique_paths = BTreeSet::new();
        for path in paths {
            unique_paths.insert(path);
        }
        let mut entries = Vec::new();
        let result = (|| {
            for (index, path) in unique_paths.into_iter().enumerate() {
                let state = capture_state(&path, &payload_root.join(index.to_string()))?;
                entries.push(SnapshotEntry { path, state });
            }
            let snapshot = Snapshot {
                id: id.clone(),
                created_at: Utc::now().to_rfc3339(),
                root: snapshot_root.clone(),
                entries,
            };
            let manifest = snapshot_root.join("manifest.json");
            let bytes = serde_json::to_vec_pretty(&snapshot)
                .map_err(|source| crate::error::json_error(&manifest, source))?;
            write_atomic(&manifest, &bytes)?;
            Ok(snapshot)
        })();
        if result.is_err() {
            let _ = fs::remove_dir_all(&snapshot_root);
        }
        result
    }

    pub fn restore(&self, snapshot: &Snapshot) -> Result<()> {
        let mut entries = snapshot.entries.clone();
        entries.sort_by(|left, right| {
            // Restore children before parents so removing a parent path cannot
            // erase a later entry that must recreate a nested path.
            right
                .path
                .components()
                .count()
                .cmp(&left.path.components().count())
        });
        for entry in entries {
            remove_path(&entry.path)?;
            match entry.state {
                SnapshotState::Missing => {}
                SnapshotState::File { payload } => {
                    if let Some(parent) = entry.path.parent() {
                        fs::create_dir_all(parent).map_err(|source| io_error(parent, source))?;
                    }
                    fs::copy(&payload, &entry.path)
                        .map_err(|source| io_error(&entry.path, source))?;
                }
                SnapshotState::Directory { payload } => {
                    copy_tree_preserving(&payload, &entry.path)?;
                }
                SnapshotState::Symlink { target } => {
                    create_symlink(&target, &entry.path)?;
                }
            }
        }
        Ok(())
    }

    pub fn prune_after_success(&self) -> Result<()> {
        fs::create_dir_all(&self.root).map_err(|source| io_error(&self.root, source))?;
        let mut snapshots = Vec::new();
        for entry in fs::read_dir(&self.root).map_err(|source| io_error(&self.root, source))? {
            let entry = entry.map_err(|source| io_error(&self.root, source))?;
            let path = entry.path();
            if path.is_dir() {
                snapshots.push(path);
            }
        }
        snapshots.sort();
        let remove_count = snapshots.len().saturating_sub(self.retention);
        for path in snapshots.into_iter().take(remove_count) {
            fs::remove_dir_all(&path).map_err(|source| io_error(&path, source))?;
        }
        Ok(())
    }
}

#[derive(Clone, Debug)]
pub struct ApplyExecutor {
    snapshots: SnapshotStore,
    git: Option<GitRepository>,
    push_mode: PushMode,
    workspaces: Vec<Workspace>,
    backup_metadata: BackupMetadata,
}

#[derive(Clone, Debug)]
pub struct ApplyResult {
    pub snapshot_id: String,
    pub commit_id: Option<String>,
    pub push_status: PushStatus,
}

impl ApplyExecutor {
    pub fn new(snapshot_root: impl Into<PathBuf>, snapshot_retention: usize) -> Self {
        Self {
            snapshots: SnapshotStore::new(snapshot_root, snapshot_retention),
            git: None,
            push_mode: PushMode::CommitLocally,
            workspaces: Vec::new(),
            backup_metadata: BackupMetadata::default(),
        }
    }

    pub fn with_git(mut self, repository: GitRepository, push_mode: PushMode) -> Self {
        self.git = Some(repository);
        self.push_mode = push_mode;
        self
    }

    pub fn with_workspaces(mut self, workspaces: Vec<Workspace>) -> Self {
        self.workspaces = workspaces;
        self
    }

    pub fn with_backup_metadata(mut self, metadata: BackupMetadata) -> Self {
        self.backup_metadata = metadata;
        self
    }

    pub fn snapshot_store(&self) -> &SnapshotStore {
        &self.snapshots
    }

    pub fn apply(&self, plan: &ApplyPlan) -> Result<ApplyResult> {
        plan.validate()?;
        let snapshot_paths = snapshot_paths(plan);
        let snapshot = self.snapshots.create(snapshot_paths)?;
        for operation in &plan.operations {
            if let Err(error) = execute_operation(operation) {
                return self.rollback_after_failure(&snapshot, error);
            }
        }
        for operation in &plan.operations {
            if let Err(error) = verify_operation(operation) {
                return self.rollback_after_failure(&snapshot, error);
            }
        }

        let (commit_id, push_status) = if let Some(repository) = &self.git {
            let post_inventory = match InventoryScanner::new(&self.workspaces)
                .scan(plan.inventory_generation.saturating_add(1))
            {
                Ok(inventory) => inventory,
                Err(error) => return self.rollback_after_failure(&snapshot, error),
            };
            if let Err(error) = repository
                .materialize_inventory_with_metadata(&post_inventory, &self.backup_metadata)
            {
                return self.rollback_after_failure(&snapshot, error);
            }
            match repository.commit(
                &format!("Apply {} changes", plan.operation_count()),
                self.push_mode,
            ) {
                Ok(result) => (Some(result.0), result.1),
                Err(error) => return self.rollback_git_and_files(&snapshot, repository, error),
            }
        } else {
            (None, PushStatus::NotConfigured)
        };
        self.snapshots.prune_after_success()?;
        Ok(ApplyResult {
            snapshot_id: snapshot.id,
            commit_id,
            push_status,
        })
    }

    fn rollback_after_failure(&self, snapshot: &Snapshot, error: GinoError) -> Result<ApplyResult> {
        match self.snapshots.restore(snapshot) {
            Ok(()) => Err(error),
            Err(rollback) => Err(GinoError::InvalidPlan(format!(
                "{}; rollback failed: {}",
                error, rollback
            ))),
        }
    }

    fn rollback_git_and_files(
        &self,
        snapshot: &Snapshot,
        repository: &GitRepository,
        error: GinoError,
    ) -> Result<ApplyResult> {
        let rollback = self.snapshots.restore(snapshot);
        let git_cleanup = repository.discard_materialized_changes();
        match (rollback, git_cleanup) {
            (Ok(()), Ok(())) => Err(error),
            (Err(rollback), Ok(())) => Err(GinoError::InvalidPlan(format!(
                "{}; rollback failed: {}",
                error, rollback
            ))),
            (Ok(()), Err(cleanup)) => Err(GinoError::InvalidPlan(format!(
                "{}; Git cleanup failed: {}",
                error, cleanup
            ))),
            (Err(rollback), Err(cleanup)) => Err(GinoError::InvalidPlan(format!(
                "{}; rollback failed: {}; Git cleanup failed: {}",
                error, rollback, cleanup
            ))),
        }
    }
}

fn snapshot_id() -> Result<String> {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .map_err(|source| GinoError::Clock {
            cause: source.to_string(),
        })?;
    Ok(format!("snapshot-{nanos}"))
}

fn snapshot_paths(plan: &ApplyPlan) -> Vec<PathBuf> {
    let mut paths = Vec::new();
    for operation in &plan.operations {
        match &operation.kind {
            OperationKind::CopyTree { .. } | OperationKind::LinkTree { .. } => {
                paths.push(operation.destination.clone());
            }
            OperationKind::MoveTree { .. } => {
                if let Some(source) = &operation.source {
                    paths.push(source.clone());
                }
                paths.push(operation.destination.clone());
            }
            OperationKind::RemovePath | OperationKind::WriteFile { .. } => {
                paths.push(operation.destination.clone());
            }
        }
    }
    paths
}

fn execute_operation(operation: &FileOperation) -> Result<()> {
    match &operation.kind {
        OperationKind::CopyTree { overwrite } => {
            let source = required_source(operation)?;
            ensure_source(operation)?;
            if path_present(&operation.destination) && !*overwrite {
                return operation_error(operation, "Destination collision".to_owned());
            }
            copy_tree_dereferenced(source, &operation.destination, *overwrite)
                .map_err(|error| operation_failure(operation, error.to_string()))
        }
        OperationKind::LinkTree { overwrite } => {
            let source = required_source(operation)?;
            ensure_source(operation)?;
            if path_present(&operation.destination) && !*overwrite {
                return operation_error(operation, "Destination collision".to_owned());
            }
            if *overwrite {
                remove_path(&operation.destination)
                    .map_err(|error| operation_failure(operation, error.to_string()))?;
            }
            if let Some(parent) = operation.destination.parent() {
                fs::create_dir_all(parent)
                    .map_err(|error| operation_failure(operation, error.to_string()))?;
            }
            create_symlink(source, &operation.destination)
                .map_err(|error| operation_failure(operation, error.to_string()))
        }
        OperationKind::MoveTree { overwrite } => {
            let source = required_source(operation)?;
            ensure_source(operation)?;
            if path_present(&operation.destination) && !*overwrite {
                return operation_error(operation, "Destination collision".to_owned());
            }
            if *overwrite {
                remove_path(&operation.destination)
                    .map_err(|error| operation_failure(operation, error.to_string()))?;
            }
            if let Some(parent) = operation.destination.parent() {
                fs::create_dir_all(parent)
                    .map_err(|error| operation_failure(operation, error.to_string()))?;
            }
            fs::rename(source, &operation.destination)
                .map_err(|error| operation_failure(operation, error.to_string()))
        }
        OperationKind::RemovePath => remove_path(&operation.destination)
            .map_err(|error| operation_failure(operation, error.to_string())),
        OperationKind::WriteFile { bytes } => write_atomic(&operation.destination, bytes)
            .map_err(|error| operation_failure(operation, error.to_string())),
    }
}

fn ensure_source(operation: &FileOperation) -> Result<()> {
    let source = required_source(operation)?;
    if let Err(error) = fs::metadata(source) {
        return operation_error(operation, format!("Source skill is missing: {error}"));
    }
    Ok(())
}

fn required_source(operation: &FileOperation) -> Result<&Path> {
    operation.source.as_deref().ok_or_else(|| {
        GinoError::InvalidPlan(format!(
            "{:?} operation for `{}` requires a source path",
            operation.action, operation.skill_name
        ))
    })
}

fn verify_operation(operation: &FileOperation) -> Result<()> {
    match &operation.kind {
        OperationKind::RemovePath => {
            if operation.destination.exists()
                || fs::symlink_metadata(&operation.destination).is_ok()
            {
                return operation_error(operation, "expected path to be removed".to_owned());
            }
        }
        OperationKind::WriteFile { bytes } => {
            let actual = fs::read(&operation.destination)
                .map_err(|error| operation_failure(operation, error.to_string()))?;
            if actual != *bytes {
                return operation_error(operation, "written file did not verify".to_owned());
            }
        }
        OperationKind::CopyTree { .. }
        | OperationKind::LinkTree { .. }
        | OperationKind::MoveTree { .. } => {
            if !path_present(&operation.destination) {
                return operation_error(operation, "expected destination is missing".to_owned());
            }
        }
    }
    Ok(())
}

fn operation_error(operation: &FileOperation, cause: String) -> Result<()> {
    Err(operation_failure(operation, cause))
}

fn operation_failure(operation: &FileOperation, cause: String) -> GinoError {
    GinoError::Apply {
        skill: operation.skill_name.clone(),
        action: format!("{:?}", operation.action),
        source_path: operation
            .source
            .clone()
            .unwrap_or_else(|| operation.destination.clone()),
        destination_path: operation.destination.clone(),
        cause,
    }
}

fn capture_state(path: &Path, payload: &Path) -> Result<SnapshotState> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(SnapshotState::Missing);
        }
        Err(error) => return Err(io_error(path, error)),
    };
    if metadata.file_type().is_symlink() {
        let target = fs::read_link(path).map_err(|source| io_error(path, source))?;
        return Ok(SnapshotState::Symlink { target });
    }
    if metadata.is_dir() {
        copy_tree_preserving(path, payload)?;
        Ok(SnapshotState::Directory {
            payload: payload.to_path_buf(),
        })
    } else {
        if let Some(parent) = payload.parent() {
            fs::create_dir_all(parent).map_err(|source| io_error(parent, source))?;
        }
        fs::copy(path, payload).map_err(|source| io_error(payload, source))?;
        Ok(SnapshotState::File {
            payload: payload.to_path_buf(),
        })
    }
}

fn copy_tree_dereferenced(source: &Path, destination: &Path, overwrite: bool) -> Result<()> {
    if path_present(destination) && !overwrite {
        return Err(GinoError::Apply {
            skill: source.display().to_string(),
            action: "Copy".to_owned(),
            source_path: source.to_path_buf(),
            destination_path: destination.to_path_buf(),
            cause: "Destination collision".to_owned(),
        });
    }
    if path_present(destination) {
        remove_path(destination)?;
    }
    let metadata = fs::metadata(source).map_err(|source_error| io_error(source, source_error))?;
    if metadata.is_dir() {
        fs::create_dir_all(destination)
            .map_err(|source_error| io_error(destination, source_error))?;
        let entries =
            fs::read_dir(source).map_err(|source_error| io_error(source, source_error))?;
        for entry in entries {
            let entry = entry.map_err(|source_error| io_error(source, source_error))?;
            copy_tree_dereferenced(&entry.path(), &destination.join(entry.file_name()), false)?;
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

fn copy_tree_preserving(source: &Path, destination: &Path) -> Result<()> {
    let metadata =
        fs::symlink_metadata(source).map_err(|source_error| io_error(source, source_error))?;
    if metadata.file_type().is_symlink() {
        let target =
            fs::read_link(source).map_err(|source_error| io_error(source, source_error))?;
        create_symlink(&target, destination)?;
    } else if metadata.is_dir() {
        fs::create_dir_all(destination)
            .map_err(|source_error| io_error(destination, source_error))?;
        for entry in fs::read_dir(source).map_err(|source_error| io_error(source, source_error))? {
            let entry = entry.map_err(|source_error| io_error(source, source_error))?;
            copy_tree_preserving(&entry.path(), &destination.join(entry.file_name()))?;
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

fn path_present(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok()
}

fn create_symlink(target: &Path, link: &Path) -> Result<()> {
    if let Some(parent) = link.parent() {
        fs::create_dir_all(parent).map_err(|source| io_error(parent, source))?;
    }
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(target, link).map_err(|source| io_error(link, source))
    }
    #[cfg(windows)]
    {
        std::os::windows::fs::symlink_dir(target, link).map_err(|source| io_error(link, source))
    }
}

#[cfg(test)]
mod tests {
    use std::fs;

    use tempfile::tempdir;

    use super::*;
    use crate::inventory::{InventoryScanner, Workspace, WorkspaceKind};
    use crate::planner::{InstallMode, PlanAction, Planner};

    fn write_skill(root: &Path, name: &str, body: &str) -> PathBuf {
        let skill = root.join(name);
        fs::create_dir_all(&skill).expect("skill dir");
        fs::write(
            skill.join("SKILL.md"),
            format!("---\nname: {name}\ndescription: demo\n---\n{body}\n"),
        )
        .expect("skill file");
        skill
    }

    #[test]
    fn apply_remove_creates_snapshot_and_removes_skill() {
        let root = tempdir().expect("root");
        let skill = write_skill(root.path(), "demo", "body");
        let workspace = Workspace::new("custom", "Custom", WorkspaceKind::Custom, root.path());
        let inventory = InventoryScanner::new(&[workspace.clone()])
            .scan(1)
            .expect("scan");
        let planner = Planner::new(&inventory, vec![root.path().to_path_buf()]);
        let plan = planner.remove(&[&inventory.placements[0]]).expect("plan");
        let snapshot_root = tempdir().expect("snapshots");
        let executor = ApplyExecutor::new(snapshot_root.path(), 10);

        let result = executor.apply(&plan).expect("apply");
        assert!(!skill.exists());
        assert!(snapshot_root.path().join(result.snapshot_id).exists());
    }

    #[test]
    fn failure_after_first_operation_restores_everything_and_creates_no_commit() {
        let root = tempdir().expect("root");
        let first = write_skill(root.path(), "first", "one");
        let source = tempdir().expect("source");
        let second_source = write_skill(source.path(), "second", "two");
        let workspace = Workspace::new("custom", "Custom", WorkspaceKind::Custom, root.path());
        let inventory = InventoryScanner::new(&[workspace]).scan(1).expect("scan");
        let planner = Planner::new(
            &inventory,
            vec![root.path().to_path_buf(), source.path().to_path_buf()],
        );
        let mut plan = planner
            .remove(&[&inventory.placements[0]])
            .expect("first plan");
        let second_destination = root.path().join("second");
        plan.changes.push(crate::planner::PendingChange {
            id: 2,
            action: PlanAction::Install,
            skill_name: "second".to_owned(),
            source: Some(second_source.clone()),
            destination: second_destination.clone(),
            mode: Some(InstallMode::Copy),
            summary: "install second".to_owned(),
            unavailable_reason: None,
        });
        plan.operations.push(FileOperation {
            id: 2,
            action: PlanAction::Install,
            skill_name: "second".to_owned(),
            source: Some(root.path().join("does-not-exist")),
            destination: second_destination,
            kind: OperationKind::CopyTree { overwrite: false },
        });
        let snapshot_root = tempdir().expect("snapshots");
        let executor = ApplyExecutor::new(snapshot_root.path(), 10);

        let error = executor.apply(&plan).expect_err("apply should fail");
        assert!(error.to_string().contains("Source skill is missing"));
        assert!(first.exists());
        assert!(!root.path().join("second").exists());
    }

    #[test]
    fn successful_apply_materializes_backup_and_creates_one_commit() {
        let root = tempdir().expect("root");
        let skill = write_skill(root.path(), "demo", "body");
        let workspace = Workspace::new("custom", "Custom", WorkspaceKind::Custom, root.path());
        let inventory = InventoryScanner::new(std::slice::from_ref(&workspace))
            .scan(1)
            .expect("scan");
        let planner = Planner::new(&inventory, vec![root.path().to_path_buf()]);
        let plan = planner.remove(&[&inventory.placements[0]]).expect("plan");
        let snapshot_root = tempdir().expect("snapshots");
        let backup_root = tempdir().expect("backup");
        let repository = GitRepository::open_or_init(backup_root.path()).expect("git init");
        let executor = ApplyExecutor::new(snapshot_root.path(), 10)
            .with_git(repository.clone(), PushMode::CommitLocally)
            .with_workspaces(vec![workspace]);

        let result = executor.apply(&plan).expect("apply");
        assert!(!skill.exists());
        assert!(result.commit_id.is_some());
        assert!(backup_root.path().join("manifest.json").exists());
        assert_eq!(repository.commit_count().expect("commit count"), 1);
    }

    #[test]
    fn push_failure_keeps_the_local_commit_and_applied_filesystem_state() {
        let root = tempdir().expect("root");
        let skill = write_skill(root.path(), "demo", "body");
        let workspace = Workspace::new("custom", "Custom", WorkspaceKind::Custom, root.path());
        let inventory = InventoryScanner::new(std::slice::from_ref(&workspace))
            .scan(1)
            .expect("scan");
        let planner = Planner::new(&inventory, vec![root.path().to_path_buf()]);
        let plan = planner.remove(&[&inventory.placements[0]]).expect("plan");
        let snapshot_root = tempdir().expect("snapshots");
        let backup_root = tempdir().expect("backup");
        let unrelated = backup_root.path().join("user-notes.txt");
        fs::write(&unrelated, "keep me").expect("unrelated backup file");
        let repository = GitRepository::open_or_init(backup_root.path()).expect("git init");
        let executor = ApplyExecutor::new(snapshot_root.path(), 10)
            .with_git(repository, PushMode::CommitAndPush)
            .with_workspaces(vec![workspace]);

        let result = executor.apply(&plan).expect("local apply succeeds");
        assert!(!skill.exists());
        assert!(result.commit_id.is_some());
        assert!(matches!(result.push_status, PushStatus::NotPushed(_)));
        assert_eq!(
            fs::read_to_string(unrelated).expect("unrelated file"),
            "keep me"
        );
    }
}
