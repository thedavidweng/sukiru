//! Official `skills` CLI vs Gino — differential e2e suite (spec §23.5).
//!
//! Off by default (no Node, no network). CI and local e2e:
//!
//! ```text
//! GINO_E2E=1 cargo test --test e2e_cli_diff -- --ignored --nocapture
//! ```
//!
//! Uses `bunx skills@latest` when `bunx` is on PATH, otherwise `npx --yes skills@latest`.
//! The fixture source is https://github.com/thedavidweng/skills (`stale-docs-cleanup`).
//!
//! Scenarios:
//!
//! 1. `official_cli_and_gino_install_the_same_example_skill` — project scope,
//!    universal agent, copy mode: layout, files, hash, lock entry, discovery.
//! 2. `project_agent_target_copy_matches_official_cli` — `--agent claude-code`
//!    installs into `.claude/skills`, not the universal root.
//! 3. `global_scope_copy_matches_official_cli` — `-g` installs under the home
//!    directory and writes the v3 global lock (honoring `XDG_STATE_HOME`).
//! 4. `symlink_layout_matches_official_cli` — default link mode keeps the
//!    canonical copy in `.agents/skills` and symlinks each agent directory.
//! 5. `remove_matches_official_cli` — Gino's inventory → planner → executor
//!    remove pipeline reaches the same end state as `skills remove`.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use gino_core::discovery::discover_skills;
use gino_core::executor::ApplyExecutor;
use gino_core::inventory::{Inventory, Workspace, WorkspaceKind};
use gino_core::planner::{InstallMode, Planner};
use gino_core::protocol::{
    LockScope, SkillSource, collect_project_skill_files, project_computed_hash, project_lock_path,
    read_lock_file, skill_folder_hash,
};
use gino_core::source::SourceCache;
use tempfile::tempdir;

const SOURCE_REPO: &str = "thedavidweng/skills";
const SOURCE_URL: &str = "https://github.com/thedavidweng/skills";
const SKILL_NAME: &str = "stale-docs-cleanup";

#[test]
#[ignore = "network e2e: GINO_E2E=1 cargo test --test e2e_cli_diff -- --ignored --nocapture"]
fn official_cli_and_gino_install_the_same_example_skill() {
    if !e2e_enabled() {
        return;
    }
    let runner = require_runner();
    let sandbox = Sandbox::new();

    let status = run_official(
        &runner,
        &sandbox.cli_home,
        &sandbox.cli_project,
        &add_args(&["universal"], true),
    );
    assert!(
        status.success(),
        "official skills add failed\n{}",
        sandbox.cli_log()
    );
    let cli_skill = find_installed_skill(&sandbox.cli_project, SKILL_NAME)
        .expect("CLI should install the example skill");

    let (install_source, skill_dir, resolved_root) = resolve_fixture_skill(&sandbox.gino_home);
    gino_install(
        &sandbox.gino_home,
        &[&sandbox.gino_project, &resolved_root],
        &install_source,
        &skill_dir,
        &sandbox.gino_project.join(".agents/skills").join(SKILL_NAME),
        InstallMode::Copy,
        Some((project_lock_path(&sandbox.gino_project), LockScope::Project)),
    );
    let gino_skill = find_installed_skill(&sandbox.gino_project, SKILL_NAME)
        .expect("Gino should install the example skill");

    assert_identical_trees(&cli_skill, &gino_skill);

    let cli_hash = project_computed_hash(&cli_skill).expect("cli hash");
    let gino_hash = project_computed_hash(&gino_skill).expect("gino hash");
    assert_eq!(cli_hash, gino_hash, "project computedHash of files differs");

    assert_project_lock_parity(&sandbox.cli_project, &sandbox.gino_project, &cli_hash);
    assert_discovery_parity(&sandbox.cli_project, &sandbox.gino_project);
}

