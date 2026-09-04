use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

use rusqlite::{Connection, params};
use serde::{Deserialize, Serialize};

use crate::error::{GinoError, Result};
use crate::inventory::WorkspaceKind;
use crate::planner::{InstallMode, Preset, PresetMode};
use crate::protocol::now_rfc3339;

pub const APP_VERSION: &str = env!("CARGO_PKG_VERSION");
pub const RELEASES_URL: &str = concat!(env!("CARGO_PKG_REPOSITORY"), "/releases");

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct Preferences {
    pub theme: String,
    pub text_size: String,
    pub language: String,
    pub editor: String,
    pub snapshot_retention: usize,
    pub snapshot_root: PathBuf,
    /// Opt-in local git backup (`~/.gino/backup`). Off by default: no
    /// repository is created, no commits are made, nothing is pushed. The
    /// transaction snapshot taken by every Apply is independent of this and
    /// always runs.
    pub backup_enabled: bool,
    pub backup_remote: String,
    pub push_mode: String,
    pub size_policy_bytes: u64,
    pub proxy: String,
    pub agent_order: String,
}

impl Default for Preferences {
    fn default() -> Self {
        Self {
            theme: "light".to_owned(),
            text_size: "medium".to_owned(),
            language: "en".to_owned(),
            editor: String::new(),
            snapshot_retention: 10,
            snapshot_root: default_snapshot_root(),
            backup_enabled: false,
            backup_remote: String::new(),
            push_mode: "commit_and_push".to_owned(),
            size_policy_bytes: 50 * 1024 * 1024,
            proxy: String::new(),
            agent_order: String::new(),
        }
    }
}

