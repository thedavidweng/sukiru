mod ui;

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use gino_core::agents::AgentRegistry;
use gino_core::executor::ApplyExecutor;
use gino_core::git::{GitRepository, PushMode};
use gino_core::inventory::{Inventory, InventoryScanner, PlacementKind, Workspace, WorkspaceKind};
use gino_core::metadata::{MetadataStore, Preferences};
use gino_core::planner::Planner;
use gino_core::protocol::global_lock_path;
use gpui::{
    AnyWindowHandle, App, AppContext, Application, Bounds, Entity, Global, KeyBinding, Menu,
    MenuItem, WindowBounds, WindowOptions, px, size,
};
use gpui_component::Root;

use ui::session::expand_registered_workspace;
use ui::{GinoWindow, QuitApp};

/// Handles to the single app window and its inner view. The component `Root`
/// owns `GinoWindow`, so nothing in the element tree exposes it; storing the
/// handles globally lets the app-level `QuitApp` listener reach the view no
/// matter which input or dialog holds focus.
struct GinoWindowHandles {
    window: AnyWindowHandle,
    view: Entity<GinoWindow>,
}

impl Global for GinoWindowHandles {}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("clean-broken") => clean_broken_cli(&args[1..]),
        Some(other) => {
            eprintln!(
                "gino: unknown command `{other}`\n\
                 \n\
                 Usage:\n\
                 \x20 gino                          open the desktop app\n\
                 \x20 gino clean-broken [--apply]   report dangling skill symlinks\n\
                 \x20                               (dry run unless --apply)"
            );
            std::process::exit(2);
        }
        None => run_app(),
    }
}

/// Workspace list and preferences shared by the GUI session and the CLI so
/// both surfaces see exactly the same scan roots.
fn load_session_inputs() -> (
    PathBuf,
    PathBuf,
    Option<MetadataStore>,
    Preferences,
    Vec<Workspace>,
) {
    let home = AgentRegistry::default().home().to_path_buf();
    let metadata_path = home.join(".gino/state.sqlite");
    let metadata = MetadataStore::open(&metadata_path).ok();
    // Preferences (theme, editor, snapshot root at ~/.gino/snapshots, proxy,
    // push mode, …) come from the UI-only SQLite store. Missing rows use
    // `Preferences::default()` and never invent installed Skill state.
    let preferences: Preferences = metadata
        .as_ref()
        .and_then(|store| store.preferences().ok())
        .unwrap_or_default();
    let mut workspaces = default_workspaces(&home);
    if let Some(store) = &metadata {
        match store.workspaces() {
            Ok(registered) => {
                workspaces.extend(registered.into_iter().flat_map(expand_registered_workspace))
            }
            Err(error) => eprintln!("gino: could not load registered workspaces: {error}"),
        }
    }
    (home, metadata_path, metadata, preferences, workspaces)
}

fn run_app() {
    let (home, metadata_path, _metadata, preferences, workspaces) = load_session_inputs();
    let inventory = Inventory::empty();
    // Local backup is opt-in: with the flag off there is no repository on
    // disk and no fetch/commit ever happens. A lazy handle keeps the session
    // wiring unchanged; enabling the toggle in Settings materializes it.
    let backup = if preferences.backup_enabled {
        GitRepository::open_or_init(home.join(".gino/backup"))
    } else {
        Ok(GitRepository::open(home.join(".gino/backup")))
    };
    // Startup performs one fetch when a remote is configured (§16.5). The
    // fetch is best-effort: a failed fetch must not block the session.
    if preferences.backup_enabled {
        if let Ok(repository) = &backup {
            if !preferences.backup_remote.is_empty() {
                if let Err(error) = repository.fetch() {
                    eprintln!("gino: startup fetch failed: {error}");
                }
            }
        }
    }
    Application::new()
        .with_assets(gpui_component_assets::Assets)
        .run(move |cx: &mut App| {
            gpui_component::init(cx);
            // Native macOS alignment: the menu bar and its ⌘Q equivalent are
            // app-provided in GPUI (nothing registers defaults), so wire the
            // standard app-menu Quit to the same gated flow as `q`.
            cx.bind_keys([KeyBinding::new("cmd-q", QuitApp, None)]);
            cx.set_menus(vec![Menu {
                name: "Gino".into(),
                items: vec![MenuItem::action("Quit Gino", QuitApp)],
            }]);
            // Global QuitApp fallback: fires whenever no element along the
            // focus path handles the action, so ⌘Q and the menu item work
            // even with a text input or dialog focused.
            cx.on_action(|_: &QuitApp, cx| {
                if let Some(handles) = cx.try_global::<GinoWindowHandles>() {
                    let window = handles.window;
                    let view = handles.view.clone();
                    let _ = window.update(cx, |_, window, cx| {
                        view.update(cx, |app, cx| app.request_quit(window, cx))
                    });
                }
            });
            let bounds = Bounds::centered(None, size(px(1_280.), px(820.)), cx);
            cx.open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(bounds)),
                    window_min_size: Some(size(px(880.), px(560.))),
                    titlebar: Some({
                        let mut options = gpui_component::TitleBar::title_bar_options();
                        options.title = Some("Gino".into());
                        options
                    }),
                    app_id: Some("app.gino.desktop".into()),
                    ..Default::default()
                },
                move |window, cx| {
                    let view = cx.new(|cx| {
                        GinoWindow::new(
                            workspaces,
                            inventory,
                            backup,
                            metadata_path,
                            preferences,
                            window,
                            cx,
                        )
                    });
                    cx.set_global(GinoWindowHandles {
                        window: window.window_handle(),
                        view: view.clone(),
                    });
                    cx.new(|cx| Root::new(view, window, cx))
                },
            )
            .expect("Gino window should open");
            cx.activate(true);
        });
}

