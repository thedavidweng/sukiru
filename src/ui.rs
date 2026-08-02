use std::collections::BTreeSet;

use gino_core::executor::ApplyExecutor;
use gino_core::inventory::{Inventory, InventoryScanner, SkillState, Workspace};
use gino_core::planner::{PendingChanges, Planner};
use gpui::{
    Context, Entity, InteractiveElement, IntoElement, ParentElement, Render, SharedString,
    StatefulInteractiveElement, Styled, Window, div, prelude::FluentBuilder, px, rgb,
};
use gpui_component::{
    Icon, IconName, StyledExt,
    scroll::ScrollableElement,
    sidebar::{Sidebar, SidebarMenu, SidebarMenuItem},
};

const NAVIGATION: &[(&str, IconName)] = &[
    ("Library", IconName::LayoutDashboard),
    ("Marketplace", IconName::Globe),
    ("Global", IconName::Globe),
    ("Projects", IconName::Folder),
    ("Agents", IconName::Bot),
    ("Custom Workspaces", IconName::FolderOpen),
    ("Duplicates", IconName::Copy),
    ("Presets", IconName::Star),
    ("Backup", IconName::GitHub),
    ("Activity", IconName::Inbox),
    ("Settings", IconName::Settings),
];

pub struct GinoWindow {
    workspaces: Vec<Workspace>,
    inventory: Inventory,
    active_section: String,
    selected_names: BTreeSet<String>,
    pending: PendingChanges,
    refresh_error: Option<String>,
    action_error: Option<String>,
}

impl GinoWindow {
    pub fn new(workspaces: Vec<Workspace>, inventory: Inventory) -> Self {
        Self {
            workspaces,
            inventory,
            active_section: "Library".to_owned(),
            selected_names: BTreeSet::new(),
            pending: PendingChanges::default(),
            refresh_error: None,
            action_error: None,
        }
    }

    fn refresh(&mut self) {
        match InventoryScanner::new(&self.workspaces)
            .scan(self.inventory.generation.saturating_add(1))
        {
            Ok(inventory) => {
                self.inventory = inventory;
                self.refresh_error = None;
                self.selected_names.retain(|name| {
                    self.inventory
                        .placements
                        .iter()
                        .any(|placement| &placement.name == name)
                });
                self.pending.mark_unavailable();
            }
            Err(error) => self.refresh_error = Some(error.to_string()),
        }
    }

    fn toggle_selected(&mut self, name: &str) {
        if !self.selected_names.insert(name.to_owned()) {
            self.selected_names.remove(name);
        }
    }

    fn queue_remove_selected(&mut self) {
        let placements = self
            .inventory
            .placements
            .iter()
            .filter(|placement| self.selected_names.contains(&placement.name))
            .collect::<Vec<_>>();
        if placements.is_empty() {
            return;
        }
        let planner = Planner::new(&self.inventory, self.declared_roots());
        match planner.remove(&placements) {
            Ok(plan) => {
                self.pending.add_plan(&plan);
                self.selected_names.clear();
                self.action_error = None;
            }
            Err(error) => self.action_error = Some(error.to_string()),
        }
    }

    fn apply_pending(&mut self) {
        if self.pending.items().is_empty() {
            return;
        }
        let plan = self
            .pending
            .plan(self.inventory.generation, self.declared_roots());
        let snapshot_root = std::env::temp_dir().join("gino-snapshots");
        let executor =
            ApplyExecutor::new(snapshot_root, 10).with_workspaces(self.workspaces.clone());
        match executor.apply(&plan) {
            Ok(_) => {
                self.pending.clear();
                self.action_error = None;
                self.refresh();
            }
            Err(error) => self.action_error = Some(error.to_string()),
        }
    }

    fn declared_roots(&self) -> Vec<std::path::PathBuf> {
        self.workspaces
            .iter()
            .flat_map(|workspace| {
                let lock_root = workspace
                    .lock
                    .as_ref()
                    .and_then(|lock| lock.path.parent())
                    .map(std::path::Path::to_path_buf);
                std::iter::once(workspace.root.clone()).chain(lock_root)
            })
            .collect()
    }

