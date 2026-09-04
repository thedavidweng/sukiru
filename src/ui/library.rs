use gino_core::inventory::{PlacementKind, SkillState};
use gino_core::platform::{open_in_editor, reveal_in_file_manager};
use gpui::{
    ClickEvent, ClipboardItem, Context, Corner, Entity, IntoElement, Keystroke, ParentElement,
    SharedString, Styled, Window, div, prelude::FluentBuilder as _, px, rems, uniform_list,
};
use gpui_component::{
    ActiveTheme, Disableable as _, Icon, IconName, Sizable as _, StyledExt,
    button::{Button, ButtonVariants as _},
    checkbox::Checkbox,
    clipboard::Clipboard,
    description_list::{DescriptionItem, DescriptionList},
    h_flex,
    input::Input,
    kbd::Kbd,
    list::ListItem,
    menu::{ContextMenuExt as _, DropdownMenu as _, PopupMenuItem},
    popover::Popover,
    scroll::ScrollableElement as _,
    select::Select,
    tab::{Tab, TabBar},
    tag::Tag,
    text::TextView,
    v_flex,
};

use super::GinoWindow;
use super::session::{
    PreviewTab, Section, duplicate_label, equivalent_cli, kind_label, state_label,
};
use super::widgets::{empty_state, muted, status_dot};

impl GinoWindow {
    pub(crate) fn render_library(
        &self,
        entity: Entity<Self>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let count = self.session.visible_placements().len();
        h_flex()
            .flex_1()
            .min_h(px(0.))
            .child(
                v_flex()
                    .flex_1()
                    .min_w(px(360.))
                    .h_full()
                    .min_h(px(0.))
                    .px_4()
                    .pt_3()
                    .gap_2()
                    .child(self.render_search_row(cx))
                    .child(self.render_filter_row(cx))
                    .child(self.render_selection_row(entity.clone(), cx))
                    .child(self.render_skill_list(count, entity.clone(), cx)),
            )
            .child(self.render_detail(entity, window, cx))
    }

    fn render_search_row(&self, cx: &mut Context<Self>) -> impl IntoElement {
        Input::new(&self.library_search_input)
            .prefix(
                Icon::new(IconName::Search)
                    .small()
                    .text_color(cx.theme().muted_foreground),
            )
            .suffix(Kbd::new(
                Keystroke::parse("cmd-f").expect("valid keystroke"),
            ))
    }

    /// Tag/workspace filters as native dropdowns. Option lists and the active
    /// selection are rebuilt by `sync_filter_options`; Confirm handlers on the
    /// select states write back into `session.tag_filter`/`workspace_filter`.
    /// The workspace filter only earns its slot when more than one workspace
    /// is installed.
    fn render_filter_row(&self, cx: &mut Context<Self>) -> impl IntoElement {
        h_flex()
            .w_full()
            .items_center()
            .gap_2()
            .child(muted(cx, "Tags"))
            .child(Select::new(&self.tag_filter_select).small().w(px(160.)))
            .when(self.session.workspace_filter_options().len() > 1, |this| {
                this.child(muted(cx, "Workspace")).child(
                    Select::new(&self.workspace_filter_select)
                        .small()
                        .w(px(180.)),
                )
            })
    }