#[test]
#[ignore = "network e2e: GINO_E2E=1 cargo test --test e2e_cli_diff -- --ignored --nocapture"]
fn project_agent_target_copy_matches_official_cli() {
    if !e2e_enabled() {
        return;
    }
    let runner = require_runner();
    let sandbox = Sandbox::new();

    let status = run_official(
        &runner,
        &sandbox.cli_home,
        &sandbox.cli_project,
        &add_args(&["claude-code"], true),
    );
    assert!(
        status.success(),
        "official skills add failed\n{}",
        sandbox.cli_log()
    );
    let cli_skill = find_installed_skill(&sandbox.cli_project, SKILL_NAME)
        .expect("CLI should install the example skill");
    assert!(
        cli_skill.starts_with(sandbox.cli_project.join(".claude").join("skills")),
        "CLI --agent claude-code should target .claude/skills, got {}",
        cli_skill.display()
    );

    let (install_source, skill_dir, resolved_root) = resolve_fixture_skill(&sandbox.gino_home);
    let gino_destination = sandbox.gino_project.join(".claude/skills").join(SKILL_NAME);
    gino_install(
        &sandbox.gino_home,
        &[&sandbox.gino_project, &resolved_root],
        &install_source,
        &skill_dir,
        &gino_destination,
        InstallMode::Copy,
        Some((project_lock_path(&sandbox.gino_project), LockScope::Project)),
    );
    let gino_skill = find_installed_skill(&sandbox.gino_project, SKILL_NAME)
        .expect("Gino should install the example skill");
    assert_eq!(
        gino_skill
            .strip_prefix(&sandbox.gino_project)
            .ok()
            .and_then(|path| path.to_str()),
        cli_skill
            .strip_prefix(&sandbox.cli_project)
            .ok()
            .and_then(|path| path.to_str()),
        "installed relative layout differs"
    );

    assert_identical_trees(&cli_skill, &gino_skill);
    let cli_hash = project_computed_hash(&cli_skill).expect("cli hash");
    assert_project_lock_parity(&sandbox.cli_project, &sandbox.gino_project, &cli_hash);
    assert_discovery_parity(&sandbox.cli_project, &sandbox.gino_project);
}

#[test]
#[ignore = "network e2e: GINO_E2E=1 cargo test --test e2e_cli_diff -- --ignored --nocapture"]
fn global_scope_copy_matches_official_cli() {
    if !e2e_enabled() {
        return;
    }
    let runner = require_runner();
    let sandbox = Sandbox::new();

    // `-g` is what makes this a global install.
    let status = run_official(
        &runner,
        &sandbox.cli_home,
        &sandbox.cli_home,
        &add_args_opt(&["universal"], true, Some("-g")),
    );
    assert!(
        status.success(),
        "official global add failed\n{}",
        sandbox.cli_log()
    );

    // `run_official` hands the CLI `XDG_STATE_HOME=<home>/.state`; upstream and
    // Gino both place the global lock at `$XDG_STATE_HOME/skills/.skill-lock.json`
    // in that case (see `global_lock_path`).
    let cli_lock_path = sandbox_global_lock(&sandbox.cli_home);
    assert!(
        cli_lock_path.is_file(),
        "official CLI should write {}",
        cli_lock_path.display()
    );
    let cli_canonical = sandbox.cli_home.join(".agents/skills").join(SKILL_NAME);
    assert!(cli_canonical.join("SKILL.md").is_file());

    let (install_source, skill_dir, resolved_root) = resolve_fixture_skill(&sandbox.gino_home);
    let gino_destination = sandbox.gino_home.join(".agents/skills").join(SKILL_NAME);
    gino_install(
        &sandbox.gino_home,
        // The home root declares the global install destination and lock path.
        &[&sandbox.gino_home, &resolved_root],
        &install_source,
        &skill_dir,
        &gino_destination,
        InstallMode::Copy,
        Some((sandbox_global_lock(&sandbox.gino_home), LockScope::Global)),
    );

    assert_identical_trees(&cli_canonical, &gino_destination);
    assert_discovery_parity(&sandbox.cli_home, &sandbox.gino_home);

    let gino_hash = skill_folder_hash(&gino_destination).expect("gino hash");
    let cli_lock = read_lock_file(&cli_lock_path, LockScope::Global).expect("cli lock");
    let gino_lock = read_lock_file(&sandbox_global_lock(&sandbox.gino_home), LockScope::Global)
        .expect("gino lock");
    assert_eq!(cli_lock.version, gino_lock.version);
    let cli_entry = cli_lock.skills.get(SKILL_NAME).expect("cli lock entry");
    let gino_entry = gino_lock.skills.get(SKILL_NAME).expect("gino lock entry");
    assert_eq!(
        normalize_source(&cli_entry.source),
        normalize_source(&gino_entry.source)
    );
    assert_eq!(cli_entry.source_type, gino_entry.source_type);
    assert_eq!(
        cli_entry.skill_path.as_deref().map(normalize_skill_path),
        gino_entry.skill_path.as_deref().map(normalize_skill_path)
    );
    // Upstream stores a git tree SHA on `skillFolderHash` in the global lock;
    // Gino stores its deterministic local hash as a documented proxy. Values
    // are intentionally not compared — only presence and self-consistency.
    assert!(
        cli_entry.skill_folder_hash.is_some(),
        "official global lock should carry skillFolderHash"
    );
    assert_eq!(
        gino_entry.skill_folder_hash.as_deref(),
        Some(gino_hash.as_str()),
        "Gino global lock hash should match the installed files"
    );
    assert!(
        cli_entry.computed_hash.is_none() && gino_entry.computed_hash.is_none(),
        "computedHash is a project-scope field"
    );
}