    fn visible_placements(&self) -> Vec<&gino_core::inventory::SkillPlacement> {
        let duplicate_indexes = self
            .inventory
            .duplicate_groups
            .iter()
            .flat_map(|group| group.placement_indexes.iter().copied())
            .collect::<BTreeSet<_>>();
        self.inventory
            .placements
            .iter()
            .enumerate()
            .filter(|(index, placement)| match self.active_section.as_str() {
                "Global" => placement.workspace_kind == gino_core::inventory::WorkspaceKind::Global,
                "Projects" => {
                    placement.workspace_kind == gino_core::inventory::WorkspaceKind::Project
                }
                "Agents" => placement.workspace_kind == gino_core::inventory::WorkspaceKind::Agent,
                "Custom Workspaces" => {
                    placement.workspace_kind == gino_core::inventory::WorkspaceKind::Custom
                }
                "Duplicates" => duplicate_indexes.contains(index),
                _ => true,
            })
            .map(|(_, placement)| placement)
            .collect()
    }
}

impl Render for GinoWindow {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let entity = cx.entity();
        let sidebar = Sidebar::left()
            .collapsible(false)
            .child(
                SidebarMenu::new().children(NAVIGATION.iter().map(|(label, icon)| {
                    navigation_item(
                        entity.clone(),
                        label,
                        icon.clone(),
                        self.active_section == *label,
                    )
                })),
            );
        let refresh_entity = entity.clone();
        let refresh = div()
            .id("refresh")
            .cursor_pointer()
            .on_click(move |_, _, cx| {
                refresh_entity.update(cx, |window, _| window.refresh());
            })
            .px_3()
            .py_1()
            .rounded_md()
            .text_sm()
            .text_color(rgb(0x475569))
            .hover(|this| this.bg(rgb(0xe2e8f0)))
            .child("Refresh");
        let remove_entity = entity.clone();
        let remove_selected = div()
            .id("remove-selected")
            .cursor_pointer()
            .on_click(move |_, _, cx| {
                remove_entity.update(cx, |window, _| window.queue_remove_selected());
            })
            .px_3()
            .py_1()
            .rounded_md()
            .text_sm()
            .text_color(rgb(0x475569))
            .hover(|this| this.bg(rgb(0xe2e8f0)))
            .child("Queue Remove");
        let apply_entity = entity.clone();
        let apply_pending = div()
            .id("apply-pending")
            .cursor_pointer()
            .on_click(move |_, _, cx| {
                apply_entity.update(cx, |window, _| window.apply_pending());
            })
            .px_3()
            .py_1()
            .rounded_md()
            .text_sm()
            .text_color(rgb(0x1d4ed8))
            .hover(|this| this.bg(rgb(0xdbeafe)))
            .child(format!("Apply {}", self.pending.items().len()));
        let content = self.render_content(entity.clone(), refresh, remove_selected, apply_pending);
        div()
            .size_full()
            .bg(rgb(0xf8fafc))
            .text_color(rgb(0x0f172a))
            .child(sidebar)
            .child(content)
    }
}

fn navigation_item(
    entity: Entity<GinoWindow>,
    label: &str,
    icon: IconName,
    active: bool,
) -> SidebarMenuItem {
    let label = label.to_owned();
    SidebarMenuItem::new(label.clone())
        .icon(Icon::new(icon))
        .active(active)
        .on_click(move |_, _, cx| {
            entity.update(cx, |window, _| window.active_section = label.clone());
        })
}

