use gino_core::inventory::SkillState;
use gino_core::platform::{open_in_editor, reveal_in_file_manager};
use gpui::{
    ClickEvent, Context, Entity, InteractiveElement, IntoElement, ParentElement, SharedString,
    StatefulInteractiveElement, Styled, Window, div, prelude::FluentBuilder as _, px, uniform_list,
};
use gpui_component::{
    ActiveTheme, Selectable, StyledExt,
    button::{Button, ButtonVariants as _},
    checkbox::Checkbox,
    h_flex,
    input::Input,
    scroll::ScrollableElement,
    tag::Tag,
    text::TextView,
    v_flex,
};

use super::GinoWindow;
use super::session::TagFilter;
use super::session::{
    PreviewTab, TargetMenu, duplicate_label, equivalent_cli, kind_label, state_label,
};
use super::widgets::{empty_state, field_label, muted, row_shell, status_badge};

impl GinoWindow {
    pub(crate) fn render_library(
        &self,
        entity: Entity<Self>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let placements = self.session.visible_placements();
        let count = placements.len();
        h_flex()
            .flex_1()
            .min_w(px(0.))
            .child(
                v_flex()
                    .flex_1()
                    .min_w(px(240.))
                    .h_full()
                    .child(self.render_list_toolbar(entity.clone(), cx))
                    .when(count == 0, |this| {
                        this.child(empty_state(
                            cx,
                            "No Skills discovered. Refresh after installing with npx skills, or open Marketplace.",
                        ))
                    })
                    .child(
                        uniform_list("skill-list", count, {
                            let entity = entity.clone();
                            move |range, _, cx| {
                                entity.update(cx, |app, cx| app.render_skill_rows(range, cx))
                            }
                        })
                        .flex_1()
                        .h_full(),
                    ),
            )
            .child(self.render_detail(entity, window, cx))
    }

    fn render_list_toolbar(
        &self,
        entity: Entity<Self>,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let selected = self.session.selected_paths.len();
        v_flex()
            .w_full()
            .px_4()
            .py_2()
            .gap_2()
            .border_b_1()
            .border_color(cx.theme().border)
            .child(
                h_flex()
                    .w_full()
                    .gap_2()
                    .flex_wrap()
                    .items_center()
                    .child(muted(
                        cx,
                        format!(
                            "{} visible · {} selected · selection never writes files",
                            self.session.visible_placements().len(),
                            selected
                        ),
                    ))
                    .child(
                        Button::new("select-visible")
                            .ghost()
                            .label("Select visible")
                            .on_click({
                                let entity = entity.clone();
                                move |_, _, cx| {
                                    entity.update(cx, |app, cx| {
                                        app.session.select_visible();
                                        cx.notify();
                                    });
                                }
                            }),
                    )
                    .child(
                        Button::new("clear-selection")
                            .ghost()
                            .label("Clear")
                            .on_click({
                                let entity = entity.clone();
                                move |_, _, cx| {
                                    entity.update(cx, |app, cx| {
                                        app.session.clear_selection();
                                        cx.notify();
                                    });
                                }
                            }),
                    )
                    .child(self.render_target_toggle(
                        entity.clone(),
                        "move-menu",
                        "Move to…",
                        TargetMenu::Move,
                    ))
                    .child(self.render_target_toggle(
                        entity.clone(),
                        "copy-menu",
                        "Copy to…",
                        TargetMenu::Copy,
                    )),
            )
            .when(
                matches!(
                    self.session.target_menu,
                    TargetMenu::Move | TargetMenu::Copy
                ),
                |this| this.child(self.render_workspace_targets(entity.clone())),
            )
            .child(self.render_tag_filters(entity, cx))
    }

    fn render_target_toggle(
        &self,
        entity: Entity<Self>,
        id: &'static str,
        label: &'static str,
        menu: TargetMenu,
    ) -> impl IntoElement {
        Button::new(id)
            .ghost()
            .selected(self.session.target_menu == menu)
            .label(label)
            .on_click(move |_, _, cx| {
                entity.update(cx, |app, cx| {
                    app.session.toggle_target_menu(menu);
                    cx.notify();
                });
            })
    }

    fn render_workspace_targets(&self, entity: Entity<Self>) -> impl IntoElement {
        let menu = self.session.target_menu;
        h_flex()
            .gap_1()
            .flex_wrap()
            .children(self.session.workspaces.iter().map(|workspace| {
                let id = workspace.id.clone();
                let label = workspace.display_name.clone();
                let target = entity.clone();
                Button::new(SharedString::from(format!("target-{menu:?}-{id}")))
                    .ghost()
                    .label(label)
                    .on_click(move |_, _, cx| {
                        let id = id.clone();
                        target.update(cx, |app, cx| {
                            match menu {
                                TargetMenu::Move => app.session.queue_move_to(&id),
                                TargetMenu::Copy => app.session.queue_copy_to(&id),
                                _ => {}
                            }
                            app.session.close_target_menu();
                            cx.notify();
                        });
                    })
            }))
    }

