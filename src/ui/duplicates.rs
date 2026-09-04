use gino_core::inventory::DuplicateClass;
use gpui::{
    Context, Entity, IntoElement, ParentElement, SharedString, Styled, Window, div,
    prelude::FluentBuilder as _,
};
use gpui_component::{
    ActiveTheme, Sizable as _, StyledExt,
    button::{Button, ButtonVariants as _},
    h_flex,
    list::ListItem,
    scroll::ScrollableElement,
    tag::Tag,
    v_flex,
};

use super::GinoWindow;
use super::session::duplicate_label;
use super::widgets::{empty_state, muted};

impl GinoWindow {
    pub(crate) fn render_duplicates(
        &self,
        entity: Entity<Self>,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let groups =
            self.session
                .visible_duplicate_groups()
                .into_iter()
                .map(|(group_index, group)| {
                    let members = group
                        .placement_indexes
                        .iter()
                        .filter_map(|index| self.session.inventory.placements.get(*index))
                        .collect::<Vec<_>>();
                    v_flex()
                        .w_full()
                        .p_4()
                        .gap_2()
                        .border_b_1()
                        .border_color(cx.theme().border)
                        .child(
                            h_flex()
                                .items_center()
                                .gap_2()
                                .child(duplicate_class_tag(&group.class))
                                .child(div().font_medium().child(group.skill_name.clone())),
                        )
                        .children(members.iter().enumerate().map(|(member_ix, placement)| {
                            let keep = entity.clone();
                            let keep_index = group.placement_indexes[member_ix];
                            ListItem::new(SharedString::from(format!(
                                "dup-{:?}-{}",
                                group.class,
                                placement.path.display()
                            )))
                            .child(
                                h_flex()
                                    .w_full()
                                    .child(div().flex_1().text_xs().child(format!(
                                    "{} · hash {}",
                                    placement.path.display(),
                                    placement
                                        .content_hash
                                        .clone()
                                        .unwrap_or_else(|| "n/a".to_owned())
                                )))
                                    .child(
                                        Button::new(SharedString::from(format!(
                                            "keep-{group_index}-{keep_index}"
                                        )))
                                        .ghost()
                                        .label("Keep this")
                                        .on_click(
                                            move |_, _, cx| {
                                                keep.update(cx, |app, cx| {
                                                    app.session
                                                        .keep_duplicate(group_index, keep_index);
                                                    cx.notify();
                                                });
                                            },
                                        ),
                                    ),
                            )
                        }))
                        .when(group.class == DuplicateClass::NameCollision, |this| {
                            let ignore = entity.clone();
                            this.child(
                                Button::new(SharedString::from(format!("ignore-{group_index}")))
                                    .ghost()
                                    .label("Ignore until identity changes")
                                    .on_click(move |_, _, cx| {
                                        ignore.update(cx, |app, cx| {
                                            app.session.ignore_duplicate(group_index);
                                            cx.notify();
                                        });
                                    }),
                            )
                        })
                });
        v_flex()
            .flex_1()
            .child(div().p_4().child(muted(
                cx,
                "Deterministic duplicates only. Keep-one queues removals; Apply writes.",
            )))
            .when(self.session.visible_duplicate_groups().is_empty(), |this| {
                this.child(empty_state(
                    cx,
                    "No duplicate groups in the current inventory.",
                ))
            })
            .child(div().flex_1().overflow_y_scrollbar().children(groups))
    }
}

/// Outline tags separate duplicate classes without saturating the list.
fn duplicate_class_tag(class: &DuplicateClass) -> Tag {
    match class {
        DuplicateClass::ExactDuplicate => Tag::warning(),
        DuplicateClass::SourceDuplicate => Tag::info(),
        DuplicateClass::NameCollision => Tag::secondary(),
    }
    .outline()
    .small()
    .child(duplicate_label(class))
}