    /// Bulk-selection controls. Move/Copy target pickers sit behind native
    /// dropdown menus; rare maintenance lives in the overflow menu so the
    /// primary row stays scannable.
    fn render_selection_row(
        &self,
        entity: Entity<Self>,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let selected = self.session.selected_paths.len();
        let broken = self.session.visible_broken_symlink_count();
        h_flex()
            .w_full()
            .items_center()
            .gap_1()
            .child(
                Button::new("select-visible")
                    .ghost()
                    .xsmall()
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
                    .xsmall()
                    .disabled(selected == 0)
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
            .when(selected > 0, |this| {
                this.child(
                    div()
                        .text_xs()
                        .text_color(cx.theme().muted_foreground)
                        .child(format!("{selected} selected")),
                )
            })
            .child(div().w(px(1.)).h(px(14.)).mx_1().bg(cx.theme().border))
            .child(self.render_target_menu(entity.clone(), "move-menu", "Move to…", true))
            .child(self.render_target_menu(entity.clone(), "copy-menu", "Copy to…", false))
            .child(div().flex_1())
            .child(
                Button::new("more-menu")
                    .ghost()
                    .xsmall()
                    .label("More")
                    .dropdown_caret(true)
                    .dropdown_menu(move |menu, _, _| {
                        menu.item(
                            PopupMenuItem::new(format!("Clean Broken Links ({broken})"))
                                .disabled(broken == 0)
                                .on_click({
                                    let entity = entity.clone();
                                    move |_, window, cx| {
                                        entity.update(cx, |app, cx| {
                                            let count =
                                                app.session.queue_cleanup_visible_broken_symlinks();
                                            if count > 0 {
                                                app.session.active_section = Section::Pending;
                                            }
                                            app.push_status(window, cx);
                                            cx.notify();
                                        });
                                    }
                                }),
                        )
                    }),
            )
    }

    fn render_skill_list(
        &self,
        count: usize,
        entity: Entity<Self>,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        div()
            .flex_1()
            .min_h(px(0.))
            .border_1()
            .border_color(cx.theme().border)
            .rounded_lg()
            .overflow_hidden()
            .when(count == 0, |this| {
                this.child(empty_state(
                    cx,
                    if self.session.search.trim().is_empty() {
                        "No Skills discovered. Refresh after installing with npx skills, or open Marketplace."
                    } else {
                        "No Skills match the current search and filters."
                    },
                ))
            })
            .when(count > 0, |this| {
                this.child(
                    uniform_list("skill-list", count, {
                        let entity = entity.clone();
                        move |range, _, cx| {
                            entity.update(cx, |app, cx| app.render_skill_rows(range, cx))
                        }
                    })
                    .flex_1()
                    .h_full(),
                )
            })
    }

    /// Move/Copy targets behind a native dropdown menu; open/close state lives
    /// in the popover itself instead of `session.target_menu`.
    fn render_target_menu(
        &self,
        entity: Entity<Self>,
        id: &'static str,
        label: &'static str,
        move_mode: bool,
    ) -> impl IntoElement {
        let targets: Vec<(String, String)> = self
            .session
            .workspaces
            .iter()
            .filter(|workspace| workspace.installed)
            .map(|workspace| (workspace.id.clone(), workspace.display_name.clone()))
            .collect();
        Button::new(id)
            .ghost()
            .xsmall()
            .label(label)
            .dropdown_caret(true)
            .dropdown_menu(move |menu, _, _| {
                let mut built = menu;
                for (target_id, name) in targets.iter() {
                    let target_id = target_id.clone();
                    let entity = entity.clone();
                    built =
                        built.item(PopupMenuItem::new(name.clone()).on_click(move |_, _, cx| {
                            let target_id = target_id.clone();
                            entity.update(cx, |app, cx| {
                                if move_mode {
                                    app.session.queue_move_to(&target_id);
                                } else {
                                    app.session.queue_copy_to(&target_id);
                                }
                                cx.notify();
                            });
                        }));
                }
                built
            })
    }

    fn render_skill_rows(
        &self,
        range: std::ops::Range<usize>,
        cx: &mut Context<Self>,
    ) -> Vec<gpui::AnyElement> {
        let placements = self.session.visible_placements();
        placements
            .into_iter()
            .skip(range.start)
            .take(range.end.saturating_sub(range.start))
            .map(|placement| {
                let checked = self.session.selected_paths.contains(&placement.path);
                let focused = self.session.selected_detail.as_ref() == Some(&placement.path);
                let path = placement.path.clone();
                let toggle_path = path.clone();
                let row_entity = cx.entity();
                let check_entity = cx.entity();
                ListItem::new(SharedString::from(format!(
                    "skill-row-{}",
                    placement.path.display()
                )))
                .selected(focused)
                .on_click(move |event: &ClickEvent, _, cx| {
                    let path = path.clone();
                    let shift = event.modifiers().shift;
                    row_entity.update(cx, |app, cx| {
                        app.session.open_placement(path, shift);
                        cx.notify();
                    });
                })
                .child(
                    h_flex()
                        .w_full()
                        .items_center()
                        .gap_x_3()
                        .child(
                            Checkbox::new(SharedString::from(format!(
                                "skill-check-{}",
                                placement.path.display()
                            )))
                            .checked(checked)
                            .on_click(move |_, _, cx| {
                                let path = toggle_path.clone();
                                check_entity.update(cx, |app, cx| {
                                    app.session.toggle_selected(&path);
                                    cx.notify();
                                });
                                // The checkbox owns bulk selection only; stop the
                                // row underneath from also opening the detail pane.
                                cx.stop_propagation();
                            }),
                        )
                        .child(
                            v_flex()
                                .flex_1()
                                .min_w(px(0.))
                                .gap(px(2.))
                                .child(
                                    div()
                                        .text_sm()
                                        .font_medium()
                                        .text_color(cx.theme().foreground)
                                        .truncate()
                                        .child(placement.name.clone()),
                                )
                                .child(if placement.description.is_empty() {
                                    div()
                                        .text_xs()
                                        .text_color(cx.theme().muted_foreground.opacity(0.6))
                                        .child("No description")
                                } else {
                                    div()
                                        .text_xs()
                                        .text_color(cx.theme().muted_foreground)
                                        .truncate()
                                        // Frontmatter descriptions may contain hard
                                        // line breaks; `truncate` only suppresses
                                        // soft wraps, so flatten them first or the
                                        // row grows and collides with its neighbors
                                        // in the uniform list.
                                        .child(placement.description.replace('\n', " "))
                                }),
                        )
                        .child(
                            // Right cluster: anomaly badges first, then the
                            // tracking dot. Quiet rows stay quiet.
                            h_flex()
                                .flex_shrink_0()
                                .justify_end()
                                .gap_1()
                                .items_center()
                                .children(self.session.duplicate_class_for(&placement.path).map(
                                    |class| {
                                        Tag::warning()
                                            .outline()
                                            .small()
                                            .child(duplicate_label(&class))
                                            .into_any_element()
                                    },
                                ))
                                .when(
                                    placement.placement_kind == PlacementKind::BrokenSymlink,
                                    |this| {
                                        // Attribute dangling links to the agent whose
                                        // skills directory they sit in.
                                        this.child(
                                            Tag::warning()
                                                .outline()
                                                .small()
                                                .child(self.session.workspace_display_name(
                                                    &placement.workspace_id,
                                                ))
                                                .into_any_element(),
                                        )
                                    },
                                )
                                .child(status_dot(&placement.state, cx)),
                        ),
                )
                .context_menu({
                    let menu_path = placement.path.clone();
                    let menu_entity = cx.entity();
                    let editor_pref = self.session.preferences.editor.clone();
                    move |menu, _, _| {
                        menu.item(
                            PopupMenuItem::new("Reveal in Finder")
                                .icon(IconName::Folder)
                                .on_click({
                                    let path = menu_path.clone();
                                    let entity = menu_entity.clone();
                                    move |_, _, cx| {
                                        entity.update(cx, |app, cx| {
                                            if let Err(error) = reveal_in_file_manager(&path) {
                                                app.session.action_error = Some(error.to_string());
                                            }
                                            cx.notify();
                                        });
                                    }
                                }),
                        )
                        .item(
                            PopupMenuItem::new("Open in Editor")
                                .icon(IconName::SquareTerminal)
                                .on_click({
                                    let path = menu_path.clone();
                                    let editor_pref = editor_pref.clone();
                                    let entity = menu_entity.clone();
                                    move |_, _, cx| {
                                        entity.update(cx, |app, cx| {
                                            if let Err(error) = open_in_editor(
                                                &path,
                                                (!editor_pref.is_empty())
                                                    .then_some(editor_pref.as_str()),
                                            ) {
                                                app.session.action_error = Some(error.to_string());
                                            }
                                            cx.notify();
                                        });
                                    }
                                }),
                        )
                        .item(
                            PopupMenuItem::new("Copy Path")
                                .icon(IconName::Copy)
                                .on_click({
                                    let path = menu_path.clone();
                                    let entity = menu_entity.clone();
                                    move |_, _, cx| {
                                        entity.update(cx, |_app, cx| {
                                            cx.write_to_clipboard(ClipboardItem::new_string(
                                                path.display().to_string(),
                                            ));
                                            cx.notify();
                                        });
                                    }
                                }),
                        )
                    }
                })
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
                .min_w(px(320.))
                .max_w(px(560.))
                .h_full()
                .min_h(px(0.))
                .border_l_1()
                .border_color(cx.theme().border)
                .child(empty_state(
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
                    self.session.workspace_display_name(&other.workspace_id),
                    other.path.display()
                )
            })
            .collect::<Vec<_>>();
        let tags = self.session.tags_for(&placement.name);
        let untracked = placement.state == SkillState::Untracked;
        let state_text = state_label(&placement.state);
        let preview_body = match self.session.preview_tab {
            PreviewTab::SkillMd => skill_md,
            PreviewTab::Readme => readme.unwrap_or_else(|| "_No README.md_".to_owned()),
        };
        let preview_id = format!("preview-{}", placement.path.display());
        let tracked_source =
            placement
                .lock_entry
                .as_ref()
                .map(|entry| match entry.ref_name.as_deref() {
                    Some(reference) => format!("{} · {}", entry.source, reference),
                    None => entry.source.clone(),
                });

        // Region 1 — header: identity, status, primary actions.
        let header = v_flex()
            .flex_shrink_0()
            .px_4()
            .pt_4()
            .gap_2()
            .child(
                h_flex()
                    .items_center()
                    .justify_between()
                    .gap_2()
                    .child(
                        h_flex()
                            .flex_1()
                            .min_w(px(0.))
                            .items_center()
                            .gap_2()
                            .child(
                                div()
                                    .text_xl()
                                    .font_semibold()
                                    .truncate()
                                    .child(placement.name.clone()),
                            )
                            .child(Tag::success().small().child(state_text)),
                    )
                    .child(
                        h_flex()
                            .flex_shrink_0()
                            .items_center()
                            .gap_1()
                            .child({
                                let editor = entity.clone();
                                let editor_path = path.clone();
                                Button::new("editor")
                                    .primary()
                                    .small()
                                    .icon(Icon::new(IconName::SquareTerminal))
                                    .label("Open in Editor")
                                    .on_click(move |_, _, cx| {
                                        let path = editor_path.clone();
                                        let editor_pref = editor_pref.clone();
                                        editor.update(cx, |app, cx| {
                                            if let Err(error) = open_in_editor(
                                                &path,
                                                (!editor_pref.is_empty())
                                                    .then_some(editor_pref.as_str()),
                                            ) {
                                                app.session.action_error = Some(error.to_string());
                                            }
                                            cx.notify();
                                        });
                                    })
                            })
                            .child({
                                let reveal = entity.clone();
                                let reveal_path = path.clone();
                                Button::new("reveal")
                                    .ghost()
                                    .small()
                                    .icon(Icon::new(IconName::Folder))
                                    .label("Reveal in Finder")
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
                            .child(self.render_details_popover(
                                path.clone(),
                                command,
                                placements,
                                files,
                                tags,
                                state_label(&placement.state),
                            )),
                    ),
            )
            .child(
                div()
                    .text_sm()
                    .line_clamp(3)
                    .text_color(cx.theme().foreground)
                    .child(placement.description.clone()),
            );

        // Region 2 — source card: tracking status plus its one relevant action.
        let state_tag = || Tag::success().small().child(state_label(&placement.state));
        let source_card = v_flex()
            .flex_shrink_0()
            .mx_4()
            .mt_3()
            .p_3()
            .gap_2()
            .border_1()
            .border_color(cx.theme().border)
            .rounded_lg()
            .child(
                h_flex()
                    .items_center()
                    .gap_2()
                    .child(div().text_sm().font_semibold().child("Source"))
                    .child(state_tag()),
            )
            .when(untracked, |this| {
                this.child(muted(
                    cx,
                    "This Skill has no tracked source. Attach a repository, local path, or URL to enable updates.",
                ))
                .child(
                    h_flex()
                        .w_full()
                        .gap_2()
                        .child(Input::new(&self.attach_input).flex_1())
                        .child({
                            let attach = entity.clone();
                            Button::new("attach-source")
                                .primary()
                                .small()
                                .label("Attach Source")
                                .on_click(move |_, window, cx| {
                                    attach.update(cx, |app, cx| {
                                        app.queue_attach_from_input(window, cx);
                                        cx.notify();
                                    });
                                })
                        }),
                )
            })
            .when(!untracked, |this| {
                this.child(
                    div()
                        .text_sm()
                        .truncate()
                        .text_color(cx.theme().muted_foreground)
                        .child(tracked_source.unwrap_or_else(|| "—".to_owned())),
                )
            });

        // Region 3 — file tabs.
        let tabs = div().flex_shrink_0().px_4().pt_2().child(
            TabBar::new("preview-tabs")
                .selected_index(usize::from(self.session.preview_tab == PreviewTab::Readme))
                .on_click(move |ix: &usize, _, cx| {
                    let tab = if *ix == 1 {
                        PreviewTab::Readme
                    } else {
                        PreviewTab::SkillMd
                    };
                    entity.update(cx, |app, cx| {
                        app.session.preview_tab = tab;
                        cx.notify();
                    });
                })
                .children([Tab::new().label("SKILL.md"), Tab::new().label("README.md")]),
        );

        // Region 4 — document viewer: the only scrolling region.
        let viewer = div()
            .flex_1()
            .min_h(px(0.))
            .mx_4()
            .my_3()
            .border_1()
            .border_color(cx.theme().border)
            .rounded_lg()
            .overflow_y_scrollbar()
            .child(
                div()
                    .p_4()
                    .when(preview_body.trim().is_empty(), |this| {
                        this.child(empty_state(cx, "This file has no content."))
                    })
                    .when(!preview_body.trim().is_empty(), |this| {
                        this.child(
                            TextView::markdown(
                                SharedString::from(preview_id),
                                preview_body,
                                window,
                                cx,
                            )
                            .selectable(true),
                        )
                    }),
            );

        v_flex()
            .flex_1()
            .min_w(px(320.))
            .max_w(px(560.))
            .h_full()
            .min_h(px(0.))
            .border_l_1()
            .border_color(cx.theme().border)
            .overflow_hidden()
            .child(header)
            .child(source_card)
            .child(tabs)
            .child(viewer)
            .into_any_element()
    }

    /// Overflow menu behind the ⋯ button: the long-tail metadata that would
    /// otherwise turn the header into a debug panel, plus Copy Path.
    #[allow(clippy::too_many_arguments)]
    fn render_details_popover(
        &self,
        path: std::path::PathBuf,
        command: String,
        placements: Vec<String>,
        files: Vec<String>,
        tags: std::collections::BTreeSet<String>,
        state: &'static str,
    ) -> impl IntoElement {
        let source = self
            .session
            .selected_placement()
            .and_then(|placement| placement.lock_entry.as_ref())
            .map(|entry| match entry.ref_name.as_deref() {
                Some(reference) => format!("{} · {}", entry.source, reference),
                None => entry.source.clone(),
            });
        let path_display = self
            .session
            .compact_home_display(&path.display().to_string());
        let path_string = path.display().to_string();
        Popover::new("skill-details")
            .anchor(Corner::TopRight)
            .trigger(
                Button::new("skill-details-trigger")
                    .ghost()
                    .small()
                    .icon(Icon::new(IconName::EllipsisVertical)),
            )
            .content(move |_, _, _| {
                let truncated =
                    |text: String| div().text_sm().truncate().child(text).into_any_element();
                let mut items = vec![
                    DescriptionItem::new("Path").value(truncated(path_display.clone())),
                    DescriptionItem::new("State").value(state.to_string()),
                ];
                if let Some(source) = source.clone() {
                    items.push(DescriptionItem::new("Source").value(truncated(source)));
                }
                items.extend([
                    DescriptionItem::new("Equivalent CLI").value(command.clone()),
                    DescriptionItem::new("Placements").value(truncated(placements.join(" | "))),
                    DescriptionItem::new("Files").value(truncated(files.join(", "))),
                    DescriptionItem::new("Tags").value(if tags.is_empty() {
                        "none".to_owned()
                    } else {
                        tags.clone().into_iter().collect::<Vec<_>>().join(", ")
                    }),
                ]);
                v_flex()
                    .w(rems(30.))
                    .gap_2()
                    .child(DescriptionList::vertical().small().children(items))
                    .child(
                        h_flex()
                            .justify_end()
                            .child(Clipboard::new("copy-skill-path").value(path_string.clone())),
                    )
            })
    }
}
