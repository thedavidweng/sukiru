mod ui;

use gino_core::agents::AgentRegistry;
use gino_core::git::GitRepository;
use gino_core::inventory::{Inventory, InventoryScanner, Workspace, WorkspaceKind};
use gino_core::protocol::global_lock_path;
use gpui::{App, AppContext, Application, Bounds, WindowBounds, WindowOptions, px, size};

use ui::GinoWindow;

fn main() {
    let (workspaces, inventory) = initial_inventory();
    let home = AgentRegistry::default().home().to_path_buf();
    let backup = GitRepository::open_or_init(home.join(".gino/backup"));
    Application::new().run(move |cx: &mut App| {
        gpui_component::init(cx);
        let bounds = Bounds::centered(None, size(px(1_280.), px(820.)), cx);
        cx.open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                ..Default::default()
            },
            move |_, cx| cx.new(|_| GinoWindow::new(workspaces, inventory, backup)),
        )
        .expect("Gino window should open");
        cx.activate(true);
    });
}

fn initial_inventory() -> (Vec<Workspace>, Inventory) {
    let registry = AgentRegistry::default();
    let lock_path = global_lock_path(registry.home());
    let canonical_root = registry.home().join(".agents/skills");
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
    let inventory = match InventoryScanner::new(&workspaces).scan(1) {
        Ok(inventory) => inventory,
        Err(error) => Inventory::with_issue(1, registry.home().to_path_buf(), error.to_string()),
    };
    (workspaces, inventory)
}
