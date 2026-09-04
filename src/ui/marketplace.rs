use gpui::{
    Context, Entity, IntoElement, ParentElement, SharedString, Styled, Window, div,
    prelude::FluentBuilder as _, rems, uniform_list,
};
use gpui_component::{
    ActiveTheme, IconName,
    button::{Button, ButtonVariants as _},
    checkbox::Checkbox,
    h_flex,
    input::Input,
    list::ListItem,
    menu::{DropdownMenu as _, PopupMenuItem},
    v_flex,
};

use super::GinoWindow;
use super::widgets::{empty_state, muted};

impl GinoWindow {
    pub(crate) fn render_marketplace(
        &self,
        entity: Entity<Self>,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let count = self.session.marketplace_results.len();
        let search = entity.clone();
        let source_install = entity.clone();
        let queue_selected = entity.clone();
        v_flex()
            .flex_1()
            .min_w(rems(0.))
            .p_4()
            .gap_3()
            .child(muted(
                cx,
                "Search skills.sh or enter a source. Multi-select queues Pending Changes; nothing is written until Apply. Press Enter to search.",
            ))
            .child(
                h_flex()
                    .gap_2()
                    .flex_wrap()
                    .child(div().flex_1().min_w(rems(12.5)).child(Input::new(&self.query_input)))
                    .child(Button::new("search").primary().label("Search").on_click(
                        move |_, window, cx| {
                            search.update(cx, |app, cx| {
                                app.start_search(window, cx);
                                cx.notify();
                            });
                        },
                    )),
            )
            .child(
                h_flex()
                    .gap_2()
                    .flex_wrap()
                    .child(div().flex_1().min_w(rems(12.5)).child(Input::new(&self.source_input)))
                    .child(
                        Button::new("queue-source")
                            .ghost()
                            .label("Queue source")
                            .on_click(move |_, window, cx| {
                                source_install.update(cx, |app, cx| {
                                    app.queue_source_from_input(window, cx);
                                    cx.notify();
                                });
                            }),
                    )
                    .child(
                        Button::new("queue-selected")
                            .primary()
                            .label(format!(
                                "Queue {} selected",
                                self.session.marketplace_selected.len()
                            ))
                            .on_click(move |_, window, cx| {
                                queue_selected.update(cx, |app, cx| {
                                    let selected = app
                                        .session
                                        .marketplace_selected
                                        .iter()
                                        .filter_map(|index| {
                                            app.session.marketplace_results.get(*index).cloned()
                                        })
                                        .collect::<Vec<_>>();
                                    if selected.is_empty() {
                                        app.session.action_error =
                                            Some("Select one or more marketplace Skills".to_owned());
                                        app.push_status(window, cx);
                                    } else {
                                        app.start_queue_marketplace(selected, window, cx);
                                    }
                                    cx.notify();
                                });
                            }),
                    ),
            )
            .child(self.render_install_targets(entity.clone(), cx))
            .when(count == 0, |this| {
                this.child(empty_state(cx, "No marketplace results yet."))
            })
            .child(
                uniform_list("market-list", count, {
                    let entity = entity.clone();
                    move |range, _, cx| {
                        entity.update(cx, |app, cx| app.render_market_rows(range, cx))
                    }
                })
                .flex_1()
                .h_full(),
            )
    }

    fn render_market_rows(
        &self,
        range: std::ops::Range<usize>,
        cx: &mut Context<Self>,
    ) -> Vec<gpui::AnyElement> {
        self.session
            .marketplace_results
            .iter()
            .enumerate()
            .skip(range.start)
            .take(range.end.saturating_sub(range.start))
            .map(|(index, skill)| {
                // Row and control ids come from the skill's stable marketplace
                // id so they survive result reordering; `index` only feeds the
                // existing selection bookkeeping.
                let source = if skill.source.is_empty() {
                    skill.id.clone()
                } else {
                    skill.source.clone()
                };
                let hint = skill.name.clone();
                let checked = self.session.marketplace_selected.contains(&index);
                let toggle = cx.entity();
                let install = cx.entity();
                ListItem::new(SharedString::from(format!("market-row-{}", skill.id)))
                    .on_click(move |_, _, cx| {
                        toggle.update(cx, |app, cx| {
                            app.session.toggle_marketplace(index);
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
                                Checkbox::new(SharedString::from(format!(
                                    "market-check-{}",
                                    skill.id
                                )))
                                .label(skill.name.clone())
                                .checked(checked),
                            )
                            .child(
                                div()
                                    .flex_1()
                                    .min_w(rems(0.))
                                    .text_xs()
                                    .text_color(cx.theme().muted_foreground)
                                    .truncate()
                                    .child(source.clone()),
                            )
                            .child(
                                div()
                                    .text_xs()
                                    .child(format!("{} installs", skill.installs)),
                            )
                            .child(
                                Button::new(SharedString::from(format!("install-{}", skill.id)))
                                    .ghost()
                                    .label("Queue install")
                                    .on_click({
                                        let install = install.clone();
                                        move |_, window, cx| {
                                            // Keep the queueing click from also
                                            // toggling the row's selection.
                                            cx.stop_propagation();
                                            let source = source.clone();
                                            let hint = hint.clone();
                                            install.update(cx, |app, cx| {
                                                app.start_discover(source, Some(hint), window, cx);
                                                cx.notify();
                                            });
                                        }
                                    }),
                            ),
                    )
                    .into_any_element()
            })
            .collect()
    }

    fn render_install_targets(
        &self,
        entity: Entity<Self>,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let selected_label = self
            .session
            .workspaces
            .iter()
            .find(|workspace| workspace.id == self.session.install_target_id)
            .map(|workspace| workspace.display_name.clone())
            .unwrap_or_else(|| "Choose workspace".to_owned());
        h_flex()
            .gap_2()
            .items_center()
            .flex_wrap()
            .child(muted(cx, "Install target:"))
            .child(
                Button::new("install-target")
                    .ghost()
                    .icon(IconName::ChevronDown)
                    .label(selected_label)
                    .dropdown_menu({
                        let entity = entity.clone();
                        // The component owns open/close state; items are read
                        // from live session state each time the menu opens.
                        move |menu, _, cx| {
                            let session = &entity.read(cx).session;
                            let mut menu = menu;
                            for workspace in session.workspaces.iter().filter(|w| w.installed) {
                                let active = session.install_target_id == workspace.id;
                                menu = menu.item(
                                    PopupMenuItem::new(workspace.display_name.clone())
                                        .checked(active)
                                        .on_click({
                                            let entity = entity.clone();
                                            let id = workspace.id.clone();
                                            move |_, _, cx| {
                                                entity.update(cx, |app, cx| {
                                                    app.session.install_target_id = id.clone();
                                                    cx.notify();
                                                });
                                            }
                                        }),
                                );
                            }
                            menu
                        }
                    }),
            )
    }
}