    pub(crate) fn render_tag_filters(
        &self,
        entity: Entity<Self>,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let tags = self.session.all_tags();
        h_flex()
            .gap_2()
            .flex_wrap()
            .child(muted(cx, "Filter:"))
            .child(filter_chip(
                entity.clone(),
                "filter-all",
                "All",
                matches!(self.session.tag_filter, TagFilter::All),
                TagFilter::All,
            ))
            .child(filter_chip(
                entity.clone(),
                "filter-untagged",
                "Untagged",
                matches!(self.session.tag_filter, TagFilter::Untagged),
                TagFilter::Untagged,
            ))
            .children(tags.into_iter().map(|tag| {
                let selected =
                    matches!(&self.session.tag_filter, TagFilter::Tag(current) if current == &tag);
                filter_chip(
                    entity.clone(),
                    SharedString::from(format!("filter-{tag}")),
                    tag.clone(),
                    selected,
                    TagFilter::Tag(tag),
                )
            }))
    }

    fn render_skill_rows(
        &self,
        range: std::ops::Range<usize>,
        cx: &mut Context<Self>,
    ) -> Vec<gpui::AnyElement> {
        let placements = self.session.visible_placements();
        placements
            .into_iter()
            .enumerate()
            .skip(range.start)
            .take(range.end.saturating_sub(range.start))
            .map(|(index, placement)| {
                let checked = self.session.selected_paths.contains(&placement.path);
                let focused = self.session.selected_detail.as_ref() == Some(&placement.path);
                let path = placement.path.clone();
                let toggle_path = path.clone();
                let row_entity = cx.entity();
                let check_entity = cx.entity();
                row_shell(cx, focused)
                    .id(SharedString::from(format!("skill-row-{index}")))
                    .on_click(move |event: &ClickEvent, _, cx| {
                        let path = path.clone();
                        let shift = event.modifiers().shift;
                        row_entity.update(cx, |app, cx| {
                            app.session.click_placement(path, shift);
                            cx.notify();
                        });
                    })
                    .child(
                        Checkbox::new(SharedString::from(format!("skill-check-{index}")))
                            .label(placement.name.clone())
                            .checked(checked)
                            .on_click(move |_, _, cx| {
                                let path = toggle_path.clone();
                                check_entity.update(cx, |app, cx| {
                                    app.session.toggle_selected(&path);
                                    app.session.selected_detail = Some(path);
                                    app.session.warm_detail_preview();
                                    cx.notify();
                                });
                            }),
                    )
                    .child(
                        div()
                            .flex_1()
                            .min_w(px(0.))
                            .text_sm()
                            .text_color(cx.theme().muted_foreground)
                            .truncate()
                            .child(placement.description.clone()),
                    )
                    .child(status_badge(placement.state.clone()))
                    .children(
                        self.session
                            .duplicate_class_for(&placement.path)
                            .map(|class| {
                                Tag::warning()
                                    .child(duplicate_label(&class))
                                    .into_any_element()
                            }),
                    )
                    .child(
                        div()
                            .text_xs()
                            .text_color(cx.theme().muted_foreground)
                            .child(kind_label(&placement.workspace_kind)),
                    )
                    .into_any_element()
            })
            .collect()
    }

