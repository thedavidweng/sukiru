use std::collections::BTreeMap;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::error::Result;
use crate::protocol::{collect_skill_files, skill_folder_hash};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum UpdateStatus {
    Unchanged,
    UpdateAvailable,
    LocallyModified,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum FileDifferenceKind {
    Added,
    Removed,
    Changed,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct FileDifference {
    pub relative_path: String,
    pub kind: FileDifferenceKind,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SkillComparison {
    pub local_path: PathBuf,
    pub upstream_path: PathBuf,
    pub local_hash: String,
    pub upstream_hash: String,
    pub status: UpdateStatus,
    pub files: Vec<FileDifference>,
}

pub fn compare_skill_dirs(
    local_path: impl Into<PathBuf>,
    upstream_path: impl Into<PathBuf>,
    recorded_hash: Option<&str>,
) -> Result<SkillComparison> {
    let local_path = local_path.into();
    let upstream_path = upstream_path.into();
    let local_hash = skill_folder_hash(&local_path)?;
    let upstream_hash = skill_folder_hash(&upstream_path)?;
    let local_files = collect_skill_files(&local_path)?
        .into_iter()
        .map(|file| (file.relative_path, file.bytes))
        .collect::<BTreeMap<_, _>>();
    let upstream_files = collect_skill_files(&upstream_path)?
        .into_iter()
        .map(|file| (file.relative_path, file.bytes))
        .collect::<BTreeMap<_, _>>();
    let mut paths: Vec<String> = local_files
        .keys()
        .chain(upstream_files.keys())
        .cloned()
        .collect();
    paths.sort();
    paths.dedup();
    let files = paths
        .into_iter()
        .filter_map(|relative_path| {
            let kind = match (
                local_files.get(&relative_path),
                upstream_files.get(&relative_path),
            ) {
                (None, Some(_)) => FileDifferenceKind::Added,
                (Some(_), None) => FileDifferenceKind::Removed,
                (Some(local), Some(upstream)) if local != upstream => FileDifferenceKind::Changed,
                _ => return None,
            };
            Some(FileDifference {
                relative_path,
                kind,
            })
        })
        .collect();
    let status = if local_hash == upstream_hash {
        UpdateStatus::Unchanged
    } else if recorded_hash.is_some_and(|recorded| recorded == local_hash) {
        UpdateStatus::UpdateAvailable
    } else {
        UpdateStatus::LocallyModified
    };
    Ok(SkillComparison {
        local_path,
        upstream_path,
        local_hash,
        upstream_hash,
        status,
        files,
    })
}

/// Stable key for an "ignore this upstream update" decision. It binds the
/// decision to the exact upstream content that was compared; when upstream
/// publishes new content (`upstream_hash` changes) the decision no longer
/// matches and the update is surfaced again. Local modifications do not
/// invalidate it.
pub fn update_ignore_fingerprint(skill_name: &str, upstream_hash: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(skill_name.as_bytes());
    hasher.update(b"\n");
    hasher.update(upstream_hash.as_bytes());
    format!("{:x}", hasher.finalize())
}

/// Match a comparison against a persisted ignore decision. A comparison is
/// ignored only when it reports `UpdateAvailable` for the same upstream
/// content that was ignored; local modifications are always surfaced.
pub fn is_ignored_update(
    ignored: impl Fn(&str, &str) -> bool,
    skill_name: &str,
    comparison: &SkillComparison,
) -> bool {
    comparison.status == UpdateStatus::UpdateAvailable
        && ignored(
            skill_name,
            &update_ignore_fingerprint(skill_name, &comparison.upstream_hash),
        )
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::Path;

    use tempfile::tempdir;

    use super::*;

    fn write_skill(root: &Path, body: &str) {
        fs::write(
            root.join("SKILL.md"),
            format!("---\nname: demo\ndescription: demo\n---\n{body}\n"),
        )
        .expect("skill");
    }

    #[test]
    fn update_ignore_fingerprint_binds_skill_and_upstream_content() {
        let first = update_ignore_fingerprint("demo", "hash-1");
        assert_eq!(first, update_ignore_fingerprint("demo", "hash-1"));
        assert_ne!(first, update_ignore_fingerprint("demo", "hash-2"));
        assert_ne!(first, update_ignore_fingerprint("other", "hash-1"));
    }

    #[test]
    fn ignored_update_only_matches_clean_available_updates() {
        let local = tempdir().expect("local");
        let upstream = tempdir().expect("upstream");
        write_skill(local.path(), "same");
        write_skill(upstream.path(), "new");
        let local_hash = skill_folder_hash(local.path()).expect("hash");
        let comparison =
            compare_skill_dirs(local.path(), upstream.path(), Some(&local_hash)).expect("compare");
        assert_eq!(comparison.status, UpdateStatus::UpdateAvailable);

        let store = |name: &str, _: &str| name == "demo";
        assert!(
            is_ignored_update(store, "demo", &comparison),
            "available update is ignored"
        );
        assert!(
            !is_ignored_update(store, "other", &comparison),
            "other skill is not ignored"
        );

        write_skill(local.path(), "local edit");
        let modified =
            compare_skill_dirs(local.path(), upstream.path(), Some(&local_hash)).expect("compare");
        assert_eq!(modified.status, UpdateStatus::LocallyModified);
        assert!(
            !is_ignored_update(store, "demo", &modified),
            "local modifications are never hidden"
        );
    }
}
