use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

use rusqlite::{Connection, params};
use serde::{Deserialize, Serialize};

use crate::error::{GinoError, Result};
use crate::inventory::WorkspaceKind;
use crate::planner::{InstallMode, Preset, PresetMode};
use crate::protocol::now_rfc3339;

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
    pub created_at: String,
}

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
                   created_at TEXT NOT NULL
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
    ) -> Result<i64> {
        self.connection
            .execute(
                "INSERT INTO activity (action, outcome, commit_id, details, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![action, outcome, commit_id, details, now_rfc3339()],
            )
            .map_err(|error| database_error(&self.path, error))?;
        Ok(self.connection.last_insert_rowid())
    }

    pub fn activity(&self) -> Result<Vec<ActivityRecord>> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT id, action, outcome, commit_id, details, created_at
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
                    created_at: row.get(5)?,
                })
            })
            .map_err(|error| database_error(&self.path, error))?;
        rows.map(|row| row.map_err(|error| database_error(&self.path, error)))
            .collect()
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
        assert_eq!(store.presets().expect("presets"), vec![preset]);
        assert_eq!(store.workspaces().expect("workspaces").len(), 1);
        assert!(
            store
                .remove_workspace("project-1")
                .expect("remove bookmark")
        );
        assert!(!root.path().join("project").exists());
    }
}