/// Headless cleanup of dangling skill symlinks through the same pipeline as
/// the GUI: inventory scan → planner → executor (snapshot + git backup).
/// Dry run by default; `--apply` performs the removals.
fn clean_broken_cli(args: &[String]) {
    let apply = args.iter().any(|flag| flag == "--apply");
    for flag in args {
        if !matches!(flag.as_str(), "--apply" | "--dry-run") {
            eprintln!("gino: unknown flag `{flag}` (expected --apply or --dry-run)");
            std::process::exit(2);
        }
    }

    let (home, _, metadata, preferences, workspaces) = load_session_inputs();
    let inventory = match InventoryScanner::new(&workspaces).scan(1) {
        Ok(inventory) => inventory,
        Err(error) => {
            eprintln!("gino: scan failed: {error}");
            std::process::exit(1);
        }
    };
    let broken = inventory
        .placements
        .iter()
        .filter(|placement| placement.placement_kind == PlacementKind::BrokenSymlink)
        .cloned()
        .collect::<Vec<_>>();
    if broken.is_empty() {
        if inventory.issues.is_empty() {
            println!("No broken symlinks found; no scan issues.");
        } else {
            println!(
                "No broken symlinks found; {} unrelated scan issue(s) remain \
                 (see the Library banner in the app).",
                inventory.issues.len()
            );
        }
        return;
    }

    let mut tally: BTreeMap<&str, usize> = BTreeMap::new();
    for placement in &broken {
        let label = workspaces
            .iter()
            .find(|workspace| workspace.id == placement.workspace_id)
            .map(|workspace| workspace.display_name.as_str())
            .unwrap_or(placement.workspace_id.as_str());
        *tally.entry(label).or_default() += 1;
    }

    let mode = if apply { "APPLY" } else { "DRY RUN" };
    println!("gino clean-broken — {mode}");
    println!(
        "{} dangling symlinks across {} locations:",
        broken.len(),
        tally.len()
    );
    for (label, count) in &tally {
        println!("  {label:<28} {count:>5}");
    }
    println!("  sample:");
    for placement in broken.iter().take(5) {
        println!(
            "    rm {}  (→ {})",
            compact_home(&home, &placement.path.to_string_lossy()),
            placement
                .link_target
                .as_ref()
                .map(|target| target.to_string_lossy().to_string())
                .unwrap_or_else(|| "?".to_owned())
        );
    }
    if broken.len() > 5 {
        println!("    … and {} more", broken.len() - 5);
    }
    if !inventory.issues.is_empty() {
        println!(
            "  note: {} unrelated scan issue(s) remain (see the Library banner in the app)",
            inventory.issues.len()
        );
    }
    if preferences.backup_enabled {
        println!("  safety: snapshot + git backup are taken before any change.");
    } else {
        println!(
            "  safety: a transaction snapshot is taken before any change (local git backup is off in Settings)."
        );
    }

    if !apply {
        println!("Nothing was written. Re-run with --apply to perform the removals.");
        return;
    }

    let declared_roots = declared_roots(&workspaces);
    let plan = match Planner::new(&inventory, declared_roots).cleanup_broken_symlinks() {
        Ok(plan) => plan,
        Err(error) => {
            eprintln!("gino: planning failed: {error}");
            std::process::exit(1);
        }
    };
    if !plan.blockers.is_empty() {
        for blocker in &plan.blockers {
            eprintln!("gino: blocked: {blocker}");
        }
        std::process::exit(1);
    }

    let backup = if preferences.backup_enabled {
        match GitRepository::open_or_init(home.join(".gino/backup")) {
            Ok(repository) => Some(repository),
            Err(error) => {
                eprintln!("gino: cannot open backup repo: {error}");
                std::process::exit(1);
            }
        }
    } else {
        None
    };
    let push_mode = if preferences.commit_locally() {
        PushMode::CommitLocally
    } else {
        PushMode::CommitAndPush
    };
    let mut executor = ApplyExecutor::new(
        preferences.snapshot_root.clone(),
        preferences.snapshot_retention,
    )
    .with_workspaces(workspaces.clone());
    if let Some(repository) = backup {
        executor = executor.with_git(repository, push_mode);
    }
    if let Some(store) = metadata {
        if let Ok(backup_metadata) = store.backup_metadata() {
            executor = executor.with_backup_metadata(backup_metadata);
        }
        executor = executor.with_metadata(store);
    }
    match executor.apply(&plan) {
        Ok(result) => {
            println!(
                "Applied {} change(s); snapshot {}{}.",
                plan.operation_count(),
                result.snapshot_id,
                result
                    .commit_id
                    .map(|commit| format!(", commit {commit}"))
                    .unwrap_or_default(),
            );
        }
        Err(error) => {
            eprintln!("gino: apply failed: {error}");
            std::process::exit(1);
        }
    }

    // Rescan so the reported remainder reflects reality, not assumptions.
    let remaining = InventoryScanner::new(&workspaces)
        .scan(2)
        .map(|fresh| {
            fresh
                .placements
                .iter()
                .filter(|placement| placement.placement_kind == PlacementKind::BrokenSymlink)
                .count()
        })
        .unwrap_or_else(|_| broken.len());
    println!("Broken symlinks remaining after rescan: {remaining}");
}