#[test]
#[ignore = "network e2e: GINO_E2E=1 cargo test --test e2e_cli_diff -- --ignored --nocapture"]
fn symlink_layout_matches_official_cli() {
    if !e2e_enabled() {
        return;
    }
    let runner = require_runner();
    let sandbox = Sandbox::new();

    // No --copy: upstream's default keeps one canonical copy and links agents to it.
    let status = run_official(
        &runner,
        &sandbox.cli_home,
        &sandbox.cli_project,
        &add_args(&["universal", "claude-code"], false),
    );
    assert!(
        status.success(),
        "official skills add failed\n{}",
        sandbox.cli_log()
    );

    let cli_canonical = sandbox.cli_project.join(".agents/skills").join(SKILL_NAME);
    let cli_link = sandbox.cli_project.join(".claude/skills").join(SKILL_NAME);
    assert!(
        cli_canonical.join("SKILL.md").is_file(),
        "CLI should keep the canonical copy in .agents/skills"
    );
    let cli_link_metadata = fs::symlink_metadata(&cli_link).expect("cli agent link");
    assert!(
        cli_link_metadata.file_type().is_symlink(),
        "CLI default mode should symlink the agent directory"
    );
    assert_eq!(
        fs::canonicalize(&cli_link).expect("resolve cli link"),
        fs::canonicalize(&cli_canonical).expect("resolve cli canonical"),
    );

    let (install_source, skill_dir, resolved_root) = resolve_fixture_skill(&sandbox.gino_home);
    let gino_canonical = sandbox.gino_project.join(".agents/skills").join(SKILL_NAME);
    gino_install(
        &sandbox.gino_home,
        &[&sandbox.gino_project, &resolved_root],
        &install_source,
        &skill_dir,
        &gino_canonical,
        InstallMode::Copy,
        Some((project_lock_path(&sandbox.gino_project), LockScope::Project)),
    );
    // Second pending change: link the agent directory at the canonical copy,
    // mirroring how the app plans an agent placement for an existing install.
    gino_install(
        &sandbox.gino_home,
        &[&sandbox.gino_project],
        &install_source,
        &gino_canonical,
        &sandbox.gino_project.join(".claude/skills").join(SKILL_NAME),
        InstallMode::Link,
        None,
    );

    let gino_link = sandbox.gino_project.join(".claude/skills").join(SKILL_NAME);
    let gino_link_metadata = fs::symlink_metadata(&gino_link).expect("gino agent link");
    assert!(
        gino_link_metadata.file_type().is_symlink(),
        "Gino Link mode should produce a symlink"
    );
    assert_eq!(
        fs::canonicalize(&gino_link).expect("resolve gino link"),
        fs::canonicalize(&gino_canonical).expect("resolve gino canonical"),
    );

    assert_identical_trees(&cli_canonical, &gino_canonical);
    // Discovery must see exactly one logical skill despite dir + link placements.
    for project in [&sandbox.cli_project, &sandbox.gino_project] {
        let names = discovered_names(project);
        assert_eq!(
            names,
            vec![SKILL_NAME.to_owned()],
            "discovery in {project:?}"
        );
    }
    let cli_hash = project_computed_hash(&cli_canonical).expect("cli hash");
    assert_project_lock_parity(&sandbox.cli_project, &sandbox.gino_project, &cli_hash);
}

