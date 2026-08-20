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

/// Upstream project lock (`local-lock.ts`): `skills-lock.json` at the project root.
pub fn project_lock_path(project_root: &Path) -> PathBuf {
    project_root.join("skills-lock.json")
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

/// Which paths participate in a content hash. The upstream global and project
/// locks disagree on exclusions: the global lock omits generated artifacts and
/// `metadata.json`, while the project `computedHash` only omits `.git` and
/// `node_modules`. Keeping them distinct is required for differential parity.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HashScope {
    Global,
    Project,
}

/// Hashing follows the upstream local lock convention: paths are normalized
/// to `/`, sorted, and included before each file's bytes. Uses the global
/// exclusion set (global lock / tree-SHA proxy).
pub fn collect_skill_files(skill_dir: &Path) -> Result<Vec<SkillFile>> {
    collect_skill_files_with(skill_dir, HashScope::Global)
}

/// Collect skill files using the project `computedHash` exclusion set.
pub fn collect_project_skill_files(skill_dir: &Path) -> Result<Vec<SkillFile>> {
    collect_skill_files_with(skill_dir, HashScope::Project)
}

fn collect_skill_files_with(skill_dir: &Path, scope: HashScope) -> Result<Vec<SkillFile>> {
    let mut files = Vec::new();
    collect_skill_files_inner(skill_dir, skill_dir, scope, &mut files)?;
    files.sort_by(|left, right| match scope {
        // Upstream `local-lock.ts` sorts with `String.localeCompare`, which
        // puts `SKILL.md` after `agents/` (case-insensitive). Byte order
        // would disagree with official `computedHash`.
        HashScope::Project => cmp_project_hash_path(&left.relative_path, &right.relative_path),
        HashScope::Global => left.relative_path.cmp(&right.relative_path),
    });
    Ok(files)
}

fn cmp_project_hash_path(left: &str, right: &str) -> std::cmp::Ordering {
    left.to_lowercase()
        .cmp(&right.to_lowercase())
        .then_with(|| left.cmp(right))
}

