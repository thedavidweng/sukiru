//! Official `skills` CLI vs Gino installer — layout, files, and project lock.
//!
//! Off by default (no Node, no network). CI and local e2e:
//!
//! ```text
//! GINO_E2E=1 cargo test --test e2e_cli_diff -- --ignored --nocapture
//! ```
//!
//! Uses `bunx skills@latest` when `bunx` is on PATH, otherwise `npx --yes skills@latest`.
//! The fixture source is https://github.com/thedavidweng/skills (`stale-docs-cleanup`).

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use gino_core::discovery::discover_skills;
use gino_core::executor::ApplyExecutor;
use gino_core::inventory::Inventory;
use gino_core::planner::{InstallMode, Planner};
use gino_core::protocol::{
    LockScope, SkillSource, collect_project_skill_files, project_computed_hash, project_lock_path,
    read_lock_file,
};
use gino_core::source::SourceCache;
use tempfile::tempdir;

const SOURCE_REPO: &str = "thedavidweng/skills";
const SOURCE_URL: &str = "https://github.com/thedavidweng/skills";
const SKILL_NAME: &str = "stale-docs-cleanup";

#[test]
#[ignore = "network e2e: GINO_E2E=1 cargo test --test e2e_cli_diff -- --ignored --nocapture"]
fn official_cli_and_gino_install_the_same_example_skill() {
    if std::env::var("GINO_E2E").ok().as_deref() != Some("1") {
        eprintln!("skipping: set GINO_E2E=1 to run the official-CLI differential");
        return;
    }

    let runner = skills_runner().unwrap_or_else(|| {
        panic!("need bunx or npx on PATH to run skills@latest");
    });
    let workspace = tempdir().expect("e2e workspace");
    let cli_home = workspace.path().join("cli-home");
    let cli_project = workspace.path().join("cli-project");
    let gino_home = workspace.path().join("gino-home");
    let gino_project = workspace.path().join("gino-project");
    fs::create_dir_all(&cli_home).expect("cli home");
    fs::create_dir_all(&cli_project).expect("cli project");
    fs::create_dir_all(cli_project.join(".git")).expect("cli project marker");
    fs::create_dir_all(&gino_home).expect("gino home");
    fs::create_dir_all(&gino_project).expect("gino project");

    let cli_status = run_official_add(&runner, &cli_home, &cli_project);
    assert!(
        cli_status.success(),
        "official skills add failed\n{}",
        last_cli_log(&cli_project)
    );

    let cli_skill = find_installed_skill(&cli_project, SKILL_NAME)
        .expect("CLI should install the example skill");
    let cli_lock_path = project_lock_path(&cli_project);
    assert!(
        cli_lock_path.is_file(),
        "official CLI should write {}",
        cli_lock_path.display()
    );

    install_with_gino(&gino_home, &gino_project);
    let gino_skill = find_installed_skill(&gino_project, SKILL_NAME)
        .expect("Gino should install the example skill");
    let gino_lock_path = project_lock_path(&gino_project);
    assert!(
        gino_lock_path.is_file(),
        "Gino should write {}",
        gino_lock_path.display()
    );

    let cli_files = file_map(&cli_skill);
    let gino_files = file_map(&gino_skill);
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

    let cli_hash = project_computed_hash(&cli_skill).expect("cli hash");
    let gino_hash = project_computed_hash(&gino_skill).expect("gino hash");
    assert_eq!(cli_hash, gino_hash, "project computedHash of files differs");

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
        Some(cli_hash.as_str()),
        "official computedHash should match on-disk project hash"
    );
    assert_eq!(
        gino_entry.skill_folder_hash.as_deref(),
        Some(gino_hash.as_str()),
        "Gino computedHash should match on-disk project hash"
    );
    if let (Some(cli_path), Some(gino_path)) = (&cli_entry.skill_path, &gino_entry.skill_path) {
        assert_eq!(
            normalize_skill_path(cli_path),
            normalize_skill_path(gino_path)
        );
    }

    let cli_names = discover_skills(&cli_project, false)
        .expect("discover cli")
        .skills
        .into_iter()
        .map(|skill| skill.metadata.name)
        .collect::<Vec<_>>();
    let gino_names = discover_skills(&gino_project, false)
        .expect("discover gino")
        .skills
        .into_iter()
        .map(|skill| skill.metadata.name)
        .collect::<Vec<_>>();
    assert_eq!(cli_names, gino_names);
}

struct SkillsRunner {
    program: String,
    prefix: Vec<String>,
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

fn run_official_add(
    runner: &SkillsRunner,
    home: &Path,
    project: &Path,
) -> std::process::ExitStatus {
    let mut command = Command::new(&runner.program);
    command.args(&runner.prefix).args([
        "add",
        SOURCE_REPO,
        "--skill",
        SKILL_NAME,
        "--agent",
        "universal",
        "--copy",
        "--yes",
    ]);
    command.current_dir(project);
    command.env("HOME", home);
    command.env("USERPROFILE", home);
    command.env("XDG_CONFIG_HOME", home.join(".config"));
    command.env("XDG_STATE_HOME", home.join(".state"));
    command.env("CI", "1");
    command.env("SKILLS_TELEMETRY", "0");
    let output = command.output().expect("spawn official skills");
    let log = project.join("official-skills.log");
    let body = format!(
        "status={}\nstdout:\n{}\nstderr:\n{}\n",
        output.status,
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let _ = fs::write(log, body);
    output.status
}

fn last_cli_log(project: &Path) -> String {
    fs::read_to_string(project.join("official-skills.log")).unwrap_or_default()
}

fn install_with_gino(home: &Path, project: &Path) {
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

    let destination = project.join(".agents/skills").join(SKILL_NAME);
    let lock_path = project_lock_path(project);
    let inventory = Inventory::empty();
    let planner = Planner::new(
        &inventory,
        vec![project.to_path_buf(), resolved.root.clone()],
    );
    let plan = planner
        .install_source(
            &install_source,
            &skill.path,
            &destination,
            InstallMode::Copy,
            Some((lock_path.as_path(), LockScope::Project)),
        )
        .expect("plan install");
    assert!(plan.can_apply(), "gino plan blocked: {:?}", plan.blockers);
    ApplyExecutor::new(home.join("snapshots"), 4)
        .apply(&plan)
        .expect("apply gino install");
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