#[test]
#[ignore = "network e2e: GINO_E2E=1 cargo test --test e2e_cli_diff -- --ignored --nocapture"]
fn remove_matches_official_cli() {
    if !e2e_enabled() {
        return;
    }
    let runner = require_runner();
    let sandbox = Sandbox::new();
    let install_args = add_args(&["universal", "claude-code"], false);

    let status = run_official(
        &runner,
        &sandbox.cli_home,
        &sandbox.cli_project,
        &install_args,
    );
    assert!(
        status.success(),
        "official skills add failed\n{}",
        sandbox.cli_log()
    );
    let status = run_official(
        &runner,
        &sandbox.cli_home,
        &sandbox.cli_project,
        &[
            "remove".to_owned(),
            SKILL_NAME.to_owned(),
            "--yes".to_owned(),
        ],
    );
    assert!(
        status.success(),
        "official remove failed\n{}",
        sandbox.cli_log()
    );

    // Gino side: same install shape (canonical copy + agent link), then the
    // full product pipeline — rescan inventory, plan the removal from real
    // placements, apply it as one batch.
    let (install_source, skill_dir, resolved_root) = resolve_fixture_skill(&sandbox.gino_home);
    gino_install(
        &sandbox.gino_home,
        &[&sandbox.gino_project, &resolved_root],
        &install_source,
        &skill_dir,
        &sandbox.gino_project.join(".agents/skills").join(SKILL_NAME),
        InstallMode::Copy,
        Some((project_lock_path(&sandbox.gino_project), LockScope::Project)),
    );
    gino_install(
        &sandbox.gino_home,
        &[&sandbox.gino_project],
        &install_source,
        &sandbox.gino_project.join(".agents/skills").join(SKILL_NAME),
        &sandbox.gino_project.join(".claude/skills").join(SKILL_NAME),
        InstallMode::Link,
        None,
    );

    let workspaces = vec![
        Workspace::new(
            "project",
            "Project",
            WorkspaceKind::Project,
            sandbox.gino_project.clone(),
        )
        .with_lock(project_lock_path(&sandbox.gino_project), LockScope::Project),
    ];
    let inventory = Inventory::empty().rescan(&workspaces).expect("rescan");
    let placements = inventory.by_name(SKILL_NAME);
    assert_eq!(
        placements.len(),
        2,
        "inventory should track the canonical copy and the agent link"
    );
    let planner = Planner::new(&inventory, vec![sandbox.gino_project.clone()]);
    let plan = planner.remove(&placements).expect("plan remove");
    assert!(plan.can_apply(), "remove plan blocked: {:?}", plan.blockers);
    ApplyExecutor::new(sandbox.gino_home.join("snapshots"), 4)
        .apply(&plan)
        .expect("apply gino remove");

    // Both sandboxes must end with no trace of the skill outside .git and an
    // emptied project lock.
    assert_eq!(
        remaining_files(&sandbox.cli_project),
        remaining_files(&sandbox.gino_project),
        "post-remove file sets differ"
    );
    assert!(
        !remaining_files(&sandbox.gino_project)
            .iter()
            .any(|path| path.contains(SKILL_NAME)),
        "skill files survived the removal"
    );
    let gino_lock = read_lock_file(
        &project_lock_path(&sandbox.gino_project),
        LockScope::Project,
    )
    .expect("gino lock after remove");
    assert!(
        gino_lock.skills.is_empty(),
        "Gino lock should drop the removed entry"
    );
    let cli_lock = read_lock_file(&project_lock_path(&sandbox.cli_project), LockScope::Project)
        .expect("cli lock after remove");
    assert!(
        cli_lock.skills.is_empty(),
        "official lock should drop the removed entry"
    );
}