fn collect_skill_files_inner(
    base: &Path,
    current: &Path,
    scope: HashScope,
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
            if is_excluded_directory(&name, scope) {
                continue;
            }
            collect_skill_files_inner(base, &path, scope, files)?;
        } else if metadata.is_file() && !is_excluded_file(&name, scope) {
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

fn is_excluded_directory(name: &str, scope: HashScope) -> bool {
    match scope {
        // Project `computedHash` only excludes `.git` and `node_modules`.
        HashScope::Project => matches!(name, ".git" | "node_modules"),
        HashScope::Global => matches!(
            name,
            ".git" | "node_modules" | "__pycache__" | "__pypackages__" | "dist" | "build"
        ),
    }
}

fn is_excluded_file(name: &str, scope: HashScope) -> bool {
    match scope {
        // Project `computedHash` includes `metadata.json`.
        HashScope::Project => false,
        HashScope::Global => name == "metadata.json",
    }
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
    hash_files(&collect_skill_files(skill_dir)?)
}

/// Project-scope `computedHash`: deterministic local SHA-256 over the project
/// exclusion set (only `.git` and `node_modules` are omitted).
pub fn project_computed_hash(skill_dir: &Path) -> Result<String> {
    hash_files(&collect_project_skill_files(skill_dir)?)
}

fn hash_files(files: &[SkillFile]) -> Result<String> {
    let mut hasher = Sha256::new();
    for file in files {
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
    #[serde(rename = "sourceUrl", skip_serializing_if = "Option::is_none")]
    pub source_url: Option<String>,
    #[serde(rename = "ref", skip_serializing_if = "Option::is_none")]
    pub ref_name: Option<String>,
    #[serde(rename = "skillPath", skip_serializing_if = "Option::is_none")]
    pub skill_path: Option<String>,
    /// Global-scope lock hash. The upstream global lock stores a GitHub tree
    /// SHA on `skillFolderHash`; Gino fills this with the deterministic local
    /// hash as a faithful proxy until the offline tree-SHA oracle is wired in.
    #[serde(rename = "skillFolderHash", skip_serializing_if = "Option::is_none")]
    pub skill_folder_hash: Option<String>,
    /// Project-scope lock hash. The upstream project lock stores the locally
    /// computed content SHA-256 on `computedHash`, NOT `skillFolderHash`.
    #[serde(rename = "computedHash", skip_serializing_if = "Option::is_none")]
    pub computed_hash: Option<String>,
    #[serde(rename = "installedAt", skip_serializing_if = "Option::is_none")]
    pub installed_at: Option<String>,
    #[serde(rename = "updatedAt", skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<String>,
    #[serde(rename = "pluginName", skip_serializing_if = "Option::is_none")]
    pub plugin_name: Option<String>,
    #[serde(rename = "sourceBaseUrl", skip_serializing_if = "Option::is_none")]
    pub source_base_url: Option<String>,
    #[serde(rename = "wellKnownDigest", skip_serializing_if = "Option::is_none")]
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dismissed: Option<DismissedPrompts>,
    #[serde(
        rename = "lastSelectedAgents",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub last_selected_agents: Option<Vec<String>>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct DismissedPrompts {
    #[serde(
        rename = "findSkillsPrompt",
        default,
        skip_serializing_if = "Option::is_none"
    )]
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

    /// Normalize scope-only fields so a written lock matches the upstream
    /// schema for its scope. Global locks carry `skillFolderHash`; project
    /// locks carry `computedHash` and are intentionally timestamp-free
    /// (upstream `local-lock.ts` writes no `installedAt`/`updatedAt` and no
    /// prompt or agent-selection state). The call is idempotent.
    pub fn normalize_for_scope(&mut self, scope: LockScope) {
        match scope {
            LockScope::Global => {
                for entry in self.skills.values_mut() {
                    entry.computed_hash = None;
                }
            }
            LockScope::Project => {
                for entry in self.skills.values_mut() {
                    if entry.computed_hash.is_none() {
                        entry.computed_hash = entry.skill_folder_hash.take();
                    } else {
                        entry.skill_folder_hash = None;
                    }
                    entry.installed_at = None;
                    entry.updated_at = None;
                }
                self.dismissed = None;
                self.last_selected_agents = None;
            }
        }
        self.version = scope.expected_version();
    }

    /// Serialize for a scope with upstream byte parity: the project lock is
    /// written with a trailing newline (upstream `writeLocalLock`), the
    /// global lock without one.
    pub fn to_bytes_for_scope(&self, path: &Path, scope: LockScope) -> Result<Vec<u8>> {
        let mut bytes =
            serde_json::to_vec_pretty(self).map_err(|source| json_error(path, source))?;
        if scope == LockScope::Project {
            bytes.push(b'\n');
        }
        Ok(bytes)
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
    let mut lock: LockFile =
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
    // Internally the engine uses `skill_folder_hash` as the canonical content
    // hash. A project lock stores it under `computedHash`, so map it back so
    // update/inventory logic is consistent regardless of scope.
    if scope == LockScope::Project {
        for entry in lock.skills.values_mut() {
            if entry.skill_folder_hash.is_none() {
                entry.skill_folder_hash = entry.computed_hash.take();
            }
        }
    }
    Ok(lock)
}

pub fn write_lock_file(path: &Path, lock: &LockFile) -> Result<()> {
    let scope = if lock.version == GLOBAL_LOCK_VERSION {
        LockScope::Global
    } else {
        LockScope::Project
    };
    write_lock_file_for_scope(path, lock, scope)
}

pub fn write_lock_file_for_scope(path: &Path, lock: &LockFile, scope: LockScope) -> Result<()> {
    write_atomic(path, &lock.to_bytes_for_scope(path, scope)?)
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
    // Prefer a pure rename (atomic on POSIX and on Windows when the target is
    // absent). Only when the destination already exists on Windows do we fall
    // back to remove-then-rename, which still avoids the gap for the common
    // first-write path. A fully guaranteed `ReplaceFile` on Windows would
    // require unsafe FFI, which this crate forbids.
    if let Err(source) = fs::rename(&temporary, path) {
        if cfg!(windows) && path.exists() {
            let _ = fs::remove_file(path);
            fs::rename(&temporary, path).map_err(|second| {
                let _ = fs::remove_file(&temporary);
                io_error(path, second)
            })
        } else {
            let _ = fs::remove_file(&temporary);
            Err(io_error(path, source))
        }
    } else {
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum SourceType {
    Github,
    Gitlab,
    Git,
    Local,
    Direct,
    WellKnown,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct SkillSource {
    pub input: String,
    pub normalized: String,
    pub source_type: SourceType,
    pub source_url: String,
    pub ref_name: Option<String>,
    /// Repository subpath (`owner/repo/skills/demo` or `/tree/<ref>/...`).
    pub skill_path: Option<String>,
    /// Skill name from `@skill` / `#ref@skill` syntax. Not a lock `skillPath`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub skill_filter: Option<String>,
}

impl SkillSource {
    pub fn parse(input: &str) -> Result<Self> {
        let original = input.trim();
        if original.is_empty() {
            return Err(GinoError::InvalidSource {
                input: original.to_owned(),
                reason: "source is empty".to_owned(),
            });
        }
        if is_local_path(original) {
            let path = PathBuf::from(original);
            return Ok(skill_source(
                original,
                path.to_string_lossy().replace('\\', "/"),
                SourceType::Local,
                original,
                None,
                None,
                None,
            ));
        }

        let (without_fragment, fragment_ref, fragment_skill) = split_fragment(original);
        let current = resolve_alias(&without_fragment);

        if let Some(rest) = current.strip_prefix("github:") {
            let mut parsed = Self::parse(&append_fragment(
                rest,
                fragment_ref.as_deref(),
                fragment_skill.as_deref(),
            ))?;
            parsed.input = original.to_owned();
            return Ok(parsed);
        }
        if let Some(rest) = current.strip_prefix("gitlab:") {
            let mut parsed = Self::parse(&append_fragment(
                &format!("https://gitlab.com/{rest}"),
                fragment_ref.as_deref(),
                fragment_skill.as_deref(),
            ))?;
            parsed.input = original.to_owned();
            return Ok(parsed);
        }

        if let Some(parsed) = parse_github(&current, fragment_ref.as_deref())? {
            return Ok(with_original_input(parsed, original));
        }
        if let Some(parsed) = parse_gitlab_tree(&current, fragment_ref.as_deref())? {
            return Ok(with_original_input(parsed, original));
        }
        if let Some(parsed) = parse_gitlab_com(&current, fragment_ref.as_deref()) {
            return Ok(with_original_input(parsed, original));
        }
        if let Some(parsed) =
            parse_github_shorthand(&current, fragment_ref.as_deref(), fragment_skill.as_deref())?
        {
            return Ok(with_original_input(parsed, original));
        }
        if is_well_known_url(&current) {
            return Ok(skill_source(
                original,
                current.clone(),
                SourceType::WellKnown,
                current,
                None,
                None,
                None,
            ));
        }

        Ok(skill_source(
            original,
            current.trim_end_matches(".git").to_owned(),
            SourceType::Git,
            current,
            fragment_ref,
            None,
            None,
        ))
    }

    pub fn source_type_name(&self) -> &'static str {
        match self.source_type {
            SourceType::Github => "github",
            SourceType::Gitlab => "gitlab",
            SourceType::Git => "git",
            SourceType::Local => "local",
            SourceType::Direct => "direct",
            SourceType::WellKnown => "well-known",
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

    /// Produce a lock entry that already places `folder_hash` on the field
    /// used by the target scope, so the value is not rewritten later.
    pub fn lock_entry_for(&self, folder_hash: String, scope: LockScope) -> SkillLockEntry {
        let mut entry = self.lock_entry(folder_hash.clone());
        match scope {
            LockScope::Global => entry.computed_hash = None,
            LockScope::Project => {
                entry.computed_hash = Some(folder_hash);
                entry.skill_folder_hash = None;
            }
        }
        entry
    }
}

fn skill_source(
    original: &str,
    normalized: impl Into<String>,
    source_type: SourceType,
    source_url: impl Into<String>,
    ref_name: Option<String>,
    skill_path: Option<String>,
    skill_filter: Option<String>,
) -> SkillSource {
    SkillSource {
        input: original.to_owned(),
        normalized: normalized.into(),
        source_type,
        source_url: source_url.into(),
        ref_name,
        skill_path,
        skill_filter,
    }
}

fn with_original_input(mut parsed: SkillSource, original: &str) -> SkillSource {
    parsed.input = original.to_owned();
    parsed
}

fn is_local_path(input: &str) -> bool {
    input == "."
        || input == ".."
        || input.starts_with("./")
        || input.starts_with("../")
        || input.starts_with('/')
        || input.starts_with('~')
        || input.starts_with('\\')
        || (input.len() >= 3
            && input.as_bytes()[0].is_ascii_alphabetic()
            && input.as_bytes()[1] == b':'
            && (input.as_bytes()[2] == b'\\' || input.as_bytes()[2] == b'/'))
}

fn resolve_alias(input: &str) -> String {
    match input {
        "coinbase/agentWallet" => "coinbase/agentic-wallet-skills".to_owned(),
        _ => input.to_owned(),
    }
}

fn split_fragment(input: &str) -> (String, Option<String>, Option<String>) {
    let Some((base, fragment)) = input.split_once('#') else {
        return (input.to_owned(), None, None);
    };
    if fragment.is_empty() || !looks_like_git_source(base) {
        return (input.to_owned(), None, None);
    }
    if let Some((reference, skill)) = fragment.split_once('@') {
        (
            base.to_owned(),
            (!reference.is_empty()).then(|| decode_fragment(reference)),
            (!skill.is_empty()).then(|| decode_fragment(skill)),
        )
    } else {
        (base.to_owned(), Some(decode_fragment(fragment)), None)
    }
}

fn looks_like_git_source(input: &str) -> bool {
    if input.starts_with("github:") || input.starts_with("gitlab:") || input.starts_with("git@") {
        return true;
    }
    if input.len() >= 6 && input[..6].eq_ignore_ascii_case("ssh://") && git_suffix_present(input) {
        return true;
    }
    if let Some(rest) = input
        .strip_prefix("https://")
        .or_else(|| input.strip_prefix("http://"))
    {
        let (host, path) = rest.split_once('/').unwrap_or((rest, ""));
        let host = host.split('@').next_back().unwrap_or(host);
        let host = host.split(':').next().unwrap_or(host).to_ascii_lowercase();
        let path = format!("/{path}");
        if host == "github.com" {
            return github_path_is_repo_or_tree(&path);
        }
        if host == "gitlab.com" {
            return gitlab_path_is_repo_or_tree(&path);
        }
        return git_suffix_present(input);
    }
    !input.contains(':')
        && !input.starts_with('.')
        && !input.starts_with('/')
        && input.contains('/')
}

fn git_suffix_present(input: &str) -> bool {
    let before_query = input.split(['?', '#']).next().unwrap_or(input);
    before_query.ends_with(".git") || before_query.contains(".git/")
}

fn github_path_is_repo_or_tree(path: &str) -> bool {
    let path = path.split('?').next().unwrap_or(path).trim_end_matches('/');
    let parts: Vec<&str> = path.split('/').filter(|part| !part.is_empty()).collect();
    matches!(
        parts.as_slice(),
        [_, _] | [_, _, "tree", _] | [_, _, "tree", _, ..]
    )
}

fn gitlab_path_is_repo_or_tree(path: &str) -> bool {
    let path = path.split('?').next().unwrap_or(path).trim_end_matches('/');
    if let Some((repo, tree)) = path.split_once("/-/tree/") {
        return repo.contains('/') && !tree.is_empty();
    }
    let path = path.trim_start_matches('/');
    let path = path.strip_suffix(".git").unwrap_or(path);
    path.contains('/')
}

fn decode_fragment(value: &str) -> String {
    percent_decode(value).unwrap_or_else(|| value.to_owned())
}

fn percent_decode(value: &str) -> Option<String> {
    let mut bytes = Vec::new();
    let chars: Vec<char> = value.chars().collect();
    let mut index = 0;
    while index < chars.len() {
        if chars[index] == '%' && index + 2 < chars.len() {
            let hex: String = chars[index + 1..index + 3].iter().collect();
            bytes.push(u8::from_str_radix(&hex, 16).ok()?);
            index += 3;
        } else {
            let mut buffer = [0; 4];
            bytes.extend(chars[index].encode_utf8(&mut buffer).as_bytes());
            index += 1;
        }
    }
    String::from_utf8(bytes).ok()
}

fn append_fragment(input: &str, reference: Option<&str>, skill: Option<&str>) -> String {
    match (reference, skill) {
        (Some(reference), Some(skill)) => format!("{input}#{reference}@{skill}"),
        (Some(reference), None) => format!("{input}#{reference}"),
        _ => input.to_owned(),
    }
}

fn sanitize_subpath(subpath: &str) -> Result<String> {
    if subpath
        .replace('\\', "/")
        .split('/')
        .any(|segment| segment == "..")
    {
        return Err(GinoError::InvalidSource {
            input: subpath.to_owned(),
            reason: "subpath must not contain path traversal segments".to_owned(),
        });
    }
    Ok(subpath.to_owned())
}

fn parse_github(input: &str, fragment_ref: Option<&str>) -> Result<Option<SkillSource>> {
    let Some(index) = input.find("github.com/") else {
        return Ok(None);
    };
    let rest = input[index + "github.com/".len()..]
        .split('?')
        .next()
        .unwrap_or_default()
        .trim_end_matches('/');
    let parts: Vec<&str> = rest.split('/').filter(|part| !part.is_empty()).collect();
    if parts.len() < 2 {
        return Ok(None);
    }
    let owner = parts[0];
    let repo = parts[1].trim_end_matches(".git");
    if owner.is_empty() || repo.is_empty() {
        return Ok(None);
    }
    let normalized = format!("{owner}/{repo}");
    let source_url = format!("https://github.com/{owner}/{repo}.git");
    if parts.get(2) == Some(&"tree") && parts.len() >= 4 {
        let ref_name = parts[3].to_owned();
        let subpath = if parts.len() > 4 {
            Some(sanitize_subpath(&parts[4..].join("/"))?)
        } else {
            None
        };
        return Ok(Some(skill_source(
            input,
            normalized,
            SourceType::Github,
            source_url,
            Some(ref_name).or_else(|| fragment_ref.map(ToOwned::to_owned)),
            subpath,
            None,
        )));
    }
    Ok(Some(skill_source(
        input,
        normalized,
        SourceType::Github,
        source_url,
        fragment_ref.map(ToOwned::to_owned),
        None,
        None,
    )))
}

fn parse_gitlab_tree(input: &str, fragment_ref: Option<&str>) -> Result<Option<SkillSource>> {
    let Some((scheme, rest)) = input.split_once("://") else {
        return Ok(None);
    };
    if scheme != "http" && scheme != "https" {
        return Ok(None);
    }
    let Some((host, path)) = rest.split_once('/') else {
        return Ok(None);
    };
    if host.eq_ignore_ascii_case("github.com") {
        return Ok(None);
    }
    let marker = "/-/tree/";
    let Some(index) = path.find(marker) else {
        return Ok(None);
    };
    let repo_path = path[..index].trim_end_matches(".git");
    if repo_path.is_empty() {
        return Ok(None);
    }
    let after = path[index + marker.len()..]
        .split('?')
        .next()
        .unwrap_or_default();
    let mut parts = after.split('/');
    let Some(reference) = parts.next().filter(|part| !part.is_empty()) else {
        return Ok(None);
    };
    let subpath = parts.collect::<Vec<_>>().join("/");
    let skill_path = if subpath.is_empty() {
        None
    } else {
        Some(sanitize_subpath(&subpath)?)
    };
    Ok(Some(skill_source(
        input,
        repo_path.to_owned(),
        SourceType::Gitlab,
        format!("{scheme}://{host}/{repo_path}.git"),
        Some(reference.to_owned()).or_else(|| fragment_ref.map(ToOwned::to_owned)),
        skill_path,
        None,
    )))
}

fn parse_gitlab_com(input: &str, fragment_ref: Option<&str>) -> Option<SkillSource> {
    let index = input.find("gitlab.com/")?;
    let rest = input[index + "gitlab.com/".len()..]
        .split('?')
        .next()
        .unwrap_or_default();
    if rest.contains("/-/") {
        return None;
    }
    let rest = rest.trim_end_matches('/');
    let rest = rest.strip_suffix(".git").unwrap_or(rest);
    if rest.is_empty() || !rest.contains('/') {
        return None;
    }
    Some(skill_source(
        input,
        rest.to_owned(),
        SourceType::Gitlab,
        format!("https://gitlab.com/{rest}.git"),
        fragment_ref.map(ToOwned::to_owned),
        None,
        None,
    ))
}

fn parse_github_shorthand(
    input: &str,
    fragment_ref: Option<&str>,
    fragment_skill: Option<&str>,
) -> Result<Option<SkillSource>> {
    if input.contains(':') || input.starts_with('.') || input.starts_with('/') {
        return Ok(None);
    }
    if let Some((left, skill)) = input.split_once('@') {
        let mut parts = left.split('/');
        let owner = parts.next().unwrap_or_default();
        let repo = parts.next().unwrap_or_default();
        if parts.next().is_none() && !owner.is_empty() && !repo.is_empty() && !skill.is_empty() {
            return Ok(Some(skill_source(
                input,
                format!("{owner}/{repo}"),
                SourceType::Github,
                format!("https://github.com/{owner}/{repo}.git"),
                fragment_ref.map(ToOwned::to_owned),
                None,
                Some(fragment_skill.unwrap_or(skill).to_owned()),
            )));
        }
        return Ok(None);
    }
    let trimmed = input.trim_end_matches('/');
    let mut parts = trimmed.split('/');
    let owner = parts.next().unwrap_or_default();
    let repo = parts.next().unwrap_or_default();
    if owner.is_empty() || repo.is_empty() {
        return Ok(None);
    }
    let subpath = parts.collect::<Vec<_>>().join("/");
    let skill_path = if subpath.is_empty() {
        None
    } else {
        Some(sanitize_subpath(&subpath)?)
    };
    Ok(Some(skill_source(
        input,
        format!("{owner}/{repo}"),
        SourceType::Github,
        format!("https://github.com/{owner}/{repo}.git"),
        fragment_ref.map(ToOwned::to_owned),
        skill_path,
        fragment_skill.map(ToOwned::to_owned),
    )))
}

fn is_well_known_url(input: &str) -> bool {
    let rest = input
        .strip_prefix("https://")
        .or_else(|| input.strip_prefix("http://"));
    let Some(rest) = rest else {
        return false;
    };
    let host = rest.split('/').next().unwrap_or_default();
    let host = host.split('@').next_back().unwrap_or(host);
    let host = host.split(':').next().unwrap_or(host).to_ascii_lowercase();
    !matches!(
        host.as_str(),
        "github.com" | "gitlab.com" | "raw.githubusercontent.com"
    ) && !input.ends_with(".git")
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
    fn project_lock_matches_upstream_filename() {
        assert_eq!(
            project_lock_path(Path::new("/repo")),
            PathBuf::from("/repo/skills-lock.json")
        );
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
        assert_eq!(github.source_type, SourceType::Github);
        assert_eq!(github.normalized, "vercel-labs/agent-skills");
        assert_eq!(
            github.source_url,
            "https://github.com/vercel-labs/agent-skills.git"
        );
        assert_eq!(github.ref_name.as_deref(), Some("main"));
        assert_eq!(github.skill_path.as_deref(), Some("skills/demo"));
        assert_eq!(github.skill_filter, None);

        let shorthand =
            SkillSource::parse("vercel-labs/agent-skills@demo").expect("shorthand source");
        assert_eq!(shorthand.source_type, SourceType::Github);
        assert_eq!(shorthand.skill_path, None);
        assert_eq!(shorthand.skill_filter.as_deref(), Some("demo"));
        assert_eq!(
            shorthand.source_url,
            "https://github.com/vercel-labs/agent-skills.git"
        );

        let nested = SkillSource::parse("owner/repo/skills/demo").expect("nested");
        assert_eq!(nested.skill_path.as_deref(), Some("skills/demo"));
        assert_eq!(nested.skill_filter, None);

        let gitlab = SkillSource::parse("https://gitlab.com/group/repo/-/tree/main/skills/demo")
            .expect("gitlab");
        assert_eq!(gitlab.source_type, SourceType::Gitlab);
        assert_eq!(gitlab.normalized, "group/repo");
        assert_eq!(gitlab.source_url, "https://gitlab.com/group/repo.git");
        assert_eq!(gitlab.ref_name.as_deref(), Some("main"));
        assert_eq!(gitlab.skill_path.as_deref(), Some("skills/demo"));

        let well_known =
            SkillSource::parse("https://skills.example.com/catalog").expect("well-known");
        assert_eq!(well_known.source_type, SourceType::WellKnown);

        let prefixed = SkillSource::parse("github:owner/repo#main@demo").expect("prefixed");
        assert_eq!(prefixed.normalized, "owner/repo");
        assert_eq!(prefixed.ref_name.as_deref(), Some("main"));
        assert_eq!(prefixed.skill_filter.as_deref(), Some("demo"));
        assert_eq!(prefixed.skill_path, None);
    }

    #[test]
    fn parses_upstream_source_parser_fixtures() {
        let custom =
            SkillSource::parse("https://git.corp.com/group/subgroup/project/-/tree/main/src")
                .expect("custom gitlab");
        assert_eq!(custom.source_type, SourceType::Gitlab);
        assert_eq!(custom.normalized, "group/subgroup/project");
        assert_eq!(
            custom.source_url,
            "https://git.corp.com/group/subgroup/project.git"
        );
        assert_eq!(custom.ref_name.as_deref(), Some("main"));
        assert_eq!(custom.skill_path.as_deref(), Some("src"));

        let branch_only =
            SkillSource::parse("https://gitlab.example.com/org/repo/-/tree/v1.0").expect("branch");
        assert_eq!(branch_only.source_type, SourceType::Gitlab);
        assert_eq!(
            branch_only.source_url,
            "https://gitlab.example.com/org/repo.git"
        );
        assert_eq!(branch_only.ref_name.as_deref(), Some("v1.0"));
        assert_eq!(branch_only.skill_path, None);

        let with_port =
            SkillSource::parse("https://git.corp.com:8443/group/repo/-/tree/main").expect("port");
        assert_eq!(with_port.source_type, SourceType::Gitlab);
        assert_eq!(
            with_port.source_url,
            "https://git.corp.com:8443/group/repo.git"
        );

        let http = SkillSource::parse("http://git.local/group/repo/-/tree/dev").expect("http");
        assert_eq!(http.source_url, "http://git.local/group/repo.git");

        let personal =
            SkillSource::parse("https://gitlab.com/~user/project/-/tree/main").expect("personal");
        assert_eq!(personal.source_url, "https://gitlab.com/~user/project.git");

        let custom_git =
            SkillSource::parse("https://git.mycompany.com/my-group/my-repo.git").expect("git");
        assert_eq!(custom_git.source_type, SourceType::Git);
        assert_eq!(
            custom_git.source_url,
            "https://git.mycompany.com/my-group/my-repo.git"
        );

        let generic = SkillSource::parse("https://google.com/search/result").expect("well-known");
        assert_eq!(generic.source_type, SourceType::WellKnown);

        let gitlab_com = SkillSource::parse("https://gitlab.com/owner/repo").expect("gitlab.com");
        assert_eq!(gitlab_com.source_type, SourceType::Gitlab);
        assert_eq!(gitlab_com.source_url, "https://gitlab.com/owner/repo.git");

        let subgroup = SkillSource::parse("https://gitlab.com/group/subgroup/repo").expect("sub");
        assert_eq!(subgroup.normalized, "group/subgroup/repo");
        assert_eq!(
            subgroup.source_url,
            "https://gitlab.com/group/subgroup/repo.git"
        );

        let gitlab_prefix = SkillSource::parse("gitlab:group/repo#main").expect("gitlab prefix");
        assert_eq!(gitlab_prefix.source_type, SourceType::Gitlab);
        assert_eq!(gitlab_prefix.ref_name.as_deref(), Some("main"));

        let blob = SkillSource::parse("https://github.com/owner/repo/blob/main/README.md#L10")
            .expect("blob");
        assert_eq!(blob.source_type, SourceType::Github);
        assert_eq!(blob.ref_name, None);
        assert_eq!(blob.skill_path, None);

        let hashed = SkillSource::parse("vercel-labs/agent-skills#feature/install").expect("hash");
        assert_eq!(hashed.ref_name.as_deref(), Some("feature/install"));
        assert_eq!(hashed.skill_path, None);

        let trailing = SkillSource::parse("vercel-labs/agent-skills/").expect("slash");
        assert_eq!(trailing.normalized, "vercel-labs/agent-skills");
        assert_eq!(trailing.skill_path, None);

        let ssh = SkillSource::parse("git@github.com:owner/repo.git#feature/install").expect("ssh");
        assert_eq!(ssh.source_type, SourceType::Git);
        assert_eq!(ssh.source_url, "git@github.com:owner/repo.git");
        assert_eq!(ssh.ref_name.as_deref(), Some("feature/install"));

        let alias = SkillSource::parse("coinbase/agentWallet").expect("alias");
        assert_eq!(alias.normalized, "coinbase/agentic-wallet-skills");

        let local = SkillSource::parse("./skills/demo").expect("local");
        assert_eq!(local.source_type, SourceType::Local);

        assert!(SkillSource::parse("owner/repo/foo/../escape").is_err());
    }

    #[test]
    fn global_and_project_locks_use_distinct_schema_and_versions() {
        let global_path = tempdir().expect("global").path().join("g.json");
        let project_path = tempdir().expect("project").path().join("p.json");
        let source = SkillSource::parse("owner/repo@demo").expect("source");

        let mut global = LockFile::empty(LockScope::Global);
        global.set_skill("demo", source.lock_entry("abc".to_owned()));
        write_lock_file(&global_path, &global).expect("write global");
        let global_text = fs::read_to_string(&global_path).expect("read global");
        assert!(global_text.contains("\"skillFolderHash\""));
        assert!(!global_text.contains("computedHash"));
        assert!(global_text.contains("\"version\": 3"));
        assert!(global_text.contains("\"dismissed\""));

        let mut project = LockFile::empty(LockScope::Project);
        project.set_skill(
            "demo",
            source.lock_entry_for("def".to_owned(), LockScope::Project),
        );
        project.normalize_for_scope(LockScope::Project);
        write_lock_file(&project_path, &project).expect("write project");
        let project_text = fs::read_to_string(&project_path).expect("read project");
        assert!(project_text.contains("\"computedHash\""));
        assert!(!project_text.contains("skillFolderHash"));
        assert!(project_text.contains("\"version\": 1"));
        assert!(project_text.ends_with('\n'));

        // The project lock is intentionally minimal and timestamp-free
        // (upstream `local-lock.ts`): no prompt state, no agent selection,
        // no install/update timestamps, and no serialized null fields.
        for forbidden in [
            "installedAt",
            "updatedAt",
            "dismissed",
            "lastSelectedAgents",
            "pluginName",
            "null",
        ] {
            assert!(
                !project_text.contains(forbidden),
                "project lock must not contain {forbidden}"
            );
        }
        // The global lock never emits prompt-state nulls either.
        let global_without_dismissed = LockFile::empty(LockScope::Global);
        let global_bytes = global_without_dismissed
            .to_bytes_for_scope(&global_path, LockScope::Global)
            .expect("serialize global");
        let global_text = String::from_utf8(global_bytes).expect("utf8");
        assert!(!global_text.contains("null"));
        assert!(!global_text.ends_with('\n'));

        // Re-reading maps the project hash back to the canonical field.
        let reread = read_lock_file(&project_path, LockScope::Project).expect("reread project");
        assert_eq!(
            reread.skills["demo"].skill_folder_hash.as_deref(),
            Some("def")
        );
    }

    #[test]
    fn project_computed_hash_includes_metadata_but_skip_git_and_node_modules() {
        let root = tempdir().expect("skill");
        fs::write(
            root.path().join("SKILL.md"),
            "---\nname: demo\ndescription: Demo\n---\n",
        )
        .expect("skill file");
        fs::write(root.path().join("metadata.json"), "ignored").expect("metadata");

        let before = project_computed_hash(root.path()).expect("hash");
        fs::write(root.path().join("metadata.json"), "changed").expect("change metadata");
        let after = project_computed_hash(root.path()).expect("hash");
        // Project computedHash is NOT stable under metadata.json changes.
        assert_ne!(before, after);

        // `.git` and `node_modules` remain excluded for the project hash.
        let stable = project_computed_hash(root.path()).expect("hash");
        fs::create_dir(root.path().join("node_modules")).expect("node_modules");
        fs::write(root.path().join("node_modules/x"), "ignored").expect("nm file");
        assert_eq!(project_computed_hash(root.path()).expect("hash"), stable);
    }
}