/// `$HOME` / `%USERPROFILE%`, or `.` when neither is set.
pub fn user_home() -> PathBuf {
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

/// Local recovery snapshots live at `~/.gino/snapshots`, never `$TMPDIR`.
pub fn default_snapshot_root() -> PathBuf {
    user_home().join(".gino").join("snapshots")
}

impl Preferences {
    pub fn commit_locally(&self) -> bool {
        self.push_mode == "commit_locally"
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct RegisteredWorkspace {
    pub id: String,
    pub display_name: String,
    pub kind: WorkspaceKind,
    pub path: PathBuf,
    pub preferred_mode: InstallMode,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ActivityRecord {
    pub id: i64,
    pub action: String,
    pub outcome: String,
    pub commit_id: Option<String>,
    pub details: String,
    pub restore_origin: Option<String>,
    pub created_at: String,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct BackupMetadata {
    pub tags: BTreeMap<String, BTreeSet<String>>,
    pub presets: Vec<Preset>,
    pub targets: Vec<LogicalTarget>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct LogicalTarget {
    pub id: String,
    pub kind: String,
    pub preferred_mode: String,
}

#[derive(Debug)]
pub struct MetadataStore {
    path: PathBuf,
    connection: Connection,
}

impl MetadataStore {
    pub fn open(path: impl Into<PathBuf>) -> Result<Self> {
        let path = path.into();
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|source| GinoError::Io {
                path: parent.to_path_buf(),
                source,
            })?;
        }
        let connection = Connection::open(&path).map_err(|error| database_error(&path, error))?;
        connection
            .execute_batch(
                "PRAGMA foreign_keys = ON;
                 CREATE TABLE IF NOT EXISTS workspaces (
                   id TEXT PRIMARY KEY,
                   display_name TEXT NOT NULL,
                   kind TEXT NOT NULL,
                   path TEXT NOT NULL,
                   preferred_mode TEXT NOT NULL
                 );
                 CREATE TABLE IF NOT EXISTS skill_tags (
                   skill_name TEXT NOT NULL,
                   tag TEXT NOT NULL,
                   PRIMARY KEY (skill_name, tag)
                 );
                 CREATE TABLE IF NOT EXISTS presets (
                   id TEXT PRIMARY KEY,
                   name TEXT NOT NULL UNIQUE,
                   mode TEXT NOT NULL
                 );
                 CREATE TABLE IF NOT EXISTS preset_skills (
                   preset_id TEXT NOT NULL REFERENCES presets(id) ON DELETE CASCADE,
                   skill_name TEXT NOT NULL,
                   PRIMARY KEY (preset_id, skill_name)
                 );
                 CREATE TABLE IF NOT EXISTS activity (
                   id INTEGER PRIMARY KEY AUTOINCREMENT,
                   action TEXT NOT NULL,
                   outcome TEXT NOT NULL,
                   commit_id TEXT,
                   details TEXT NOT NULL,
                   restore_origin TEXT,
                   created_at TEXT NOT NULL
                 );
                 CREATE TABLE IF NOT EXISTS ignored_updates (
                   skill_name TEXT NOT NULL,
                   fingerprint TEXT NOT NULL,
                   created_at TEXT NOT NULL,
                   PRIMARY KEY (skill_name, fingerprint)
                 );
                 CREATE TABLE IF NOT EXISTS ignored_duplicates (
                   skill_name TEXT NOT NULL,
                   fingerprint TEXT NOT NULL,
                   decision TEXT NOT NULL,
                   created_at TEXT NOT NULL,
                   PRIMARY KEY (skill_name, fingerprint)
                 );
                 CREATE TABLE IF NOT EXISTS settings (
                   key TEXT PRIMARY KEY,
                   value TEXT NOT NULL
                 );",
            )
            .map_err(|error| database_error(&path, error))?;
        Ok(Self { path, connection })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn save_workspace(&self, workspace: &RegisteredWorkspace) -> Result<()> {
        self.connection
            .execute(
                "INSERT INTO workspaces (id, display_name, kind, path, preferred_mode)
                 VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(id) DO UPDATE SET
                   display_name = excluded.display_name,
                   kind = excluded.kind,
                   path = excluded.path,
                   preferred_mode = excluded.preferred_mode",
                params![
                    workspace.id,
                    workspace.display_name,
                    workspace_kind_name(&workspace.kind),
                    workspace.path.to_string_lossy(),
                    install_mode_name(workspace.preferred_mode),
                ],
            )
            .map_err(|error| database_error(&self.path, error))?;
        Ok(())
    }

    pub fn remove_workspace(&self, id: &str) -> Result<bool> {
        let changed = self
            .connection
            .execute("DELETE FROM workspaces WHERE id = ?1", params![id])
            .map_err(|error| database_error(&self.path, error))?;
        Ok(changed == 1)
    }

    pub fn workspaces(&self) -> Result<Vec<RegisteredWorkspace>> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT id, display_name, kind, path, preferred_mode
                 FROM workspaces ORDER BY display_name, id",
            )
            .map_err(|error| database_error(&self.path, error))?;
        let rows = statement
            .query_map([], |row| {
                let kind: String = row.get(2)?;
                let preferred_mode: String = row.get(4)?;
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    kind,
                    PathBuf::from(row.get::<_, String>(3)?),
                    preferred_mode,
                ))
            })
            .map_err(|error| database_error(&self.path, error))?;
        rows.map(|row| {
            let (id, display_name, kind, path, preferred_mode) =
                row.map_err(|error| database_error(&self.path, error))?;
            Ok(RegisteredWorkspace {
                id,
                display_name,
                kind: parse_workspace_kind(&kind)?,
                path,
                preferred_mode: parse_install_mode(&preferred_mode)?,
            })
        })
        .collect()
    }

    pub fn set_tags(&self, skill_name: &str, tags: &BTreeSet<String>) -> Result<()> {
        let transaction = self
            .connection
            .unchecked_transaction()
            .map_err(|error| database_error(&self.path, error))?;
        transaction
            .execute(
                "DELETE FROM skill_tags WHERE skill_name = ?1",
                params![skill_name],
            )
            .map_err(|error| database_error(&self.path, error))?;
        for tag in tags {
            transaction
                .execute(
                    "INSERT INTO skill_tags (skill_name, tag) VALUES (?1, ?2)",
                    params![skill_name, tag],
                )
                .map_err(|error| database_error(&self.path, error))?;
        }
        transaction
            .commit()
            .map_err(|error| database_error(&self.path, error))
    }

    pub fn tags_for(&self, skill_name: &str) -> Result<BTreeSet<String>> {
        let mut statement = self
            .connection
            .prepare("SELECT tag FROM skill_tags WHERE skill_name = ?1 ORDER BY tag")
            .map_err(|error| database_error(&self.path, error))?;
        let rows = statement
            .query_map(params![skill_name], |row| row.get::<_, String>(0))
            .map_err(|error| database_error(&self.path, error))?;
        rows.map(|row| row.map_err(|error| database_error(&self.path, error)))
            .collect()
    }

    pub fn save_preset(&self, preset: &Preset) -> Result<()> {
        let transaction = self
            .connection
            .unchecked_transaction()
            .map_err(|error| database_error(&self.path, error))?;
        transaction
            .execute(
                "INSERT INTO presets (id, name, mode) VALUES (?1, ?2, ?3)
                 ON CONFLICT(id) DO UPDATE SET name = excluded.name, mode = excluded.mode",
                params![preset.id, preset.name, preset_mode_name(preset.mode)],
            )
            .map_err(|error| database_error(&self.path, error))?;
        transaction
            .execute(
                "DELETE FROM preset_skills WHERE preset_id = ?1",
                params![preset.id],
            )
            .map_err(|error| database_error(&self.path, error))?;
        for skill in &preset.skills {
            transaction
                .execute(
                    "INSERT INTO preset_skills (preset_id, skill_name) VALUES (?1, ?2)",
                    params![preset.id, skill],
                )
                .map_err(|error| database_error(&self.path, error))?;
        }
        transaction
            .commit()
            .map_err(|error| database_error(&self.path, error))
    }

    pub fn presets(&self) -> Result<Vec<Preset>> {
        let mut statement = self
            .connection
            .prepare("SELECT id, name, mode FROM presets ORDER BY name, id")
            .map_err(|error| database_error(&self.path, error))?;
        let rows = statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                ))
            })
            .map_err(|error| database_error(&self.path, error))?;
        rows.map(|row| {
            let (id, name, mode) = row.map_err(|error| database_error(&self.path, error))?;
            let mut skills_statement = self
                .connection
                .prepare(
                    "SELECT skill_name FROM preset_skills
                     WHERE preset_id = ?1 ORDER BY skill_name",
                )
                .map_err(|error| database_error(&self.path, error))?;
            let skills = skills_statement
                .query_map(params![id], |row| row.get::<_, String>(0))
                .map_err(|error| database_error(&self.path, error))?
                .map(|skill| skill.map_err(|error| database_error(&self.path, error)))
                .collect::<Result<BTreeSet<_>>>()?;
            Ok(Preset {
                id,
                name,
                skills,
                mode: parse_preset_mode(&mode)?,
            })
        })
        .collect()
    }

    pub fn record_activity(
        &self,
        action: &str,
        outcome: &str,
        commit_id: Option<&str>,
        details: &str,
        restore_origin: Option<&str>,
    ) -> Result<i64> {
        self.connection
            .execute(
                "INSERT INTO activity (action, outcome, commit_id, details, restore_origin, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![action, outcome, commit_id, details, restore_origin, now_rfc3339()],
            )
            .map_err(|error| database_error(&self.path, error))?;
        Ok(self.connection.last_insert_rowid())
    }

    pub fn activity(&self) -> Result<Vec<ActivityRecord>> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT id, action, outcome, commit_id, details, restore_origin, created_at
                 FROM activity ORDER BY id DESC",
            )
            .map_err(|error| database_error(&self.path, error))?;
        let rows = statement
            .query_map([], |row| {
                Ok(ActivityRecord {
                    id: row.get(0)?,
                    action: row.get(1)?,
                    outcome: row.get(2)?,
                    commit_id: row.get(3)?,
                    details: row.get(4)?,
                    restore_origin: row.get(5)?,
                    created_at: row.get(6)?,
                })
            })
            .map_err(|error| database_error(&self.path, error))?;
        rows.map(|row| row.map_err(|error| database_error(&self.path, error)))
            .collect()
    }

    /// Persist a user decision to ignore an upstream update for a skill.
    /// The fingerprint keys the decision to the exact source identity and
    /// upstream content that was compared; when either changes, the decision
    /// no longer matches and the update is surfaced again.
    pub fn ignore_update(&self, skill_name: &str, fingerprint: &str) -> Result<()> {
        self.connection
            .execute(
                "INSERT INTO ignored_updates (skill_name, fingerprint, created_at)
                 VALUES (?1, ?2, ?3)
                 ON CONFLICT(skill_name, fingerprint) DO UPDATE SET created_at = excluded.created_at",
                params![skill_name, fingerprint, now_rfc3339()],
            )
            .map_err(|error| database_error(&self.path, error))?;
        Ok(())
    }

    pub fn is_update_ignored(&self, skill_name: &str, fingerprint: &str) -> Result<bool> {
        let exists: bool = self
            .connection
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM ignored_updates WHERE skill_name = ?1 AND fingerprint = ?2)",
                params![skill_name, fingerprint],
                |row| row.get(0),
            )
            .map_err(|error| database_error(&self.path, error))?;
        Ok(exists)
    }

    pub fn remove_ignored_update(&self, skill_name: &str, fingerprint: &str) -> Result<bool> {
        let changed = self
            .connection
            .execute(
                "DELETE FROM ignored_updates WHERE skill_name = ?1 AND fingerprint = ?2",
                params![skill_name, fingerprint],
            )
            .map_err(|error| database_error(&self.path, error))?;
        Ok(changed == 1)
    }

    /// Persist a user decision to ignore a duplicate group, keeping the
    /// placement selected by `decision`. Keyed on the group fingerprint so a
    /// changed source identity or content hash invalidates the decision.
    pub fn ignore_duplicate(
        &self,
        skill_name: &str,
        fingerprint: &str,
        decision: &str,
    ) -> Result<()> {
        self.connection
            .execute(
                "INSERT INTO ignored_duplicates (skill_name, fingerprint, decision, created_at)
                 VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT(skill_name, fingerprint) DO UPDATE SET
                   decision = excluded.decision,
                   created_at = excluded.created_at",
                params![skill_name, fingerprint, decision, now_rfc3339()],
            )
            .map_err(|error| database_error(&self.path, error))?;
        Ok(())
    }

    pub fn ignored_duplicates(&self) -> Result<BTreeSet<(String, String)>> {
        let mut statement = self
            .connection
            .prepare("SELECT skill_name, fingerprint FROM ignored_duplicates")
            .map_err(|error| database_error(&self.path, error))?;
        let rows = statement
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })
            .map_err(|error| database_error(&self.path, error))?;
        rows.map(|row| row.map_err(|error| database_error(&self.path, error)))
            .collect()
    }

    pub fn ignored_duplicate_decision(
        &self,
        skill_name: &str,
        fingerprint: &str,
    ) -> Result<Option<String>> {
        use rusqlite::OptionalExtension;
        let decision = self
            .connection
            .query_row(
                "SELECT decision FROM ignored_duplicates WHERE skill_name = ?1 AND fingerprint = ?2",
                params![skill_name, fingerprint],
                |row| row.get::<_, String>(0),
            )
            .optional()
            .map_err(|error| database_error(&self.path, error))?;
        Ok(decision)
    }

    pub fn remove_ignored_duplicate(&self, skill_name: &str, fingerprint: &str) -> Result<bool> {
        let changed = self
            .connection
            .execute(
                "DELETE FROM ignored_duplicates WHERE skill_name = ?1 AND fingerprint = ?2",
                params![skill_name, fingerprint],
            )
            .map_err(|error| database_error(&self.path, error))?;
        Ok(changed == 1)
    }

    pub fn preferences(&self) -> Result<Preferences> {
        let mut prefs = Preferences::default();
        let mut statement = self
            .connection
            .prepare("SELECT key, value FROM settings")
            .map_err(|error| database_error(&self.path, error))?;
        let rows = statement
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })
            .map_err(|error| database_error(&self.path, error))?;
        for row in rows {
            let (key, value) = row.map_err(|error| database_error(&self.path, error))?;
            match key.as_str() {
                "theme" => prefs.theme = value,
                "text_size" => prefs.text_size = value,
                "language" => prefs.language = value,
                "editor" => prefs.editor = value,
                "snapshot_retention" => {
                    if let Ok(count) = value.parse() {
                        prefs.snapshot_retention = count;
                    }
                }
                "snapshot_root" => {
                    if !value.is_empty() {
                        prefs.snapshot_root = PathBuf::from(value);
                    }
                }
                "backup_remote" => prefs.backup_remote = value,
                "backup_enabled" => prefs.backup_enabled = value == "true",
                "push_mode" => prefs.push_mode = value,
                "size_policy_bytes" => {
                    if let Ok(bytes) = value.parse() {
                        prefs.size_policy_bytes = bytes;
                    }
                }
                "proxy" => prefs.proxy = value,
                "agent_order" => prefs.agent_order = value,
                _ => {}
            }
        }
        Ok(prefs)
    }

    pub fn set_setting(&self, key: &str, value: &str) -> Result<()> {
        self.connection
            .execute(
                "INSERT INTO settings (key, value) VALUES (?1, ?2)
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                params![key, value],
            )
            .map_err(|error| database_error(&self.path, error))?;
        Ok(())
    }

    pub fn get_setting(&self, key: &str) -> Result<Option<String>> {
        use rusqlite::OptionalExtension;
        self.connection
            .query_row(
                "SELECT value FROM settings WHERE key = ?1",
                params![key],
                |row| row.get(0),
            )
            .optional()
            .map_err(|error| database_error(&self.path, error))
    }

    pub fn settings(&self) -> Result<BTreeMap<String, String>> {
        let mut statement = self
            .connection
            .prepare("SELECT key, value FROM settings ORDER BY key")
            .map_err(|error| database_error(&self.path, error))?;
        let rows = statement
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })
            .map_err(|error| database_error(&self.path, error))?;
        rows.map(|row| row.map_err(|error| database_error(&self.path, error)))
            .collect()
    }

    pub fn save_preferences(&self, prefs: &Preferences) -> Result<()> {
        let snapshot_root = prefs.snapshot_root.to_string_lossy().into_owned();
        let retention = prefs.snapshot_retention.to_string();
        let size_policy = prefs.size_policy_bytes.to_string();
        let backup_enabled = if prefs.backup_enabled {
            "true"
        } else {
            "false"
        };
        let pairs = [
            ("theme", prefs.theme.as_str()),
            ("text_size", prefs.text_size.as_str()),
            ("language", prefs.language.as_str()),
            ("editor", prefs.editor.as_str()),
            ("snapshot_retention", retention.as_str()),
            ("snapshot_root", snapshot_root.as_str()),
            ("backup_enabled", backup_enabled),
            ("backup_remote", prefs.backup_remote.as_str()),
            ("push_mode", prefs.push_mode.as_str()),
            ("size_policy_bytes", size_policy.as_str()),
            ("proxy", prefs.proxy.as_str()),
            ("agent_order", prefs.agent_order.as_str()),
        ];
        for (key, value) in pairs {
            self.set_setting(key, value)?;
        }
        Ok(())
    }

    pub fn backup_metadata(&self) -> Result<BackupMetadata> {
        let mut tags = BTreeMap::<String, BTreeSet<String>>::new();
        let mut statement = self
            .connection
            .prepare("SELECT skill_name, tag FROM skill_tags ORDER BY skill_name, tag")
            .map_err(|error| database_error(&self.path, error))?;
        let rows = statement
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })
            .map_err(|error| database_error(&self.path, error))?;
        for row in rows {
            let (skill_name, tag) = row.map_err(|error| database_error(&self.path, error))?;
            tags.entry(skill_name).or_default().insert(tag);
        }
        let targets = self
            .workspaces()?
            .into_iter()
            .map(|workspace| LogicalTarget {
                id: workspace.id,
                kind: workspace_kind_name(&workspace.kind).to_owned(),
                preferred_mode: install_mode_name(workspace.preferred_mode).to_owned(),
            })
            .collect();
        Ok(BackupMetadata {
            tags,
            presets: self.presets()?,
            targets,
        })
    }
}

