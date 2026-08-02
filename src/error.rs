use std::io;
use std::path::PathBuf;

use thiserror::Error;

pub type Result<T> = std::result::Result<T, GinoError>;

#[derive(Debug, Error)]
pub enum GinoError {
    #[error("I/O error at {path}: {source}")]
    Io { path: PathBuf, source: io::Error },

    #[error("JSON error at {path}: {source}")]
    Json {
        path: PathBuf,
        source: serde_json::Error,
    },

    #[error("YAML frontmatter error in {path}: {source}")]
    Yaml {
        path: PathBuf,
        source: serde_yaml::Error,
    },

    #[error("invalid Skill at {path}: {reason}")]
    InvalidSkill { path: PathBuf, reason: String },

    #[error("invalid source `{input}`: {reason}")]
    InvalidSource { input: String, reason: String },

    #[error("lockfile at {path} is not safely compatible: {reason}")]
    IncompatibleLockfile { path: PathBuf, reason: String },

    #[error("unsafe operation path {path}: {reason}")]
    UnsafePath { path: PathBuf, reason: String },

    #[error("invalid plan: {0}")]
    InvalidPlan(String),

    #[error(
        "{action} failed for Skill `{skill}` from {source_path} to {destination_path}: {cause}"
    )]
    Apply {
        skill: String,
        action: String,
        source_path: PathBuf,
        destination_path: PathBuf,
        cause: String,
    },

    #[error("Git command `{command}` failed in {directory}: {cause}")]
    Git {
        directory: PathBuf,
        command: String,
        cause: String,
    },

    #[error("metadata database at {path}: {cause}")]
    Database { path: PathBuf, cause: String },
}

pub fn io_error(path: impl Into<PathBuf>, source: io::Error) -> GinoError {
    GinoError::Io {
        path: path.into(),
        source,
    }
}

pub fn json_error(path: impl Into<PathBuf>, source: serde_json::Error) -> GinoError {
    GinoError::Json {
        path: path.into(),
        source,
    }
}
