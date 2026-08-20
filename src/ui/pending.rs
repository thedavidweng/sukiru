use gpui::{
    Context, Entity, IntoElement, ParentElement, SharedString, Styled, Window, div,
    prelude::FluentBuilder as _, px, uniform_list,
};
use gpui_component::{
    ActiveTheme,
    button::{Button, ButtonVariants as _},
    checkbox::Checkbox,
    h_flex,
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
            .min_w(px(0.))
            .child(
                v_flex()
                    .p_4()
                    .gap_1()
                    .child(div().text_sm().child(format!(
                        "Review {selected} selected of {} pending changes. Apply is disabled while any selected item is Unavailable. Plans are session-only.",
                        count
                    )))
                    .child(muted(
                        cx,
                        format!(
                            "Unavailable: {unavailable}. Snapshot will be created at {}. Git commit uses {}.",
                            self.session.preferences.snapshot_root.display(),
                            self.session.push_mode_label()
                        ),
                    ))
                    .children(
                        self.session
                            .pending_warnings()
                            .into_iter()
                            .map(|warning| muted(cx, format!("Warning: {warning}"))),
                    )
                    .children(
                        self.session
                            .pending_blockers()
                            .into_iter()
                            .map(|blocker| {
                                div()
                                    .text_xs()
                                    .text_color(cx.theme().danger)
                                    .child(format!("Blocked: {blocker}"))
                            }),
                    ),
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
            .enumerate()
            .skip(range.start)
            .take(range.end.saturating_sub(range.start))
            .map(|(_, item)| {
                let id = item.id;
                let checked = self.session.pending_selected.contains(&id);
                let toggle = cx.entity();
                let remove = cx.entity();
                let available = item.available();
                let state = item
                    .unavailable_reason
                    .clone()
                    .unwrap_or_else(|| item.summary.clone());
                h_flex()
                    .w_full()
                    .h(px(48.))
                    .px_4()
                    .gap_x_3()
                    .items_center()
                    .border_b_1()
                    .border_color(cx.theme().border)
                    .child(
                        Checkbox::new(SharedString::from(format!("pending-{id}")))
                            .label(format!("{} {}", action_label(item.action), item.skill_name))
                            .checked(checked)
                            .on_click(move |_, _, cx| {
                                toggle.update(cx, |app, cx| {
                                    app.session.toggle_pending(id);
                                    cx.notify();
                                });
                            }),
                    )
                    .when(!available, |this| {
                        this.child(Tag::warning().child("Unavailable"))
                    })
                    .child(
                        div()
                            .flex_1()
                            .min_w(px(0.))
                            .text_xs()
                            .truncate()
                            .child(state),
                    )
                    .child(
                        Button::new(SharedString::from(format!("drop-{id}")))
                            .ghost()
                            .label("Remove from plan")
                            .on_click(move |_, _, cx| {
                                remove.update(cx, |app, cx| {
                                    app.session.drop_pending(id);
                                    cx.notify();
                                });
                            }),
                    )
                    .into_any_element()
            })
            .collect()
    }
}