impl GinoWindow {
    fn render_content(
        &self,
        entity: Entity<GinoWindow>,
        refresh: impl IntoElement,
        remove_selected: impl IntoElement,
        apply_pending: impl IntoElement,
    ) -> impl IntoElement {
        let visible_placements = self.visible_placements();
        let rows = visible_placements
            .iter()
            .enumerate()
            .map(|(index, placement)| {
                let selected = self.selected_names.contains(&placement.name);
                let name = placement.name.clone();
                let row_entity = entity.clone();
                div()
                    .id(SharedString::from(format!("skill-row-{index}")))
                    .cursor_pointer()
                    .on_click(move |_, _, cx| {
                        row_entity.update(cx, |window, _| window.toggle_selected(&name));
                    })
                    .h(px(56.))
                    .w_full()
                    .px_4()
                    .gap_x_3()
                    .items_center()
                    .border_b_1()
                    .border_color(rgb(0xe2e8f0))
                    .when(selected, |this| this.bg(rgb(0xeff6ff)))
                    .child(selection_box(selected))
                    .child(div().w_64().font_medium().child(placement.name.clone()))
                    .child(
                        div()
                            .flex_1()
                            .text_sm()
                            .text_color(rgb(0x64748b))
                            .child(placement.description.clone()),
                    )
                    .child(status_badge(placement.state.clone()))
                    .child(
                        div()
                            .w(px(110.))
                            .text_xs()
                            .text_color(rgb(0x94a3b8))
                            .child(format!("{:?}", placement.workspace_kind)),
                    )
            });
        let empty = visible_placements.is_empty();
        let body = if empty {
            div()
                .flex_1()
                .items_center()
                .justify_center()
                .flex()
                .flex_col()
                .gap_2()
                .child(div().text_lg().font_medium().child("No Skills discovered"))
                .child(
                    div()
                        .text_sm()
                        .text_color(rgb(0x64748b))
                        .child("Refresh after installing a Skill with the official CLI."),
                )
                .into_any_element()
        } else {
            div()
                .flex_1()
                .children(rows)
                .overflow_y_scrollbar()
                .into_any_element()
        };
        let refresh_error = self.refresh_error.clone().unwrap_or_default();
        let action_error = self.action_error.clone().unwrap_or_default();
        let issue_summary = if self.inventory.issues.is_empty() {
            String::new()
        } else {
            format!("{} scan issues", self.inventory.issues.len())
        };
        div()
            .flex_1()
            .h_full()
            .flex()
            .flex_col()
            .child(
                div()
                    .h_16()
                    .w_full()
                    .px_6()
                    .items_center()
                    .flex()
                    .gap_x_3()
                    .border_b_1()
                    .border_color(rgb(0xe2e8f0))
                    .child(
                        div()
                            .flex_1()
                            .text_xl()
                            .font_semibold()
                            .child(self.active_section.clone()),
                    )
                    .child(
                        div()
                            .text_sm()
                            .text_color(rgb(0x64748b))
                            .child(format!("{} placements", self.inventory.placements.len())),
                    )
                    .child(
                        div()
                            .text_xs()
                            .text_color(rgb(0xb45309))
                            .child(issue_summary),
                    )
                    .child(
                        div()
                            .flex_1()
                            .text_xs()
                            .text_color(rgb(0xb91c1c))
                            .child(format!("{refresh_error} {action_error}")),
                    )
                    .child(remove_selected)
                    .child(refresh)
                    .child(apply_pending)
                    .child(
                        div()
                            .text_sm()
                            .text_color(rgb(0x2563eb))
                            .child(format!("{} pending", self.pending.items().len())),
                    ),
            )
            .child(
                div()
                    .h_10()
                    .w_full()
                    .px_4()
                    .items_center()
                    .flex()
                    .gap_x_3()
                    .bg(rgb(0xf1f5f9))
                    .text_xs()
                    .font_medium()
                    .text_color(rgb(0x64748b))
                    .child(selection_box(false))
                    .child("Skill")
                    .child(div().flex_1().child("Description"))
                    .child("State")
                    .child("Workspace"),
            )
            .child(body)
    }
}

fn selection_box(selected: bool) -> impl IntoElement {
    div()
        .size_4()
        .rounded_sm()
        .border_1()
        .border_color(if selected {
            rgb(0x2563eb)
        } else {
            rgb(0x94a3b8)
        })
        .when(selected, |this| this.bg(rgb(0x2563eb)).child("✓"))
}

fn status_badge(state: SkillState) -> impl IntoElement {
    let (label, background, foreground) = match state {
        SkillState::Managed => ("Managed", 0xdcfce7, 0x166534),
        SkillState::Untracked => ("Untracked", 0xfef3c7, 0x92400e),
    };
    div()
        .w_20()
        .rounded_full()
        .px_2()
        .py_1()
        .text_xs()
        .text_color(rgb(foreground))
        .bg(rgb(background))
        .child(label)
}
