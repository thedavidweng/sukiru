use std::collections::BTreeMap;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Component, Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use chrono::Utc;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::error::{GinoError, Result, io_error, json_error};

pub const GLOBAL_LOCK_VERSION: u64 = 3;
pub const PROJECT_LOCK_VERSION: u64 = 1;

pub fn global_lock_path(home: &Path) -> PathBuf {
    std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .map(|state_home| state_home.join("skills/.skill-lock.json"))
        .unwrap_or_else(|| home.join(".agents/.skill-lock.json"))
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct SkillMetadata {
    pub name: String,
    pub description: String,
    #[serde(skip)]
    pub path: PathBuf,
    #[serde(skip)]
    pub skill_file: String,
    #[serde(skip)]
    pub internal: bool,
}

/// Parse the required YAML frontmatter without treating the body as mutable
/// application data. The upstream protocol requires both `name` and
/// `description`; missing fields make the directory undiscoverable.
pub fn parse_skill_metadata(skill_dir: &Path) -> Result<SkillMetadata> {
    let skill_file_path = skill_dir.join("SKILL.md");
    let skill_file = fs::read_to_string(&skill_file_path)
        .map_err(|source| io_error(skill_file_path.clone(), source))?;
    let (frontmatter, _) =
        split_frontmatter(&skill_file).ok_or_else(|| GinoError::InvalidSkill {
            path: skill_file_path.clone(),
            reason: "SKILL.md must start with YAML frontmatter delimited by `---`".to_owned(),
        })?;
    let yaml: serde_yaml::Value =
        serde_yaml::from_str(frontmatter).map_err(|source| GinoError::Yaml {
            path: skill_file_path.clone(),
            source,
        })?;
    let mapping = yaml.as_mapping().ok_or_else(|| GinoError::InvalidSkill {
        path: skill_file_path.clone(),
        reason: "frontmatter must be a YAML mapping".to_owned(),
    })?;

    let string_field = |name: &str| {
        mapping
            .get(serde_yaml::Value::String(name.to_owned()))
            .and_then(serde_yaml::Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToOwned::to_owned)
    };
    let name = string_field("name").ok_or_else(|| GinoError::InvalidSkill {
        path: skill_file_path.clone(),
        reason: "required frontmatter field `name` is missing".to_owned(),
    })?;
    let description = string_field("description").ok_or_else(|| GinoError::InvalidSkill {
        path: skill_file_path.clone(),
        reason: "required frontmatter field `description` is missing".to_owned(),
    })?;
    let internal = mapping
        .get(serde_yaml::Value::String("metadata".to_owned()))
        .and_then(serde_yaml::Value::as_mapping)
        .and_then(|metadata| metadata.get(serde_yaml::Value::String("internal".to_owned())))
        .and_then(serde_yaml::Value::as_bool)
        .unwrap_or(false);

    Ok(SkillMetadata {
        name,
        description,
        path: skill_dir.to_path_buf(),
        skill_file,
        internal,
    })
}

fn split_frontmatter(content: &str) -> Option<(&str, &str)> {
    let start = content
        .strip_prefix("---\n")
        .or_else(|| content.strip_prefix("---\r\n"))?;
    let end = start.find("\n---").or_else(|| start.find("\r\n---"))?;
    let body_start = end
        + if start.as_bytes().get(end) == Some(&b'\r') {
            5
        } else {
            4
        };
    Some((&start[..end], &start[body_start..]))
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct SkillFile {
    pub relative_path: String,
    pub bytes: Vec<u8>,
}

/// Hashing follows the upstream local lock convention: paths are normalized
/// to `/`, sorted, and included before each file's bytes. Excluded metadata
/// files and generated directories are not part of Skill identity.
pub fn collect_skill_files(skill_dir: &Path) -> Result<Vec<SkillFile>> {
    let mut files = Vec::new();
    collect_skill_files_inner(skill_dir, skill_dir, &mut files)?;
    files.sort_by(|left, right| left.relative_path.cmp(&right.relative_path));
    Ok(files)
}

fn collect_skill_files_inner(
    base: &Path,
    current: &Path,
    files: &mut Vec<SkillFile>,
) -> Result<()> {
    let entries = fs::read_dir(current).map_err(|source| io_error(current, source))?;
    for entry in entries {
        let entry = entry.map_err(|source| io_error(current, source))?;
        let path = entry.path();
        let name = entry.file_name();
        let name = name.to_string_lossy();
        let metadata = fs::symlink_metadata(&path).map_err(|source| io_error(&path, source))?;
        if metadata.file_type().is_symlink() {
            let relative = path.strip_prefix(base).map_err(|_| GinoError::UnsafePath {
                path: path.clone(),
                reason: "Skill link escaped its root".to_owned(),
            })?;
            let relative_path = normalize_relative_path(Path::new(""), relative);
            let target = fs::read_link(&path).map_err(|source| io_error(&path, source))?;
            files.push(SkillFile {
                relative_path,
                bytes: format!("symlink:{target:?}").into_bytes(),
            });
            continue;
        }
        if metadata.is_dir() {
            if is_excluded_directory(&name) {
                continue;
            }
            collect_skill_files_inner(base, &path, files)?;
        } else if metadata.is_file() && !is_excluded_file(&name) {
            let bytes = fs::read(&path).map_err(|source| io_error(&path, source))?;
            let relative_path = path
                .strip_prefix(base)
                .map_err(|_| GinoError::UnsafePath {
                    path: path.clone(),
                    reason: "Skill file escaped its root".to_owned(),
                })
                .map(|relative| normalize_relative_path(Path::new(""), relative))?;
            files.push(SkillFile {
                relative_path,
                bytes,
            });
        }
    }
    Ok(())
}

fn is_excluded_directory(name: &str) -> bool {
    matches!(
        name,
        ".git" | "node_modules" | "__pycache__" | "__pypackages__" | "dist" | "build"
    )
}

fn is_excluded_file(name: &str) -> bool {
    name == "metadata.json"
}

fn normalize_relative_path(base: &Path, path: &Path) -> String {
    base.join(path)
        .components()
        .filter_map(|component| match component {
            Component::Normal(value) => Some(value.to_string_lossy().into_owned()),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("/")
}

pub fn skill_folder_hash(skill_dir: &Path) -> Result<String> {
    let mut hasher = Sha256::new();
    for file in collect_skill_files(skill_dir)? {
        hasher.update(file.relative_path.as_bytes());
        hasher.update(&file.bytes);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

pub fn sha256_bytes(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum LockScope {
    Global,
    Project,
}

impl LockScope {
    pub const fn expected_version(self) -> u64 {
        match self {
            Self::Global => GLOBAL_LOCK_VERSION,
            Self::Project => PROJECT_LOCK_VERSION,
        }
    }
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct SkillLockEntry {
    pub source: String,
    #[serde(rename = "sourceType")]
    pub source_type: String,
    #[serde(rename = "sourceUrl")]
    pub source_url: Option<String>,
    #[serde(rename = "ref")]
    pub ref_name: Option<String>,
    #[serde(rename = "skillPath")]
    pub skill_path: Option<String>,
    #[serde(rename = "skillFolderHash")]
    pub skill_folder_hash: Option<String>,
    #[serde(rename = "installedAt")]
    pub installed_at: Option<String>,
    #[serde(rename = "updatedAt")]
    pub updated_at: Option<String>,
    #[serde(rename = "pluginName")]
    pub plugin_name: Option<String>,
    #[serde(rename = "sourceBaseUrl")]
    pub source_base_url: Option<String>,
    #[serde(rename = "wellKnownDigest")]
    pub well_known_digest: Option<String>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

impl SkillLockEntry {
    pub fn managed(&self) -> bool {
        !self.source.is_empty() && !self.source_type.is_empty()
    }

    pub fn source_identity(&self) -> String {
        format!(
            "{}|{}|{}|{}",
            self.source,
            self.source_type,
            self.skill_path.as_deref().unwrap_or_default(),
            self.ref_name.as_deref().unwrap_or_default()
        )
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct LockFile {
    pub version: u64,
    pub skills: BTreeMap<String, SkillLockEntry>,
    #[serde(default)]
    pub dismissed: Option<DismissedPrompts>,
    #[serde(rename = "lastSelectedAgents", default)]
    pub last_selected_agents: Option<Vec<String>>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct DismissedPrompts {
    #[serde(rename = "findSkillsPrompt", default)]
    pub find_skills_prompt: Option<bool>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

impl LockFile {
    pub fn empty(scope: LockScope) -> Self {
        Self {
            version: scope.expected_version(),
            skills: BTreeMap::new(),
            dismissed: (scope == LockScope::Global).then(DismissedPrompts::default),
            last_selected_agents: None,
            extra: BTreeMap::new(),
        }
    }

    pub fn set_skill(&mut self, name: impl Into<String>, mut entry: SkillLockEntry) {
        let name = name.into();
        let now = Utc::now().to_rfc3339();
        if let Some(previous) = self.skills.get(&name) {
            entry.installed_at = previous.installed_at.clone().or_else(|| Some(now.clone()));
        } else {
            entry.installed_at = Some(now.clone());
        }
        entry.updated_at = Some(now);
        self.skills.insert(name, entry);
    }

    pub fn remove_skill(&mut self, name: &str) -> bool {
        self.skills.remove(name).is_some()
    }
}

pub fn read_lock_file(path: &Path, scope: LockScope) -> Result<LockFile> {
    match fs::symlink_metadata(path) {
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(LockFile::empty(scope));
        }
        Err(error) => return Err(io_error(path, error)),
    }
    let bytes = fs::read(path).map_err(|source| io_error(path, source))?;
    let lock: LockFile =
        serde_json::from_slice(&bytes).map_err(|source| json_error(path, source))?;
    if lock.version < scope.expected_version() {
        return Err(GinoError::IncompatibleLockfile {
            path: path.to_path_buf(),
            reason: format!(
                "version {} is older than supported version {}; reinstall or migrate it explicitly",
                lock.version,
                scope.expected_version()
            ),
        });
    }
    Ok(lock)
}

pub fn write_lock_file(path: &Path, lock: &LockFile) -> Result<()> {
    let bytes = serde_json::to_vec_pretty(lock).map_err(|source| json_error(path, source))?;
    write_atomic(path, &bytes)
}

pub fn write_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    let parent = path.parent().ok_or_else(|| GinoError::UnsafePath {
        path: path.to_path_buf(),
        reason: "lockfile has no parent directory".to_owned(),
    })?;
    fs::create_dir_all(parent).map_err(|source| io_error(parent, source))?;
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .map_err(|source| GinoError::Clock {
            cause: source.to_string(),
        })?;
    let file_name = path.file_name().ok_or_else(|| GinoError::UnsafePath {
        path: path.to_path_buf(),
        reason: "atomic replacement requires a file name".to_owned(),
    })?;
    let temporary = parent.join(format!(".{}.{}.tmp", file_name.to_string_lossy(), nonce));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)
        .map_err(|source| io_error(&temporary, source))?;
    if let Err(source) = file.write_all(bytes).and_then(|_| file.sync_all()) {
        let _ = fs::remove_file(&temporary);
        return Err(io_error(&temporary, source));
    }
    drop(file);
    #[cfg(windows)]
    if path.exists() {
        fs::remove_file(path).map_err(|source| io_error(path, source))?;
    }
    fs::rename(&temporary, path).map_err(|source| {
        let _ = fs::remove_file(&temporary);
        io_error(path, source)
    })
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum SourceType {
    Github,
    Gitlab,
    Git,
    Local,
    Direct,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct SkillSource {
    pub input: String,
    pub normalized: String,
    pub source_type: SourceType,
    pub source_url: String,
    pub ref_name: Option<String>,
    pub skill_path: Option<String>,
}

impl SkillSource {
    pub fn parse(input: &str) -> Result<Self> {
        let input = input.trim();
        if input.is_empty() {
            return Err(GinoError::InvalidSource {
                input: input.to_owned(),
                reason: "source is empty".to_owned(),
            });
        }
        let is_local = input.starts_with('.')
            || input.starts_with('/')
            || input.starts_with('~')
            || input.starts_with("\\")
            || Path::new(input).exists();
        if is_local {
            let path = PathBuf::from(input);
            return Ok(Self {
                input: input.to_owned(),
                normalized: path.to_string_lossy().replace('\\', "/"),
                source_type: SourceType::Local,
                source_url: input.to_owned(),
                ref_name: None,
                skill_path: None,
            });
        }

        if let Some((_, hosted)) = input.split_once("://") {
            let (host, path) = hosted.split_once('/').unwrap_or((hosted, ""));
            return Self::parse_hosted(input, host, path);
        }
        if input.starts_with("git@") || input.starts_with("ssh:") {
            return Ok(Self {
                input: input.to_owned(),
                normalized: input.trim_end_matches(".git").to_owned(),
                source_type: SourceType::Git,
                source_url: input.to_owned(),
                ref_name: None,
                skill_path: None,
            });
        }
        let shorthand = input.trim_end_matches(".git");
        let mut segments = shorthand.split('/');
        let owner = segments.next().unwrap_or_default();
        let repo_with_skill = segments.next().unwrap_or_default();
        if !owner.is_empty() && !repo_with_skill.is_empty() && segments.next().is_none() {
            let (repo, skill_path) = repo_with_skill
                .split_once('@')
                .map(|(repo, skill)| (repo, Some(skill.to_owned())))
                .unwrap_or((repo_with_skill, None));
            if !repo.is_empty() {
                return Ok(Self {
                    input: input.to_owned(),
                    normalized: format!("{owner}/{repo}"),
                    source_type: SourceType::Github,
                    source_url: format!("https://github.com/{owner}/{repo}"),
                    ref_name: None,
                    skill_path,
                });
            }
        }

        Ok(Self {
            input: input.to_owned(),
            normalized: input.to_owned(),
            source_type: SourceType::Direct,
            source_url: input.to_owned(),
            ref_name: None,
            skill_path: None,
        })
    }

    fn parse_hosted(input: &str, host: &str, path: &str) -> Result<Self> {
        let kind = match host.to_ascii_lowercase().as_str() {
            "github.com" | "www.github.com" => SourceType::Github,
            "gitlab.com" | "www.gitlab.com" => SourceType::Gitlab,
            _ => SourceType::Direct,
        };
        let segments: Vec<&str> = path
            .trim_matches('/')
            .split('/')
            .filter(|part| !part.is_empty())
            .collect();
        if matches!(kind, SourceType::Github | SourceType::Gitlab) && segments.len() < 2 {
            return Err(GinoError::InvalidSource {
                input: input.to_owned(),
                reason: "hosted source must include an owner and repository".to_owned(),
            });
        }
        let normalized = if matches!(kind, SourceType::Github | SourceType::Gitlab) {
            format!("{}/{}", segments[0], segments[1].trim_end_matches(".git"))
        } else {
            input.to_owned()
        };
        let (ref_name, skill_path) = match segments.get(2).copied() {
            Some("tree") | Some("blob") if segments.len() >= 4 => {
                let ref_name = Some(segments[3].to_owned());
                let path = (segments.len() > 4).then(|| segments[4..].join("/"));
                (ref_name, path)
            }
            _ => (None, None),
        };
        Ok(Self {
            input: input.to_owned(),
            normalized,
            source_type: kind,
            source_url: input.to_owned(),
            ref_name,
            skill_path,
        })
    }

    pub fn source_type_name(&self) -> &'static str {
        match self.source_type {
            SourceType::Github => "github",
            SourceType::Gitlab => "gitlab",
            SourceType::Git => "git",
            SourceType::Local => "local",
            SourceType::Direct => "direct",
        }
    }

    pub fn lock_entry(&self, folder_hash: String) -> SkillLockEntry {
        SkillLockEntry {
            source: self.normalized.clone(),
            source_type: self.source_type_name().to_owned(),
            source_url: Some(self.source_url.clone()),
            ref_name: self.ref_name.clone(),
            skill_path: self.skill_path.clone(),
            skill_folder_hash: Some(folder_hash),
            ..SkillLockEntry::default()
        }
    }
}

pub fn sanitize_skill_name(name: &str) -> Result<String> {
    let name = name.trim();
    if name.is_empty() || name == "." || name == ".." || name.contains('/') || name.contains('\\') {
        return Err(GinoError::InvalidSource {
            input: name.to_owned(),
            reason: "Skill name must be a single non-empty directory name".to_owned(),
        });
    }
    Ok(name.to_owned())
}

pub fn now_rfc3339() -> String {
    Utc::now().to_rfc3339()
}

#[cfg(test)]
mod tests {
    use std::fs;

    use tempfile::tempdir;

    use super::*;

    #[test]
    fn parses_required_skill_frontmatter_and_internal_flag() {
        let root = tempdir().expect("tempdir");
        fs::write(
            root.path().join("SKILL.md"),
            "---\nname: demo\ndescription: A demo skill\nmetadata:\n  internal: true\n---\n\n# Demo\n",
        )
        .expect("write skill");

        let metadata = parse_skill_metadata(root.path()).expect("valid skill");
        assert_eq!(metadata.name, "demo");
        assert_eq!(metadata.description, "A demo skill");
        assert!(metadata.internal);
    }

    #[test]
    fn skill_hash_is_deterministic_and_excludes_generated_content() {
        let root = tempdir().expect("tempdir");
        fs::write(
            root.path().join("SKILL.md"),
            "---\nname: demo\ndescription: Demo\n---\n",
        )
        .expect("write skill");
        fs::write(root.path().join("metadata.json"), "ignored").expect("write metadata");
        fs::create_dir(root.path().join("node_modules")).expect("node modules");
        fs::write(root.path().join("node_modules/ignored"), "ignored").expect("write ignored");

        let first = skill_folder_hash(root.path()).expect("hash");
        fs::write(root.path().join("metadata.json"), "changed").expect("change metadata");
        fs::write(root.path().join("node_modules/ignored"), "changed").expect("change ignored");
        let second = skill_folder_hash(root.path()).expect("hash");
        assert_eq!(first, second);
    }

    #[test]
    fn lock_round_trip_preserves_unknown_fields() {
        let root = tempdir().expect("tempdir");
        let lock_path = root.path().join(".skill-lock.json");
        fs::write(
            &lock_path,
            r#"{
              "version": 3,
              "skills": {
                "demo": {
                  "source": "owner/repo",
                  "sourceType": "github",
                  "sourceUrl": "https://github.com/owner/repo",
                  "skillFolderHash": "abc",
                  "futureField": {"kept": true}
                }
              },
              "futureTopLevel": "kept"
            }"#,
        )
        .expect("write lock");
        let lock = read_lock_file(&lock_path, LockScope::Global).expect("read lock");
        write_lock_file(&lock_path, &lock).expect("write lock");
        let output = fs::read_to_string(lock_path).expect("read output");
        assert!(output.contains("futureField"));
        assert!(output.contains("futureTopLevel"));
    }

    #[test]
    fn parses_supported_source_forms() {
        let github =
            SkillSource::parse("https://github.com/vercel-labs/agent-skills/tree/main/skills/demo")
                .expect("github source");
        assert_eq!(github.normalized, "vercel-labs/agent-skills");
        assert_eq!(github.ref_name.as_deref(), Some("main"));
        assert_eq!(github.skill_path.as_deref(), Some("skills/demo"));

        let shorthand =
            SkillSource::parse("vercel-labs/agent-skills@demo").expect("shorthand source");
        assert_eq!(shorthand.source_type, SourceType::Github);
        assert_eq!(shorthand.skill_path.as_deref(), Some("demo"));
    }
}
