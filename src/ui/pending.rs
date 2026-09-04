use std::hash::{Hash, Hasher};

use gpui::{
    Context, Entity, IntoElement, ParentElement, SharedString, Styled, Window, div,
    prelude::FluentBuilder as _, rems, uniform_list,
};
use gpui_component::{
    Disableable as _, Sizable as _,
    alert::Alert,
    button::{Button, ButtonVariants as _},
    checkbox::Checkbox,
    h_flex,
    list::ListItem,
    tag::Tag,
    v_flex,
};

use super::GinoWindow;
use super::session::action_label;
use super::widgets::muted;

impl GinoWindow {
    pub(crate) fn render_pending(
        &self,
        entity: Entity<Self>,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let items = self.session.pending_items();
        let selected = self.session.selected_pending_count();
        let unavailable = items.iter().filter(|item| !item.available()).count();
        let count = items.len();
        v_flex()
            .flex_1()
            .min_w(rems(0.))
            .child(
                v_flex()
                    .p_4()
                    .gap_1()
                    .child(
                        h_flex()
                            .w_full()
                            .justify_between()
                            .flex_wrap()
                            .items_center()
                            .gap_2()
                            .child(div().text_sm().child(if count == 0 {
                                "Nothing queued yet.".to_owned()
                            } else {
                                format!(
                                    "{count} changes ready · {selected} selected · nothing touches disk until Apply"
                                )
                            }))
                            .child(
                                h_flex()
                                    .gap_1()
                                    .items_center()
                                    .child(
                                        Button::new("pending-select-all")
                                            .ghost()
                                            .xsmall()
                                            .disabled(count == 0)
                                            .label("Select all")
                                            .on_click({
                                                let entity = entity.clone();
                                                move |_, _, cx| {
                                                    entity.update(cx, |app, cx| {
                                                        app.session.select_all_pending();
                                                        cx.notify();
                                                    });
                                                }
                                            }),
                                    )
                                    .child(
                                        Button::new("pending-deselect-all")
                                            .ghost()
                                            .xsmall()
                                            .disabled(selected == 0)
                                            .label("Deselect all")
                                            .on_click({
                                                let entity = entity.clone();
                                                move |_, _, cx| {
                                                    entity.update(cx, |app, cx| {
                                                        app.session.clear_pending_selection();
                                                        cx.notify();
                                                    });
                                                }
                                            }),
                                    ),
                            ),
                    )
                    .when(count > 0, |this| {
                        let mut line =
                            String::from("Undoable: a snapshot is saved before anything changes.");
                        if unavailable > 0 {
                            line.push_str(&format!(
                                " {unavailable} item(s) are unavailable and will block Apply while selected."
                            ));
                        }
                        this.child(muted(cx, line))
                    })
                    .children(
                        self.session
                            .pending_warnings()
                            .into_iter()
                            .map(|warning| muted(cx, format!("Warning: {warning}"))),
                    )
                    // Alerts are reserved for true blockers; informational
                    // warnings above stay plain muted lines.
                    .children(self.session.pending_blockers().into_iter().map(|blocker| {
                        Alert::error(
                            blocker_element_id(&blocker),
                            format!("Blocked: {blocker}"),
                        )
                        .small()
                    })),
            )
            .child(
                uniform_list("pending-list", count, {
                    let entity = entity.clone();
                    move |range, _, cx| {
                        entity.update(cx, |app, cx| app.render_pending_rows(range, cx))
                    }
                })
                .flex_1()
                .h_full(),
            )
    }

    fn render_pending_rows(
        &self,
        range: std::ops::Range<usize>,
        cx: &mut Context<Self>,
    ) -> Vec<gpui::AnyElement> {
        let items = self.session.pending_items();
        items
            .into_iter()
            .skip(range.start)
            .take(range.end.saturating_sub(range.start))
            .map(|item| {
                // The checkbox is the single include/exclude control for a
                // row; no competing per-row button beside it.
                let id = item.id;
                let checked = self.session.pending_selected.contains(&id);
                let toggle = cx.entity();
                let available = item.available();
                let detail = match &item.unavailable_reason {
                    Some(reason) => reason.clone(),
                    None => self.session.compact_home_display(&item.summary),
                };
                ListItem::new(SharedString::from(format!("pending-row-{id}")))
                    .on_click(move |_, _, cx| {
                        toggle.update(cx, |app, cx| {
                            app.session.toggle_pending(id);
                            cx.notify();
                        });
                    })
                    // ListItem centers its children inside a full-width
                    // justify-between flex, so the row goes in as one child
                    // that owns its internal layout.
                    .child(
                        h_flex()
                            .w_full()
                            .items_center()
                            .gap_x_3()
                            .child(
                                // The row click above is the single toggle
                                // path; a checkbox handler would bubble up to
                                // it and flip the selection twice.
                                Checkbox::new(SharedString::from(format!("pending-check-{id}")))
                                    .label(format!(
                                        "{} {}",
                                        action_label(item.action),
                                        item.skill_name
                                    ))
                                    .checked(checked),
                            )
                            .when(!available, |this| {
                                this.child(Tag::warning().child("Unavailable"))
                            })
                            .child(
                                div()
                                    .flex_1()
                                    .min_w(rems(0.))
                                    .text_xs()
                                    .truncate()
                                    .child(detail),
                            ),
                    )
                    .into_any_element()
            })
            .collect()
    }
}

/// Stable element id derived from blocker content so ids survive plan
/// reordering without leaking list positions into element ids.
fn blocker_element_id(blocker: &str) -> SharedString {
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    blocker.hash(&mut hasher);
    SharedString::from(format!("pending-blocker-{:016x}", hasher.finish()))
}
