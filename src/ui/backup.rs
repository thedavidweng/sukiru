use gino_core::git::RemoteChangeStatus;
use gpui::{
    Context, Entity, IntoElement, Keystroke, ParentElement, SharedString, StyleRefinement, Styled,
    Window, div, prelude::FluentBuilder as _, rems,
};
use gpui_component::{
    ActiveTheme, Sizable as _, StyledExt,
    button::{Button, ButtonVariants as _},
    group_box::GroupBox,
    h_flex,
    kbd::Kbd,
    list::ListItem,
    scroll::ScrollableElement,
    tag::Tag,
    v_flex,
};

use super::GinoWindow;
use super::session::{StatusTone, SyncChoice, remote_status_label, remote_status_tone};
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
            .child(muted(
                cx,
                format!(
                    "Backup push mode: {}. Git is history, not the install authority.",
                    self.session.push_mode_label()
                ),
            ))
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
                        "Remote {}",
                        &proposal.remote_commit[..7.min(proposal.remote_commit.len())]
                    )))
                    // Keycap hints replace the old parenthetical copy; they sit
                    // right above the rows they resolve.
                    .child(
                        h_flex()
                            .gap_2()
                            .items_center()
                            .text_xs()
                            .text_color(cx.theme().muted_foreground)
                            .child(key_hint("l", "Keep local"))
                            .child(key_hint("u", "Use remote"))
                            .child(key_hint("b", "Keep both")),
                    )
                    .children(proposal.changes.iter().enumerate().map(|(index, change)| {
                        let focused = self.session.focused_sync_index == Some(index);
                        let focus = entity.clone();
                        ListItem::new(SharedString::from(format!(
                            "sync-row-{}/{}",
                            change.workspace_id, change.relative_path
                        )))
                        .selected(focused)
                        .on_click(move |_, _, cx| {
                            focus.update(cx, |app, cx| {
                                app.session.focused_sync_index = Some(index);
                                cx.notify();
                            });
                        })
                        .child(
                            h_flex()
                                .w_full()
                                .gap_2()
                                .child(div().w_40().child(change.skill_name.clone()))
                                .child(div().w_32().child(status_tag(change.status)))
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
                                }),
                        )
                    }))
                    .into_any_element()
            }))
            .child(
                GroupBox::new().title("Recent commits").child(
                    div().max_h(rems(11.25)).overflow_y_scrollbar().children(
                        history.into_iter().map(|commit| {
                            let restore = entity.clone();
                            let id = commit.id.clone();
                            ListItem::new(SharedString::from(format!("commit-row-{id}"))).child(
                                h_flex()
                                    .w_full()
                                    .gap_2()
                                    .child(div().flex_1().child(format!(
                                        "{}  {}",
                                        &commit.id[..7.min(commit.id.len())],
                                        commit.subject
                                    )))
                                    .child(
                                        Button::new(SharedString::from(format!(
                                            "restore-commit-{id}"
                                        )))
                                        .ghost()
                                        .label("Queue restore")
                                        .on_click(
                                            move |_, _, cx| {
                                                let id = id.clone();
                                                restore.update(cx, |app, cx| {
                                                    app.session.queue_restore_commit(&id);
                                                    cx.notify();
                                                });
                                            },
                                        ),
                                    ),
                            )
                        }),
                    ),
                ),
            )
            .child(
                // Both the group box and its inner content grow so the snapshot
                // list keeps claiming the leftover panel height it had before.
                GroupBox::new()
                    .title("Local snapshots")
                    .flex_1()
                    .content_style(StyleRefinement::default().flex_1())
                    .child(div().flex_1().overflow_y_scrollbar().children(
                        snapshots.into_iter().map(|snapshot| {
                            let restore = entity.clone();
                            let id = snapshot.id.clone();
                            ListItem::new(SharedString::from(format!("snapshot-row-{id}"))).child(
                                h_flex()
                                    .w_full()
                                    .gap_2()
                                    .child(div().flex_1().child(format!(
                                        "{} · {} paths · {}",
                                        snapshot.id, snapshot.entry_count, snapshot.created_at
                                    )))
                                    .child(
                                        Button::new(SharedString::from(format!(
                                            "restore-snap-{id}"
                                        )))
                                        .ghost()
                                        .label("Queue restore")
                                        .on_click(
                                            move |_, _, cx| {
                                                let id = id.clone();
                                                restore.update(cx, |app, cx| {
                                                    app.session.queue_restore_snapshot(&id);
                                                    cx.notify();
                                                });
                                            },
                                        ),
                                    ),
                            )
                        }),
                    )),
            )
    }
}

/// Outline `Tag` for a remote change status. Consistent outline+small keeps the
/// long statuses from shouting next to their action buttons.
fn status_tag(status: RemoteChangeStatus) -> impl IntoElement {
    match remote_status_tone(status) {
        StatusTone::Neutral => Tag::secondary(),
        StatusTone::Positive => Tag::success(),
        StatusTone::Warning => Tag::warning(),
        StatusTone::Danger => Tag::danger(),
    }
    .outline()
    .small()
    .child(remote_status_label(status))
}

/// One keycap + label pair for the sync resolution hint line.
fn key_hint(key: &'static str, label: &'static str) -> impl IntoElement {
    h_flex()
        .gap_1()
        .items_center()
        .child(Kbd::new(Keystroke::parse(key).expect("valid keystroke")))
        .child(div().child(label))
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
