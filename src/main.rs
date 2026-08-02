mod ui;

use gino_core::agents::AgentRegistry;
use gino_core::inventory::{Inventory, InventoryIssue, InventoryScanner, Workspace, WorkspaceKind};
use gino_core::protocol::global_lock_path;
use gpui::{App, AppContext, Application, Bounds, WindowBounds, WindowOptions, px, size};

use ui::GinoWindow;

fn main() {
    let (workspaces, inventory) = initial_inventory();
    Application::new().run(move |cx: &mut App| {
        gpui_component::init(cx);
        let bounds = Bounds::centered(None, size(px(1_280.), px(820.)), cx);
        cx.open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                ..Default::default()
            },
            move |_, cx| cx.new(|_| GinoWindow::new(workspaces, inventory)),
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
    let inventory = InventoryScanner::new(&workspaces)
        .scan(1)
        .unwrap_or_else(|error| Inventory {
            issues: vec![InventoryIssue {
                path: registry.home().to_path_buf(),
                reason: error.to_string(),
            }],
            ..Inventory::empty()
        });
    (workspaces, inventory)
}