fn workspace_kind_name(kind: &WorkspaceKind) -> &'static str {
    match kind {
        WorkspaceKind::Global => "global",
        WorkspaceKind::Project => "project",
        WorkspaceKind::Agent => "agent",
        WorkspaceKind::Custom => "custom",
    }
}

fn parse_workspace_kind(value: &str) -> Result<WorkspaceKind> {
    match value {
        "global" => Ok(WorkspaceKind::Global),
        "project" => Ok(WorkspaceKind::Project),
        "agent" => Ok(WorkspaceKind::Agent),
        "custom" => Ok(WorkspaceKind::Custom),
        _ => Err(GinoError::Database {
            path: PathBuf::new(),
            cause: format!("unknown workspace kind `{value}`"),
        }),
    }
}

fn install_mode_name(mode: InstallMode) -> &'static str {
    match mode {
        InstallMode::Copy => "copy",
        InstallMode::Link => "link",
    }
}

fn parse_install_mode(value: &str) -> Result<InstallMode> {
    match value {
        "copy" => Ok(InstallMode::Copy),
        "link" => Ok(InstallMode::Link),
        _ => Err(GinoError::Database {
            path: PathBuf::new(),
            cause: format!("unknown install mode `{value}`"),
        }),
    }
}

fn preset_mode_name(mode: PresetMode) -> &'static str {
    match mode {
        PresetMode::AddMissing => "add_missing",
        PresetMode::MatchExactly => "match_exactly",
    }
}

