use gino_core::inventory::WorkspaceKind;
use gpui::{
    Context, Entity, IntoElement, ParentElement, SharedString, Styled, Window, div,
    prelude::FluentBuilder as _,
};
use gpui_component::{
    ActiveTheme, Sizable as _,
    button::{Button, ButtonVariants as _},
    h_flex,
    list::ListItem,
    tag::Tag,
    v_flex,
};

use super::GinoWindow;
use super::session::{Section, kind_label};
use super::widgets::muted;

impl GinoWindow {
    pub(crate) fn render_workspace_admin(
        &self,
        entity: Entity<Self>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let kind = if self.session.active_section == Section::Projects {
            WorkspaceKind::Project
        } else {
            WorkspaceKind::Custom
        };
        let add = entity.clone();
        let add_kind = kind.clone();
        let bookmarks = self.session.bookmarks(kind.clone());
        let show_register = self.session.active_section != Section::Agents;
        v_flex()
            .flex_1()
            .h_full()
            .when(show_register, |this| {
                this.child(
                    v_flex()
                        .p_4()
                        .gap_2()
                        .border_b_1()
                        .border_color(cx.theme().border)
                        .child(muted(
                            cx,
                            "Register a folder. Removing a bookmark never deletes files. The app does not scan the whole disk.",
                        ))
                        .child(
                            Button::new("add-folder")
                                .primary()
                                .label("Open Folder")
                                .on_click(move |_, window, cx| {
                                    add.update(cx, |app, cx| {
                                        app.start_folder_pick(add_kind.clone(), window, cx);
                                        cx.notify();
                                    });
                                }),
                        )
                        .children(bookmarks.into_iter().map(|bookmark| {
                            let remove = entity.clone();
                            let id = bookmark.id.clone();
                            ListItem::new(SharedString::from(format!("bookmark-{id}"))).child(
                                h_flex().w_full()
                                    .child(div().flex_1().child(format!(
                                        "{} — {}",
                                        bookmark.display_name,
                                        bookmark.path.display()
                                    )))
                                    .child(
                                        Button::new(SharedString::from(format!("remove-{id}")))
                                            .ghost()
                                            .label("Remove bookmark")
                                            .on_click(move |_, _, cx| {
                                                let id = id.clone();
                                                remove.update(cx, |app, cx| {
                                                    app.session.remove_bookmark(&id);
                                                    cx.notify();
                                                });
                                            }),
                                    ),
                            )
                        })),
                )
            })
            .when(self.session.active_section == Section::Agents, |this| {
                this.child(v_flex().p_4().gap_1().children(
                    self.session
                        .workspaces
                        .iter()
                        .filter(|workspace| workspace.kind == WorkspaceKind::Agent)
                        .map(|workspace| {
                            h_flex()
                                .w_full()
                                .items_center()
                                .gap_2()
                                .child(div().text_sm().child(workspace.display_name.clone()))
                                .child(
                                    Tag::secondary()
                                        .outline()
                                        .small()
                                        .child(kind_label(&workspace.kind)),
                                )
                                .child(
                                    div()
                                        .flex_1()
                                        .text_sm()
                                        .text_color(cx.theme().muted_foreground)
                                        .truncate()
                                        .child(workspace.root.display().to_string()),
                                )
                        }),
                ))
            })
            .child(self.render_library(entity, window, cx))
    }
}