// --- harness -------------------------------------------------------------

struct SkillsRunner {
    program: String,
    prefix: Vec<String>,
}

fn e2e_enabled() -> bool {
    if std::env::var("GINO_E2E").ok().as_deref() == Some("1") {
        return true;
    }
    eprintln!("skipping: set GINO_E2E=1 to run the official-CLI differential");
    false
}

fn require_runner() -> SkillsRunner {
    skills_runner().expect("need bunx or npx on PATH to run skills@latest")
}

fn skills_runner() -> Option<SkillsRunner> {
    if command_exists("bunx") {
        return Some(SkillsRunner {
            program: "bunx".to_owned(),
            prefix: vec!["skills@latest".to_owned()],
        });
    }
    if command_exists("npx") {
        return Some(SkillsRunner {
            program: "npx".to_owned(),
            prefix: vec!["--yes".to_owned(), "skills@latest".to_owned()],
        });
    }
    None
}

fn command_exists(name: &str) -> bool {
    Command::new(name)
        .arg("--version")
        .output()
        .map(|output| output.status.success())
        .unwrap_or(false)
}

/// Isolated pair of sandboxes: one driven by the official CLI, one by Gino.
/// Each side gets its own HOME so global state cannot leak between runs.
struct Sandbox {
    _root: tempfile::TempDir,
    cli_home: PathBuf,
    cli_project: PathBuf,
    gino_home: PathBuf,
    gino_project: PathBuf,
}

impl Sandbox {
    fn new() -> Self {
        let root = tempdir().expect("e2e workspace");
        let cli_home = root.path().join("cli-home");
        let cli_project = root.path().join("cli-project");
        let gino_home = root.path().join("gino-home");
        let gino_project = root.path().join("gino-project");
        fs::create_dir_all(&cli_home).expect("cli home");
        fs::create_dir_all(&cli_project).expect("cli project");
        fs::create_dir_all(cli_project.join(".git")).expect("cli project marker");
        fs::create_dir_all(&gino_home).expect("gino home");
        fs::create_dir_all(&gino_project).expect("gino project");
        fs::create_dir_all(gino_project.join(".git")).expect("gino project marker");
        Self {
            _root: root,
            cli_home,
            cli_project,
            gino_home,
            gino_project,
        }
    }

    fn cli_log(&self) -> String {
        fs::read_to_string(self.cli_home.join("official-skills.log")).unwrap_or_default()
    }
}

fn add_args(agents: &[&str], copy: bool) -> Vec<String> {
    add_args_opt(agents, copy, None)
}

/// Global lock location matching the `XDG_STATE_HOME` that `run_official`
/// exports: `<home>/.state/skills/.skill-lock.json`.
fn sandbox_global_lock(home: &Path) -> PathBuf {
    home.join(".state/skills/.skill-lock.json")
}

fn add_args_opt(agents: &[&str], copy: bool, extra: Option<&str>) -> Vec<String> {
    let mut args = vec![
        "add".to_owned(),
        SOURCE_REPO.to_owned(),
        "--skill".to_owned(),
        SKILL_NAME.to_owned(),
    ];
    for agent in agents {
        args.push("--agent".to_owned());
        args.push((*agent).to_owned());
    }
    if copy {
        args.push("--copy".to_owned());
    }
    if let Some(extra) = extra {
        args.push(extra.to_owned());
    }
    args.push("--yes".to_owned());
    args
}

