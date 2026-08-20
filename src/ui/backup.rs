use gino_core::git::RemoteChangeStatus;
use gpui::{
    Context, Entity, InteractiveElement, IntoElement, ParentElement, SharedString,
    StatefulInteractiveElement, Styled, Window, div, prelude::FluentBuilder as _,
};
use gpui_component::{
    ActiveTheme, StyledExt,
    button::{Button, ButtonVariants as _},
    h_flex,
    scroll::ScrollableElement,
    v_flex,
};

use super::GinoWindow;
use super::session::{SyncChoice, remote_status_label};
use super::widgets::muted;

impl GinoWindow {
    pub(crate) fn render_backup(
        &self,
        entity: Entity<Self>,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let last = self.session.cached_last_commit().cloned();
        let history = self.session.cached_commits().to_vec();
        let snapshots = self.session.cached_snapshots().to_vec();
        let check = entity.clone();
        v_flex()
            .flex_1()
            .p_4()
            .gap_2()
            .child(div().child(format!(
                "Backup push mode: {}. Git is history, not the install authority.",
                self.session.push_mode_label()
            )))
            .child(muted(
                cx,
                last.map(|commit| {
                    format!(
                        "Last commit: {}  {}",
                        &commit.id[..7.min(commit.id.len())],
                        commit.subject
                    )
                })
                .unwrap_or_else(|| "No backup commits yet".to_owned()),
            ))
            .child(
                Button::new("check-remote")
                    .primary()
                    .label("Check Remote")
                    .on_click(move |_, window, cx| {
                        check.update(cx, |app, cx| {
                            app.start_remote_check(window, cx);
                            cx.notify();
                        });
                    }),
            )
            .children(self.session.sync_proposal.as_ref().map(|proposal| {
                v_flex()
                    .gap_1()
                    .child(div().font_medium().child(format!(
                        "Remote {} (l keep local · u use remote · b keep both)",
                        &proposal.remote_commit[..7.min(proposal.remote_commit.len())]
                    )))
                    .children(proposal.changes.iter().enumerate().map(|(index, change)| {
                        let focused = self.session.focused_sync_index == Some(index);
                        let focus = entity.clone();
                        h_flex()
                            .id(SharedString::from(format!("sync-{index}")))
                            .w_full()
                            .gap_2()
                            .px_2()
                            .py_1()
                            .when(focused, |this| this.bg(cx.theme().list_active))
                            .on_click(move |_, _, cx| {
                                focus.update(cx, |app, cx| {
                                    app.session.focused_sync_index = Some(index);
                                    cx.notify();
                                });
                            })
                            .child(div().w_40().child(change.skill_name.clone()))
                            .child(div().w_32().child(remote_status_label(change.status)))
                            .when(change.status != RemoteChangeStatus::Unchanged, |this| {
                                this.children([
                                    sync_button(
                                        entity.clone(),
                                        index,
                                        SyncChoice::KeepLocal,
                                        "Keep Local",
                                    ),
                                    sync_button(
                                        entity.clone(),
                                        index,
                                        SyncChoice::UseRemote,
                                        "Use Remote",
                                    ),
                                    sync_button(
                                        entity.clone(),
                                        index,
                                        SyncChoice::KeepBoth,
                                        "Keep Both",
                                    ),
                                ])
                            })
                    }))
                    .into_any_element()
            }))
            .child(div().text_sm().font_medium().child("Recent commits"))
            .child(div().max_h(gpui::px(180.)).overflow_y_scrollbar().children(
                history.into_iter().map(|commit| {
                    let restore = entity.clone();
                    let id = commit.id.clone();
                    h_flex()
                        .w_full()
                        .gap_2()
                        .px_2()
                        .child(div().flex_1().child(format!(
                            "{}  {}",
                            &commit.id[..7.min(commit.id.len())],
                            commit.subject
                        )))
                        .child(
                            Button::new(SharedString::from(format!("restore-commit-{id}")))
                                .ghost()
                                .label("Queue restore")
                                .on_click(move |_, _, cx| {
                                    let id = id.clone();
                                    restore.update(cx, |app, cx| {
                                        app.session.queue_restore_commit(&id);
                                        cx.notify();
                                    });
                                }),
                        )
                }),
            ))
            .child(div().text_sm().font_medium().child("Local snapshots"))
            .child(
                div()
                    .flex_1()
                    .overflow_y_scrollbar()
                    .children(snapshots.into_iter().map(|snapshot| {
                        let restore = entity.clone();
                        let id = snapshot.id.clone();
                        h_flex()
                            .w_full()
                            .gap_2()
                            .px_2()
                            .child(div().flex_1().child(format!(
                                "{} · {} paths · {}",
                                snapshot.id, snapshot.entry_count, snapshot.created_at
                            )))
                            .child(
                                Button::new(SharedString::from(format!("restore-snap-{id}")))
                                    .ghost()
                                    .label("Queue restore")
                                    .on_click(move |_, _, cx| {
                                        let id = id.clone();
                                        restore.update(cx, |app, cx| {
                                            app.session.queue_restore_snapshot(&id);
                                            cx.notify();
                                        });
                                    }),
                            )
                    })),
            )
    }
}

fn sync_button(
    entity: Entity<GinoWindow>,
    index: usize,
    choice: SyncChoice,
    label: &'static str,
) -> impl IntoElement {
    Button::new(SharedString::from(format!("sync-{index}-{label}")))
        .ghost()
        .label(label)
        .on_click(move |_, _, cx| {
            entity.update(cx, |app, cx| {
                app.session.focused_sync_index = Some(index);
                app.session.resolve_sync(index, choice);
                cx.notify();
            });
        })
}
