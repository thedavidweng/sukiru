use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use chrono::Utc;
use serde::{Deserialize, Serialize};

use crate::error::{GinoError, Result, io_error};
use crate::git::{GitRepository, PushMode, PushStatus};
use crate::inventory::{InventoryScanner, Workspace};
use crate::metadata::{BackupMetadata, MetadataStore};
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

    /// Load a snapshot by id for user-initiated restore (§12.3). The id is
    /// validated as a single path component so a malicious id cannot escape
    /// the snapshot root.
    pub fn load(&self, id: &str) -> Result<Snapshot> {
        if id.is_empty()
            || id == "."
            || id == ".."
            || id.contains(std::path::MAIN_SEPARATOR)
            || id.contains('/')
        {
            return Err(GinoError::InvalidPlan(format!(
                "snapshot id `{id}` is not a single component"
            )));
        }
        let snapshot_root = self.root.join(id);
        let manifest = snapshot_root.join("manifest.json");
        let bytes = fs::read(&manifest).map_err(|source| io_error(&manifest, source))?;
        let snapshot: Snapshot = serde_json::from_slice(&bytes)
            .map_err(|source| crate::error::json_error(&manifest, source))?;
        if snapshot.id != id || snapshot.root != snapshot_root {
            return Err(GinoError::InvalidPlan(format!(
                "snapshot manifest at `{}` does not match requested id `{id}`",
                manifest.display()
            )));
        }
        Ok(snapshot)
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

/// Executes one plan transaction. Created per Apply and never cloned or
/// reused across transactions: it owns the metadata store connection.
#[derive(Debug)]
pub struct ApplyExecutor {
    snapshots: SnapshotStore,
    git: Option<GitRepository>,
    push_mode: PushMode,
    workspaces: Vec<Workspace>,
    backup_metadata: BackupMetadata,
    metadata: Option<MetadataStore>,
}

#[derive(Clone, Debug)]
pub struct ApplyResult {
    pub snapshot_id: String,
    pub commit_id: Option<String>,
    pub push_status: PushStatus,
}

/// Outcome of one Apply transaction, separate from the returned `Result` so
/// the Activity record can distinguish a clean rollback from a failure.
enum ApplyOutcome {
    Success(ApplyResult),
    Failure { error: GinoError, rolled_back: bool },
}

impl ApplyExecutor {
    pub fn new(snapshot_root: impl Into<PathBuf>, snapshot_retention: usize) -> Self {
        Self {
            snapshots: SnapshotStore::new(snapshot_root, snapshot_retention),
            git: None,
            push_mode: PushMode::CommitLocally,
            workspaces: Vec::new(),
            backup_metadata: BackupMetadata::default(),
            metadata: None,
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

    /// Attach the metadata store so every Apply writes an Activity record
    /// (§21): action, outcome, commit id, restore origin where relevant.
    pub fn with_metadata(mut self, store: MetadataStore) -> Self {
        self.metadata = Some(store);
        self
    }

    pub fn snapshot_store(&self) -> &SnapshotStore {
        &self.snapshots
    }

    pub fn apply(&self, plan: &ApplyPlan) -> Result<ApplyResult> {
        let outcome = self.execute(plan);
        self.record_activity(plan, &outcome);
        match outcome {
            ApplyOutcome::Success(result) => Ok(result),
            ApplyOutcome::Failure { error, .. } => Err(error),
        }
    }

    fn execute(&self, plan: &ApplyPlan) -> ApplyOutcome {
        if let Err(error) = plan.validate() {
            return ApplyOutcome::Failure {
                error,
                rolled_back: false,
            };
        }
        let snapshot_paths = snapshot_paths(plan);
        let snapshot = match self.snapshots.create(snapshot_paths) {
            Ok(snapshot) => snapshot,
            Err(error) => {
                return ApplyOutcome::Failure {
                    error,
                    rolled_back: false,
                };
            }
        };
        for operation in &plan.operations {
            if let Err(error) = execute_operation(operation) {
                return self.failure_after_rollback(&snapshot, error);
            }
        }
        for operation in &plan.operations {
            if let Err(error) = verify_operation(operation) {
                return self.failure_after_rollback(&snapshot, error);
            }
        }

        if let Some(repository) = &self.git {
            let post_inventory = match InventoryScanner::new(&self.workspaces)
                .scan(plan.inventory_generation.saturating_add(1))
            {
                Ok(inventory) => inventory,
                Err(error) => return self.failure_after_rollback(&snapshot, error),
            };
            if let Err(error) = repository
                .materialize_inventory_with_metadata(&post_inventory, &self.backup_metadata)
            {
                return self.failure_after_rollback(&snapshot, error);
            }
            match repository.commit(
                &format!("Apply {} changes", plan.operation_count()),
                self.push_mode,
            ) {
                Ok(result) => {
                    if let Err(error) = self.snapshots.prune_after_success() {
                        return self.failure_with_git_cleanup(&snapshot, repository, error);
                    }
                    return ApplyOutcome::Success(ApplyResult {
                        snapshot_id: snapshot.id,
                        commit_id: Some(result.0),
                        push_status: result.1,
                    });
                }
                Err(error) => return self.failure_with_git_cleanup(&snapshot, repository, error),
            }
        }
        if let Err(error) = self.snapshots.prune_after_success() {
            return self.failure_after_rollback(&snapshot, error);
        }
        ApplyOutcome::Success(ApplyResult {
            snapshot_id: snapshot.id,
            commit_id: None,
            push_status: PushStatus::NotConfigured,
        })
    }

    fn failure_after_rollback(&self, snapshot: &Snapshot, error: GinoError) -> ApplyOutcome {
        let rolled_back = match self.snapshots.restore(snapshot) {
            Ok(()) => true,
            Err(rollback) => {
                return ApplyOutcome::Failure {
                    error: GinoError::InvalidPlan(format!("{error}; rollback failed: {rollback}")),
                    rolled_back: false,
                };
            }
        };
        ApplyOutcome::Failure { error, rolled_back }
    }

    fn failure_with_git_cleanup(
        &self,
        snapshot: &Snapshot,
        repository: &GitRepository,
        error: GinoError,
    ) -> ApplyOutcome {
        let rolled_back = self.snapshots.restore(snapshot).is_ok();
        let cleaned = repository.discard_materialized_changes().is_ok();
        let error = match (rolled_back, cleaned) {
            (true, true) => error,
            (false, true) => GinoError::InvalidPlan(format!("{error}; rollback failed")),
            (true, false) => GinoError::InvalidPlan(format!("{error}; Git cleanup failed")),
            (false, false) => {
                GinoError::InvalidPlan(format!("{error}; rollback failed; Git cleanup failed"))
            }
        };
        ApplyOutcome::Failure { error, rolled_back }
    }

    fn record_activity(&self, plan: &ApplyPlan, outcome: &ApplyOutcome) {
        let Some(store) = &self.metadata else {
            return;
        };
        let restore_origins = plan
            .changes
            .iter()
            .filter_map(|change| change.restore_origin.clone())
            .collect::<BTreeSet<_>>();
        let restore_origin = if restore_origins.is_empty() {
            None
        } else {
            Some(restore_origins.into_iter().collect::<Vec<_>>().join("; "))
        };
        let actions = plan
            .changes
            .iter()
            .map(|change| format!("{:?} {}", change.action, change.skill_name))
            .collect::<Vec<_>>()
            .join(", ");
        match outcome {
            ApplyOutcome::Success(result) => {
                let _ = store.record_activity(
                    "Apply",
                    match result.push_status {
                        PushStatus::Pushed => "success_pushed",
                        PushStatus::NotPushed(_) => "success_not_pushed",
                        _ => "success",
                    },
                    result.commit_id.as_deref(),
                    &actions,
                    restore_origin.as_deref(),
                );
            }
            ApplyOutcome::Failure {
                error, rolled_back, ..
            } => {
                let _ = store.record_activity(
                    "Apply",
                    if *rolled_back { "rollback" } else { "failed" },
                    None,
                    &format!("{actions}; {error}"),
                    restore_origin.as_deref(),
                );
            }
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
            move_tree_with_fallback(source, &operation.destination)
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
        OperationKind::CopyTree { .. } => {
            let source = required_source(operation)?;
            if !trees_identical(source, &operation.destination)? {
                return operation_error(operation, "copied content did not verify".to_owned());
            }
        }
        OperationKind::LinkTree { .. } => {
            let metadata = fs::symlink_metadata(&operation.destination)
                .map_err(|error| operation_failure(operation, error.to_string()))?;
            if !metadata.file_type().is_symlink() {
                return operation_error(operation, "expected a symlink".to_owned());
            }
            let target = fs::read_link(&operation.destination)
                .map_err(|error| operation_failure(operation, error.to_string()))?;
            let source = required_source(operation)?;
            if !link_targets_equivalent(&target, source)
                && fs::canonicalize(&target).ok() != fs::canonicalize(source).ok()
            {
                return operation_error(operation, "link target did not verify".to_owned());
            }
        }
        OperationKind::MoveTree { .. } => {
            let source = required_source(operation)?;
            // A successful move removes the source and materializes the
            // destination; both invariants must hold after the transaction.
            if path_present(source) {
                return operation_error(operation, "move source still present".to_owned());
            }
            if !path_present(&operation.destination) {
                return operation_error(
                    operation,
                    "expected move destination is missing".to_owned(),
                );
            }
        }
    }
    Ok(())
}

fn link_targets_equivalent(target: &Path, source: &Path) -> bool {
    // Equivalent both when the raw target string matches the source and when
    // they resolve to the same canonical location.
    target == source || fs::canonicalize(target).ok() == fs::canonicalize(source).ok()
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

/// Move a tree, preferring `rename` but falling back to copy-verify-delete for
/// cross-device moves or any case where rename is not possible. The fallback
/// removes the source only after the destination is byte-for-byte identical.
fn move_tree_with_fallback(source: &Path, destination: &Path) -> Result<()> {
    if fs::rename(source, destination).is_ok() {
        return Ok(());
    }
    // Cross-device (or otherwise refused) rename: copy, verify, then delete
    // the source so the observable state is identical to a real move.
    copy_tree_dereferenced(source, destination, true)?;
    if !trees_identical(source, destination)? {
        return Err(GinoError::Apply {
            skill: source.display().to_string(),
            action: "Move".to_owned(),
            source_path: source.to_path_buf(),
            destination_path: destination.to_path_buf(),
            cause: "fallback copy did not verify".to_owned(),
        });
    }
    remove_path(source)
}

/// Compare two trees (directories, files and symlinks) byte-for-byte and
/// structurally, following no symlinks inside.
fn trees_identical(left: &Path, right: &Path) -> Result<bool> {
    let left_meta = fs::symlink_metadata(left).map_err(|source| io_error(left, source))?;
    let right_meta = fs::symlink_metadata(right).map_err(|source| io_error(right, source))?;
    let left_kind = left_meta.file_type();
    let right_kind = right_meta.file_type();
    if left_kind.is_symlink() || right_kind.is_symlink() {
        // A symlink never equals a regular tree in this comparison.
        return Ok(false);
    }
    if left_meta.is_dir() != right_meta.is_dir() {
        return Ok(false);
    }
    if left_meta.is_dir() {
        let mut left_children = fs::read_dir(left)
            .map_err(|source| io_error(left, source))?
            .map(|entry| {
                entry
                    .map(|entry| entry.file_name())
                    .map_err(|e| io_error(left, e))
            })
            .collect::<Result<Vec<_>>>()?;
        let mut right_children = fs::read_dir(right)
            .map_err(|source| io_error(right, source))?
            .map(|entry| {
                entry
                    .map(|entry| entry.file_name())
                    .map_err(|e| io_error(right, e))
            })
            .collect::<Result<Vec<_>>>()?;
        left_children.sort();
        right_children.sort();
        if left_children != right_children {
            return Ok(false);
        }
        for name in left_children {
            if !trees_identical(&left.join(&name), &right.join(&name))? {
                return Ok(false);
            }
        }
        Ok(true)
    } else {
        let left_bytes = fs::read(left).map_err(|source| io_error(left, source))?;
        let right_bytes = fs::read(right).map_err(|source| io_error(right, source))?;
        Ok(left_bytes == right_bytes)
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
        let inventory = InventoryScanner::new(std::slice::from_ref(&workspace))
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
            restore_origin: None,
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

    #[test]
    fn snapshot_load_round_trips_and_rejects_path_traversal() {
        let root = tempdir().expect("root");
        let skill = write_skill(root.path(), "demo", "body");
        let snapshot_root = tempdir().expect("snapshots");
        let store = SnapshotStore::new(snapshot_root.path(), 10);
        let snapshot = store.create([skill.join("SKILL.md")]).expect("snapshot");

        let loaded = store.load(&snapshot.id).expect("load snapshot");
        assert_eq!(loaded.id, snapshot.id);
        assert_eq!(loaded.entries.len(), 1);
        assert!(store.load("..").is_err());
        assert!(store.load("../outside").is_err());
        assert!(store.load("does-not-exist").is_err());
    }

    #[test]
    fn apply_records_activity_with_commit_and_restore_origin() {
        use crate::metadata::MetadataStore;

        let root = tempdir().expect("root");
        write_skill(root.path(), "demo", "body");
        let workspace = Workspace::new("custom", "Custom", WorkspaceKind::Custom, root.path());
        let inventory = InventoryScanner::new(std::slice::from_ref(&workspace))
            .scan(1)
            .expect("scan");
        let planner = Planner::new(&inventory, vec![root.path().to_path_buf()]);
        let mut plan = planner.remove(&[&inventory.placements[0]]).expect("plan");
        plan.changes[0].restore_origin = Some("snapshot snap-1".to_owned());
        let snapshot_root = tempdir().expect("snapshots");
        let backup_root = tempdir().expect("backup");
        let repository = GitRepository::open_or_init(backup_root.path()).expect("git init");
        let metadata_root = tempdir().expect("metadata");
        let store = MetadataStore::open(metadata_root.path().join("state.sqlite")).expect("store");
        let executor = ApplyExecutor::new(snapshot_root.path(), 10)
            .with_git(repository, PushMode::CommitLocally)
            .with_workspaces(vec![workspace])
            .with_metadata(store);

        let result = executor.apply(&plan).expect("apply");

        let activity = MetadataStore::open(metadata_root.path().join("state.sqlite"))
            .expect("reopen store")
            .activity()
            .expect("activity");
        assert_eq!(activity.len(), 1);
        assert_eq!(activity[0].action, "Apply");
        assert_eq!(activity[0].outcome, "success");
        assert_eq!(
            activity[0].commit_id.as_deref(),
            result.commit_id.as_deref()
        );
        assert_eq!(
            activity[0].restore_origin.as_deref(),
            Some("snapshot snap-1")
        );
        assert!(activity[0].details.contains("Remove demo"));
    }

    #[test]
    fn failed_apply_records_rollback_outcome() {
        use crate::metadata::MetadataStore;

        let root = tempdir().expect("root");
        let skill = write_skill(root.path(), "demo", "body");
        let workspace = Workspace::new("custom", "Custom", WorkspaceKind::Custom, root.path());
        let inventory = InventoryScanner::new(std::slice::from_ref(&workspace))
            .scan(1)
            .expect("scan");
        let planner = Planner::new(&inventory, vec![root.path().to_path_buf()]);
        let mut plan = planner.remove(&[&inventory.placements[0]]).expect("plan");
        plan.operations[0] = FileOperation {
            id: plan.operations[0].id,
            action: PlanAction::Install,
            skill_name: "demo".to_owned(),
            source: Some(root.path().join("does-not-exist")),
            destination: root.path().join("new-place"),
            kind: OperationKind::CopyTree { overwrite: false },
        };
        let snapshot_root = tempdir().expect("snapshots");
        let metadata_root = tempdir().expect("metadata");
        let store = MetadataStore::open(metadata_root.path().join("state.sqlite")).expect("store");
        let executor = ApplyExecutor::new(snapshot_root.path(), 10).with_metadata(store);

        executor.apply(&plan).expect_err("apply must fail");
        assert!(skill.exists(), "rollback restored the skill");

        let activity = MetadataStore::open(metadata_root.path().join("state.sqlite"))
            .expect("reopen store")
            .activity()
            .expect("activity");
        assert_eq!(activity.len(), 1);
        assert_eq!(activity[0].outcome, "rollback");
    }
}