    fn render_detail(
        &self,
        entity: Entity<Self>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let Some(placement) = self.session.selected_placement() else {
            return v_flex()
                .flex_1()
                .min_w(px(240.))
                .max_w(px(520.))
                .h_full()
                .p_4()
                .border_l_1()
                .border_color(cx.theme().border)
                .child(muted(
                    cx,
                    "Select a Skill to inspect it. Preview is read-only.",
                ))
                .into_any_element();
        };
        let preview = self.session.detail_preview();
        let skill_md = preview
            .map(|preview| preview.skill_md.clone())
            .unwrap_or_default();
        let readme = preview.and_then(|preview| preview.readme.clone());
        let files = preview
            .map(|preview| preview.files.clone())
            .unwrap_or_default();
        let command = equivalent_cli(placement);
        let path = placement.path.clone();
        let editor_pref = self.session.preferences.editor.clone();
        let placements = self
            .session
            .inventory
            .by_name(&placement.name)
            .into_iter()
            .map(|other| {
                format!(
                    "{} · {} · {}",
                    kind_label(&other.workspace_kind),
                    other.workspace_id,
                    other.path.display()
                )
            })
            .collect::<Vec<_>>();
        let source = placement.lock_entry.as_ref().map(|entry| {
            format!(
                "{} ({}) ref={} path={}",
                entry.source,
                entry.source_type,
                entry.ref_name.as_deref().unwrap_or("-"),
                entry.skill_path.as_deref().unwrap_or("-")
            )
        });
        let tags = self.session.tags_for(&placement.name);
        let untracked = placement.state == SkillState::Untracked;
        let preview_body = match self.session.preview_tab {
            PreviewTab::SkillMd => skill_md,
            PreviewTab::Readme => readme.unwrap_or_else(|| "_No README.md_".to_owned()),
        };
        let preview_id = format!("preview-{}", placement.path.display());
        v_flex()
            .flex_1()
            .min_w(px(240.))
            .max_w(px(520.))
            .h_full()
            .p_4()
            .gap_2()
            .border_l_1()
            .border_color(cx.theme().border)
            .child(
                div()
                    .text_lg()
                    .font_semibold()
                    .child(placement.name.clone()),
            )
            .child(div().text_sm().child(placement.description.clone()))
            .child(muted(cx, format!("Path: {}", placement.path.display())))
            .child(muted(
                cx,
                format!(
                    "Hash: {}",
                    placement
                        .content_hash
                        .clone()
                        .unwrap_or_else(|| "n/a".to_owned())
                ),
            ))
            .child(muted(
                cx,
                format!("State: {}", state_label(&placement.state)),
            ))
            .children(source.map(|source| muted(cx, format!("Source: {source}"))))
            .child(muted(cx, format!("Equivalent CLI: {command}")))
            .child(muted(cx, format!("Placements: {}", placements.join(" | "))))
            .child(muted(cx, format!("Files: {}", files.join(", "))))
            .child(muted(
                cx,
                format!(
                    "Tags: {}",
                    if tags.is_empty() {
                        "none".to_owned()
                    } else {
                        tags.into_iter().collect::<Vec<_>>().join(", ")
                    }
                ),
            ))
            .child(
                h_flex()
                    .gap_2()
                    .flex_wrap()
                    .child({
                        let reveal = entity.clone();
                        let reveal_path = path.clone();
                        Button::new("reveal")
                            .ghost()
                            .label("Reveal")
                            .on_click(move |_, _, cx| {
                                let path = reveal_path.clone();
                                reveal.update(cx, |app, cx| {
                                    if let Err(error) = reveal_in_file_manager(&path) {
                                        app.session.action_error = Some(error.to_string());
                                    }
                                    cx.notify();
                                });
                            })
                    })
                    .child({
                        let editor = entity.clone();
                        let editor_path = path.clone();
                        Button::new("editor")
                            .ghost()
                            .label("Open in Editor")
                            .on_click(move |_, _, cx| {
                                let path = editor_path.clone();
                                let editor_pref = editor_pref.clone();
                                editor.update(cx, |app, cx| {
                                    if let Err(error) = open_in_editor(
                                        &path,
                                        (!editor_pref.is_empty()).then_some(editor_pref.as_str()),
                                    ) {
                                        app.session.action_error = Some(error.to_string());
                                    }
                                    cx.notify();
                                });
                            })
                    }),
            )
            .when(untracked, |this| {
                let attach = entity.clone();
                this.child(muted(
                    cx,
                    "Untracked: attach an explicit source to enable updates.",
                ))
                .child(field_label("Source for this Skill"))
                .child(Input::new(&self.attach_input))
                .child(
                    Button::new("attach-source")
                        .ghost()
                        .label("Queue Attach Source")
                        .on_click(move |_, window, cx| {
                            attach.update(cx, |app, cx| {
                                app.queue_attach_from_input(window, cx);
                                cx.notify();
                            });
                        }),
                )
            })
            .child(
                h_flex()
                    .gap_2()
                    .child(preview_tab_button(
                        entity.clone(),
                        "tab-skill",
                        "SKILL.md",
                        self.session.preview_tab == PreviewTab::SkillMd,
                        PreviewTab::SkillMd,
                    ))
                    .child(preview_tab_button(
                        entity,
                        "tab-readme",
                        "README.md",
                        self.session.preview_tab == PreviewTab::Readme,
                        PreviewTab::Readme,
                    )),
            )
            .child(
                div()
                    .flex_1()
                    .p_2()
                    .bg(cx.theme().secondary)
                    .overflow_y_scrollbar()
                    .child(
                        TextView::markdown(
                            SharedString::from(preview_id),
                            preview_body,
                            window,
                            cx,
                        )
                        .selectable(true),
                    ),
            )
            .into_any_element()
    }
}

fn preview_tab_button(
    entity: Entity<GinoWindow>,
    id: &'static str,
    label: &'static str,
    active: bool,
    tab: PreviewTab,
) -> impl IntoElement {
    Button::new(id)
        .ghost()
        .selected(active)
        .label(label)
        .on_click(move |_, _, cx| {
            entity.update(cx, |app, cx| {
                app.session.preview_tab = tab;
                cx.notify();
            });
        })
}

fn filter_chip(
    entity: Entity<GinoWindow>,
    id: impl Into<SharedString>,
    label: impl Into<SharedString>,
    selected: bool,
    filter: TagFilter,
) -> impl IntoElement {
    Button::new(id.into())
        .ghost()
        .selected(selected)
        .label(label.into())
        .on_click(move |_, _, cx| {
            let filter = filter.clone();
            entity.update(cx, |app, cx| {
                app.session.tag_filter = filter;
                cx.notify();
            });
        })
}