fn declared_roots(workspaces: &[Workspace]) -> Vec<PathBuf> {
    workspaces
        .iter()
        .flat_map(|workspace| {
            let lock_root = workspace
                .lock
                .as_ref()
                .and_then(|lock| lock.path.parent())
                .map(Path::to_path_buf);
            std::iter::once(workspace.root.clone()).chain(lock_root)
        })
        .collect()
}

fn compact_home(home: &Path, text: &str) -> String {
    match home.to_str() {
        Some(home_str) if !home_str.is_empty() && home_str != "/" && text.contains(home_str) => {
            text.replace(home_str, "~")
        }
        _ => text.to_owned(),
    }
}

fn default_workspaces(home: &std::path::Path) -> Vec<Workspace> {
    let registry = AgentRegistry::default();
    let lock_path = global_lock_path(home);
    let canonical_root = home.join(".agents/skills");
    let mut workspaces = vec![
        Workspace::new("global", "Global", WorkspaceKind::Global, &canonical_root)
            .with_lock(&lock_path, gino_core::protocol::LockScope::Global),
    ];

    for (agent, root) in registry.global_skill_roots() {
        if root != canonical_root {
            workspaces.push(
                Workspace::new(
                    format!("agent:{}", agent.id.0),
                    agent.display_name.clone(),
                    WorkspaceKind::Agent,
                    root,
                )
                .with_agent(agent.id.clone())
                .with_lock(&lock_path, gino_core::protocol::LockScope::Global),
            );
        }
    }
    // Leftover skills directories of clients that are not installed stay
    // scannable (their dangling links must remain cleanable) but are flagged
    // so the UI keeps the agent out of lists and install targets.
    for (agent, root) in registry.leftover_global_skill_roots() {
        if root != canonical_root {
            workspaces.push(
                Workspace::new(
                    format!("agent:{}", agent.id.0),
                    agent.display_name.clone(),
                    WorkspaceKind::Agent,
                    root,
                )
                .with_agent(agent.id.clone())
                .with_lock(&lock_path, gino_core::protocol::LockScope::Global)
                .with_installed(false),
            );
        }
    }
    workspaces
}
