use gino_core::planner::PresetMode;
use gpui::{
    Context, Entity, IntoElement, ParentElement, SharedString, Styled, Window, div,
    prelude::FluentBuilder as _,
};
use gpui_component::{
    StyledExt,
    button::{Button, ButtonVariants as _},
    group_box::{GroupBox, GroupBoxVariants as _},
    h_flex,
    input::Input,
    menu::{DropdownMenu as _, PopupMenuItem},
    scroll::ScrollableElement,
    tab::{Tab, TabBar},
    v_flex,
};

use super::GinoWindow;
use super::session::preset_mode_label;
use super::widgets::muted;

impl GinoWindow {
    pub(crate) fn render_presets(
        &self,
        entity: Entity<Self>,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let presets = self.session.presets();
        let save = entity.clone();
        let apply_targets = self
            .session
            .workspaces
            .iter()
            .filter(|workspace| workspace.installed)
            .map(|workspace| (workspace.id.clone(), workspace.display_name.clone()))
            .collect::<Vec<_>>();
        v_flex()
            .flex_1()
            .p_4()
            .gap_3()
            .child(muted(
                cx,
                "Presets generate Pending Changes. Add Missing is the default. Tags are metadata only and never change installation state.",
            ))
            .child(
                TabBar::new("preset-mode")
                    .segmented()
                    .selected_index(match self.session.preset_mode {
                        PresetMode::AddMissing => 0,
                        PresetMode::MatchExactly => 1,
                    })
                    .children([
                        Tab::new().label("Add missing"),
                        Tab::new().label("Match exactly"),
                    ])
                    .on_click({
                        let entity = entity.clone();
                        move |index: &usize, _, cx| {
                            entity.update(cx, |app, cx| {
                                app.session.preset_mode = if *index == 0 {
                                    PresetMode::AddMissing
                                } else {
                                    PresetMode::MatchExactly
                                };
                                cx.notify();
                            });
                        }
                    }),
            )
            .child(
                h_flex()
                    .gap_2()
                    .child(div().flex_1().child(Input::new(&self.preset_input)))
                    .child(
                        Button::new("save-preset")
                            .primary()
                            .label("Save from selection")
                            .on_click(move |_, _, cx| {
                                save.update(cx, |app, cx| {
                                    let name = app.preset_input.read(cx).value().to_string();
                                    app.session.save_preset_from_selection(&name);
                                    cx.notify();
                                });
                            }),
                    ),
            )
            .child(self.render_tag_editor(entity.clone(), cx))
            .child(div().font_medium().child("Presets"))
            .child(
                div().flex_1().overflow_y_scrollbar().gap_3().children(
                    presets.into_iter().map(|preset| {
                        let apply = entity.clone();
                        let preset_id = preset.id.clone();
                        let card_id = SharedString::from(format!("preset-{}", preset.id));
                        let apply_targets = apply_targets.clone();
                        GroupBox::new()
                            .id(card_id)
                            .fill()
                            .title(format!(
                                "{} ({})",
                                preset.name,
                                preset_mode_label(preset.mode)
                            ))
                            .child(muted(
                                cx,
                                preset.skills.into_iter().collect::<Vec<_>>().join(", "),
                            ))
                            // The chip pile collapses into one dropdown; only
                            // installed workspaces stay listed as targets.
                            .when(!apply_targets.is_empty(), |this| {
                                this.child(
                                    Button::new(SharedString::from(format!(
                                        "apply-{preset_id}"
                                    )))
                                    .ghost()
                                    .label("Apply to…")
                                    .dropdown_caret(true)
                                    .dropdown_menu({
                                        let apply = apply.clone();
                                        let preset_id = preset_id.clone();
                                        let apply_targets = apply_targets.clone();
                                        move |menu, _, _| {
                                            let mut menu = menu;
                                            for (workspace_id, display_name) in
                                                apply_targets.iter()
                                            {
                                                let apply = apply.clone();
                                                let preset_id = preset_id.clone();
                                                let workspace_id = workspace_id.clone();
                                                menu = menu.item(
                                                    PopupMenuItem::new(display_name.clone())
                                                        .on_click(move |_, _, cx| {
                                                            apply.update(cx, |app, cx| {
                                                                app.session.queue_preset(
                                                                    &preset_id,
                                                                    &workspace_id,
                                                                );
                                                                cx.notify();
                                                            });
                                                        }),
                                                );
                                            }
                                            menu
                                        }
                                    }),
                                )
                            })
                    }),
                ),
            )
    }

    fn render_tag_editor(&self, entity: Entity<Self>, _cx: &mut Context<Self>) -> impl IntoElement {
        let add = entity.clone();
        let skill = self
            .session
            .selected_placement()
            .map(|placement| placement.name.clone())
            .unwrap_or_default();
        h_flex()
            .gap_2()
            .child(div().flex_1().child(Input::new(&self.tag_input)))
            .child(
                Button::new("add-tag")
                    .ghost()
                    .label("Tag selected Skill")
                    .on_click({
                        let skill = skill.clone();
                        move |_, _, cx| {
                            let skill = skill.clone();
                            add.update(cx, |app, cx| {
                                let tag = app.tag_input.read(cx).value().to_string();
                                app.session.add_tag(&skill, &tag);
                                cx.notify();
                            });
                        }
                    }),
            )
            .child({
                let remove = entity;
                Button::new("remove-tag")
                    .ghost()
                    .label("Remove tag")
                    .on_click(move |_, _, cx| {
                        let skill = skill.clone();
                        remove.update(cx, |app, cx| {
                            let tag = app.tag_input.read(cx).value().to_string();
                            app.session.remove_tag(&skill, &tag);
                            cx.notify();
                        });
                    })
            })
    }
}
