mod ui;

use gino_core::agents::AgentRegistry;
use gino_core::git::GitRepository;
use gino_core::inventory::{Inventory, Workspace, WorkspaceKind};
use gino_core::metadata::{MetadataStore, Preferences};
use gino_core::protocol::global_lock_path;
use gpui::{
    App, AppContext, Application, Bounds, TitlebarOptions, WindowBounds, WindowOptions, px, size,
};
use gpui_component::Root;

use ui::GinoWindow;
use ui::session::expand_registered_workspace;

fn main() {
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
    let inventory = Inventory::empty();
    let backup = GitRepository::open_or_init(home.join(".gino/backup"));
    // Startup performs one fetch when a remote is configured (§16.5). The
    // fetch is best-effort: a failed fetch must not block the session.
    if let Ok(repository) = &backup {
        if !preferences.backup_remote.is_empty() {
            if let Err(error) = repository.fetch() {
                eprintln!("gino: startup fetch failed: {error}");
            }
        }
    }
    Application::new().run(move |cx: &mut App| {
        gpui_component::init(cx);
        let bounds = Bounds::centered(None, size(px(1_280.), px(820.)), cx);
        cx.open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                window_min_size: Some(size(px(880.), px(560.))),
                titlebar: Some(TitlebarOptions {
                    title: Some("Gino".into()),
                    appears_transparent: false,
                    traffic_light_position: None,
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
                cx.new(|cx| Root::new(view, window, cx))
            },
        )
        .expect("Gino window should open");
        cx.activate(true);
    });
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
    workspaces
}