/// Serialize official CLI invocations across tests. `bunx` shares one global
/// install cache (`$BUN_INSTALL`, not `$HOME`), so concurrent cold starts race
/// and fail with "could not determine executable". Tests otherwise stay parallel.
fn cli_serial() -> std::sync::MutexGuard<'static, ()> {
    static LOCK: std::sync::OnceLock<std::sync::Mutex<()>> = std::sync::OnceLock::new();
    LOCK.get_or_init(|| std::sync::Mutex::new(()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn run_official(
    runner: &SkillsRunner,
    home: &Path,
    cwd: &Path,
    args: &[String],
) -> std::process::ExitStatus {
    let _serial = cli_serial();
    let mut command = Command::new(&runner.program);
    command.args(&runner.prefix).args(args);
    command.current_dir(cwd);
    command.env("HOME", home);
    command.env("USERPROFILE", home);
    command.env("XDG_CONFIG_HOME", home.join(".config"));
    command.env("XDG_STATE_HOME", home.join(".state"));
    command.env("CI", "1");
    command.env("SKILLS_TELEMETRY", "0");
    let output = command.output().expect("spawn official skills");
    let log = home.join("official-skills.log");
    let body = format!(
        "status={}\nstdout:\n{}\nstderr:\n{}\n",
        output.status,
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let _ = fs::write(log, body);
    output.status
}

/// Resolve the fixture skill through Gino's source cache and derive the
/// subdirectory-qualified install source, exactly like the marketplace flow.
fn resolve_fixture_skill(home: &Path) -> (SkillSource, PathBuf, PathBuf) {
    let source = SkillSource::parse(&format!("{SOURCE_REPO}@{SKILL_NAME}")).expect("parse source");
    let cache = SourceCache::new(home.join("source-cache"));
    let resolved = cache.resolve(&source).expect("resolve source");
    let discovered = cache.discover(&source, false).expect("discover");
    let skill = discovered
        .skills
        .iter()
        .find(|item| item.metadata.name == SKILL_NAME)
        .unwrap_or_else(|| panic!("source {SOURCE_URL} should contain {SKILL_NAME}"));
    let mut install_source = source.clone();
    if let Ok(relative) = skill.path.strip_prefix(&resolved.root) {
        let relative = relative
            .components()
            .filter_map(|component| match component {
                std::path::Component::Normal(value) => Some(value.to_string_lossy().into_owned()),
                _ => None,
            })
            .collect::<Vec<_>>()
            .join("/");
        if !relative.is_empty() {
            install_source.skill_path = Some(if relative.ends_with("SKILL.md") {
                relative
            } else {
                format!("{relative}/SKILL.md")
            });
        }
    }
    (install_source, skill.path.clone(), resolved.root.clone())
}

fn gino_install(
    home: &Path,
    declared_roots: &[&Path],
    install_source: &SkillSource,
    skill_dir: &Path,
    destination: &Path,
    mode: InstallMode,
    lock: Option<(PathBuf, LockScope)>,
) {
    let inventory = Inventory::empty();
    let planner = Planner::new(
        &inventory,
        declared_roots
            .iter()
            .map(|root| root.to_path_buf())
            .collect(),
    );
    let plan = planner
        .install_source(
            install_source,
            skill_dir,
            destination,
            mode,
            lock.as_ref().map(|(path, scope)| (path.as_path(), *scope)),
        )
        .expect("plan install");
    assert!(plan.can_apply(), "gino plan blocked: {:?}", plan.blockers);
    ApplyExecutor::new(home.join("snapshots"), 4)
        .apply(&plan)
        .expect("apply gino install");
}

fn assert_identical_trees(cli_skill: &Path, gino_skill: &Path) {
    let cli_files = file_map(cli_skill);
    let gino_files = file_map(gino_skill);
    assert_eq!(
        cli_files.keys().collect::<Vec<_>>(),
        gino_files.keys().collect::<Vec<_>>(),
        "installed file lists differ"
    );
    for (path, bytes) in &cli_files {
        assert_eq!(
            gino_files.get(path),
            Some(bytes),
            "file contents differ: {path}"
        );
    }
}

fn assert_project_lock_parity(cli_project: &Path, gino_project: &Path, expected_hash: &str) {
    let cli_lock_path = project_lock_path(cli_project);
    let gino_lock_path = project_lock_path(gino_project);
    assert!(
        cli_lock_path.is_file(),
        "official CLI should write {}",
        cli_lock_path.display()
    );
    assert!(
        gino_lock_path.is_file(),
        "Gino should write {}",
        gino_lock_path.display()
    );
    let cli_lock = read_lock_file(&cli_lock_path, LockScope::Project).expect("cli lock");
    let gino_lock = read_lock_file(&gino_lock_path, LockScope::Project).expect("gino lock");
    assert_eq!(cli_lock.version, gino_lock.version);
    let cli_entry = cli_lock.skills.get(SKILL_NAME).expect("cli lock entry");
    let gino_entry = gino_lock.skills.get(SKILL_NAME).expect("gino lock entry");
    assert_eq!(cli_entry.source_type, gino_entry.source_type);
    assert_eq!(
        normalize_source(&cli_entry.source),
        normalize_source(&gino_entry.source)
    );
    assert_eq!(
        cli_entry.skill_folder_hash.as_deref(),
        Some(expected_hash),
        "official computedHash should match on-disk project hash"
    );
    assert_eq!(
        gino_entry.skill_folder_hash.as_deref(),
        Some(expected_hash),
        "Gino computedHash should match on-disk project hash"
    );
    if let (Some(cli_path), Some(gino_path)) = (&cli_entry.skill_path, &gino_entry.skill_path) {
        assert_eq!(
            normalize_skill_path(cli_path),
            normalize_skill_path(gino_path)
        );
    }
}

fn assert_discovery_parity(cli_root: &Path, gino_root: &Path) {
    assert_eq!(discovered_names(cli_root), discovered_names(gino_root));
}

fn discovered_names(root: &Path) -> Vec<String> {
    discover_skills(root, false)
        .unwrap_or_else(|error| panic!("discover {root:?}: {error}"))
        .skills
        .into_iter()
        .map(|skill| skill.metadata.name)
        .collect()
}

fn find_installed_skill(root: &Path, name: &str) -> Option<PathBuf> {
    let discovered = discover_skills(root, true).ok()?;
    discovered
        .skills
        .into_iter()
        .find(|skill| skill.metadata.name == name)
        .map(|skill| skill.path)
}

fn file_map(skill_dir: &Path) -> BTreeMap<String, Vec<u8>> {
    collect_project_skill_files(skill_dir)
        .expect("collect skill files")
        .into_iter()
        .map(|file| (file.relative_path, file.bytes))
        .collect()
}

/// Relative regular-file paths under `root`, ignoring `.git`. Used to prove
/// two sandboxes reached the same end state without comparing empty dirs.
fn remaining_files(root: &Path) -> BTreeSet<String> {
    fn walk(dir: &Path, prefix: &str, out: &mut BTreeSet<String>) {
        for entry in fs::read_dir(dir).expect("read dir") {
            let entry = entry.expect("dir entry");
            let name = entry.file_name().to_string_lossy().into_owned();
            if name == ".git" {
                continue;
            }
            let path = entry.path();
            let relative = if prefix.is_empty() {
                name
            } else {
                format!("{prefix}/{name}")
            };
            if path.is_dir()
                && !fs::symlink_metadata(&path)
                    .expect("lstat")
                    .file_type()
                    .is_symlink()
            {
                walk(&path, &relative, out);
            } else if path.is_file() {
                out.insert(relative);
            }
        }
    }
    let mut out = BTreeSet::new();
    walk(root, "", &mut out);
    out
}

fn normalize_source(source: &str) -> String {
    source
        .trim()
        .trim_end_matches('/')
        .trim_end_matches(".git")
        .to_ascii_lowercase()
}

fn normalize_skill_path(path: &str) -> String {
    path.trim()
        .trim_end_matches("/SKILL.md")
        .trim_end_matches("\\SKILL.md")
        .replace('\\', "/")
}
