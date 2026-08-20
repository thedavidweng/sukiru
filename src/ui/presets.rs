use gino_core::planner::PresetMode;
use gpui::{Context, Entity, IntoElement, ParentElement, SharedString, Styled, Window, div};
use gpui_component::{
    ActiveTheme, Selectable, StyledExt,
    button::{Button, ButtonVariants as _},
    h_flex,
    input::Input,
    scroll::ScrollableElement,
    v_flex,
};

use super::GinoWindow;
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
        v_flex()
            .flex_1()
            .p_4()
            .gap_3()
            .child(muted(
                cx,
                "Presets generate Pending Changes. Add Missing is the default. Tags are metadata only and never change installation state.",
            ))
            .child(
                h_flex()
                    .gap_2()
                    .child(
                        Button::new("mode-add")
                            .ghost()
                            .selected(self.session.preset_mode == PresetMode::AddMissing)
                            .label("Add Missing")
                            .on_click({
                                let entity = entity.clone();
                                move |_, _, cx| {
                                    entity.update(cx, |app, cx| {
                                        app.session.preset_mode = PresetMode::AddMissing;
                                        cx.notify();
                                    });
                                }
                            }),
                    )
                    .child(
                        Button::new("mode-exact")
                            .ghost()
                            .selected(self.session.preset_mode == PresetMode::MatchExactly)
                            .label("Match Exactly")
                            .on_click({
                                let entity = entity.clone();
                                move |_, _, cx| {
                                    entity.update(cx, |app, cx| {
                                        app.session.preset_mode = PresetMode::MatchExactly;
                                        cx.notify();
                                    });
                                }
                            }),
                    ),
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
                div().flex_1().overflow_y_scrollbar().children(presets.into_iter().map(|preset| {
                    let apply = entity.clone();
                    let preset_id = preset.id.clone();
                    v_flex()
                        .w_full()
                        .p_3()
                        .gap_1()
                        .border_b_1()
                        .border_color(cx.theme().border)
                        .child(div().font_medium().child(format!(
                            "{} ({})",
                            preset.name,
                            super::session::preset_mode_label(preset.mode)
                        )))
                        .child(muted(
                            cx,
                            preset.skills.into_iter().collect::<Vec<_>>().join(", "),
                        ))
                        .child(h_flex().gap_1().flex_wrap().children(self.session.workspaces.iter().map(
                            |workspace| {
                                let apply = apply.clone();
                                let preset_id = preset_id.clone();
                                let workspace_id = workspace.id.clone();
                                Button::new(SharedString::from(format!(
                                    "apply-{}-{}",
                                    preset_id, workspace.id
                                )))
                                .ghost()
                                .label(format!("Apply → {}", workspace.display_name))
                                .on_click(move |_, _, cx| {
                                    let preset_id = preset_id.clone();
                                    let workspace_id = workspace_id.clone();
                                    apply.update(cx, |app, cx| {
                                        app.session.queue_preset(&preset_id, &workspace_id);
                                        cx.notify();
                                    });
                                })
                            },
                        )))
                })),
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