fn parse_preset_mode(value: &str) -> Result<PresetMode> {
    match value {
        "add_missing" => Ok(PresetMode::AddMissing),
        "match_exactly" => Ok(PresetMode::MatchExactly),
        _ => Err(GinoError::Database {
            path: PathBuf::new(),
            cause: format!("unknown preset mode `{value}`"),
        }),
    }
}

fn database_error(path: &Path, error: rusqlite::Error) -> GinoError {
    GinoError::Database {
        path: path.to_path_buf(),
        cause: error.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use tempfile::tempdir;

    use super::*;

    #[test]
    fn metadata_round_trip_keeps_tags_presets_and_workspace_bookmarks() {
        let root = tempdir().expect("metadata root");
        let store = MetadataStore::open(root.path().join("state.sqlite")).expect("database");
        let tags = BTreeSet::from(["web".to_owned(), "team".to_owned()]);
        store.set_tags("demo", &tags).expect("tags");
        let preset = Preset {
            id: "preset-1".to_owned(),
            name: "Daily".to_owned(),
            skills: BTreeSet::from(["demo".to_owned()]),
            mode: PresetMode::AddMissing,
        };
        store.save_preset(&preset).expect("preset");
        store
            .save_workspace(&RegisteredWorkspace {
                id: "project-1".to_owned(),
                display_name: "Project".to_owned(),
                kind: WorkspaceKind::Project,
                path: root.path().join("project"),
                preferred_mode: InstallMode::Link,
            })
            .expect("workspace");

        assert_eq!(store.tags_for("demo").expect("tags"), tags);
        assert_eq!(store.presets().expect("presets"), vec![preset.clone()]);
        assert_eq!(store.workspaces().expect("workspaces").len(), 1);

        let backup = store.backup_metadata().expect("backup metadata");
        assert_eq!(backup.tags.get("demo"), Some(&tags));
        assert_eq!(backup.presets, vec![preset]);
        assert_eq!(backup.targets[0].id, "project-1");
        assert_eq!(backup.targets[0].preferred_mode, "link");

        assert!(
            store
                .remove_workspace("project-1")
                .expect("remove bookmark")
        );
        assert!(!root.path().join("project").exists());
    }

    #[test]
    fn ignore_decisions_are_keyed_by_fingerprint() {
        let root = tempdir().expect("metadata root");
        let store = MetadataStore::open(root.path().join("state.sqlite")).expect("database");

        assert!(!store.is_update_ignored("demo", "fp-1").expect("query"));
        store.ignore_update("demo", "fp-1").expect("ignore update");
        assert!(store.is_update_ignored("demo", "fp-1").expect("query"));
        assert!(!store.is_update_ignored("demo", "fp-2").expect("query"));
        assert!(
            store
                .remove_ignored_update("demo", "fp-1")
                .expect("forget update")
        );
        assert!(!store.is_update_ignored("demo", "fp-1").expect("query"));

        assert_eq!(
            store
                .ignored_duplicate_decision("demo", "fp-9")
                .expect("query"),
            None
        );
        store
            .ignore_duplicate("demo", "fp-9", "keep_first")
            .expect("ignore duplicate");
        assert!(
            store
                .ignored_duplicates()
                .expect("list")
                .contains(&("demo".to_owned(), "fp-9".to_owned()))
        );
        assert_eq!(
            store
                .ignored_duplicate_decision("demo", "fp-9")
                .expect("query")
                .as_deref(),
            Some("keep_first")
        );
        store
            .ignore_duplicate("demo", "fp-9", "keep_last")
            .expect("re-ignore duplicate");
        assert_eq!(
            store
                .ignored_duplicate_decision("demo", "fp-9")
                .expect("query")
                .as_deref(),
            Some("keep_last")
        );
        assert!(
            store
                .remove_ignored_duplicate("demo", "fp-9")
                .expect("forget duplicate")
        );
        assert_eq!(
            store
                .ignored_duplicate_decision("demo", "fp-9")
                .expect("query"),
            None
        );
    }

    #[test]
    fn preferences_round_trip() {
        let root = tempdir().expect("metadata root");
        let store = MetadataStore::open(root.path().join("state.sqlite")).expect("database");
        // Backup starts off (opt-in) and survives a save/load cycle when on.
        assert!(!store.preferences().expect("fresh").backup_enabled);
        let prefs = Preferences {
            theme: "dark".to_owned(),
            push_mode: "commit_locally".to_owned(),
            snapshot_retention: 3,
            backup_enabled: true,
            ..Preferences::default()
        };
        store.save_preferences(&prefs).expect("save");
        let loaded = store.preferences().expect("load");
        assert_eq!(loaded.theme, "dark");
        assert!(loaded.commit_locally());
        assert_eq!(loaded.snapshot_retention, 3);
        assert_eq!(loaded.snapshot_root, prefs.snapshot_root);
        assert!(loaded.backup_enabled);
    }

    #[test]
    fn default_snapshot_root_is_under_gino_home_not_tmpdir() {
        let root = default_snapshot_root();
        assert_eq!(root, user_home().join(".gino").join("snapshots"));
        assert_eq!(Preferences::default().snapshot_root, root);
        assert_ne!(root, std::env::temp_dir());
    }

    #[test]
    fn settings_key_value_table_survives_preference_save() {
        let root = tempdir().expect("metadata root");
        let store = MetadataStore::open(root.path().join("state.sqlite")).expect("database");
        store.set_setting("custom_flag", "yes").expect("set custom");
        store
            .save_preferences(&Preferences {
                theme: "dark".to_owned(),
                ..Preferences::default()
            })
            .expect("save prefs");
        assert_eq!(
            store.get_setting("custom_flag").expect("custom"),
            Some("yes".to_owned())
        );
        assert_eq!(
            store.get_setting("theme").expect("theme"),
            Some("dark".to_owned())
        );
        assert!(store.settings().expect("all").contains_key("snapshot_root"));
        assert_eq!(store.get_setting("missing").expect("missing"), None);
    }

    #[test]
    fn release_identity_is_1_0_0_with_github_releases_and_no_telemetry() {
        assert_eq!(APP_VERSION, "1.0.0");
        assert_eq!(APP_VERSION, env!("CARGO_PKG_VERSION"));
        assert_eq!(
            RELEASES_URL,
            "https://github.com/thedavidweng/gino/releases"
        );
        assert_eq!(
            RELEASES_URL,
            concat!(env!("CARGO_PKG_REPOSITORY"), "/releases")
        );

        let encoded = serde_json::to_string(&Preferences::default()).expect("prefs json");
        assert!(!encoded.contains("telemetry"));
        assert!(!encoded.contains("self_update"));
        assert!(!encoded.contains("self-update"));

        let root = tempdir().expect("metadata root");
        let store = MetadataStore::open(root.path().join("state.sqlite")).expect("database");
        store
            .save_preferences(&Preferences::default())
            .expect("save prefs");
        let keys = store.settings().expect("settings");
        assert!(!keys.is_empty());
        assert!(
            keys.keys()
                .all(|key| !key.contains("telemetry") && !key.contains("update"))
        );
    }
}
