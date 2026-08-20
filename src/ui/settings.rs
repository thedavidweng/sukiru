use gpui::{
    Context, Entity, IntoElement, ParentElement, Styled, Window, div, prelude::FluentBuilder as _,
    px, uniform_list,
};
use gpui_component::{
    StyledExt,
    button::{Button, ButtonVariants as _},
    input::Input,
    scroll::ScrollableElement,
    v_flex,
};

use super::GinoWindow;
use super::widgets::{apply_appearance, field_label, muted, settings_heading};

impl GinoWindow {
    pub(crate) fn render_activity(
        &self,
        _entity: Entity<Self>,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let records = self.session.activity_records();
        let count = records.len();
        v_flex()
            .flex_1()
            .min_w(px(0.))
            .child(
                div()
                    .p_4()
                    .child(muted(cx, "Local activity only. It is not backed up.")),
            )
            .when(count == 0, |this| {
                this.child(div().px_4().child(muted(cx, "No activity recorded yet.")))
            })
            .child(
                uniform_list("activity-list", count, {
                    let records = records.clone();
                    move |range, _, _| {
                        records
                            .iter()
                            .skip(range.start)
                            .take(range.end.saturating_sub(range.start))
                            .map(|record| {
                                div()
                                    .px_4()
                                    .py_2()
                                    .child(format!(
                                        "{}  {}  {}  {}  {}",
                                        record.created_at,
                                        record.action,
                                        record.outcome,
                                        record.commit_id.clone().unwrap_or_default(),
                                        record.restore_origin.clone().unwrap_or_default()
                                    ))
                                    .into_any_element()
                            })
                            .collect::<Vec<_>>()
                    }
                })
                .flex_1()
                .h_full(),
            )
    }

    pub(crate) fn render_settings(
        &self,
        entity: Entity<Self>,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let theme = entity.clone();
        let size = entity.clone();
        let push = entity.clone();
        let save = entity.clone();
        let export = entity.clone();
        let releases = entity.clone();
        let (version, releases_url) = super::session::Session::about();
        v_flex()
            .flex_1()
            .p_4()
            .gap_2()
            .overflow_y_scrollbar()
            .child(
                div()
                    .text_lg()
                    .font_semibold()
                    .child(format!("Gino {version}")),
            )
            .child(muted(cx, format!("Releases: {releases_url}")))
            .child(
                Button::new("open-releases")
                    .ghost()
                    .label("Open GitHub Releases")
                    .on_click(move |_, window, cx| {
                        releases.update(cx, |app, cx| {
                            app.session.open_releases();
                            app.push_status(window, cx);
                            cx.notify();
                        });
                    }),
            )
            .child(muted(cx, "No telemetry. No in-app self-update."))
            .child(settings_heading("Appearance"))
            .child(field_label(format!(
                "Theme: {}",
                self.session.theme_label()
            )))
            .child(
                Button::new("toggle-theme")
                    .ghost()
                    .label("Cycle light / dark / system")
                    .on_click(move |_, window, cx| {
                        theme.update(cx, |app, cx| {
                            app.session.cycle_theme();
                            apply_appearance(&app.session.preferences, Some(window), cx);
                            cx.notify();
                        });
                    }),
            )
            .child(field_label(format!(
                "Text size: {}",
                self.session.text_size_label()
            )))
            .child(
                Button::new("cycle-size")
                    .ghost()
                    .label("Cycle text size")
                    .on_click(move |_, window, cx| {
                        size.update(cx, |app, cx| {
                            app.session.cycle_text_size();
                            apply_appearance(&app.session.preferences, Some(window), cx);
                            cx.notify();
                        });
                    }),
            )
            .child(muted(
                cx,
                format!(
                    "Interface language: {}. 1.0 ships English only.",
                    self.session.language_label()
                ),
            ))
            .child(settings_heading("Editor and network"))
            .child(field_label("External editor"))
            .child(Input::new(&self.editor_input))
            .child(field_label("HTTP proxy (source / marketplace)"))
            .child(Input::new(&self.proxy_input))
            .child(field_label("Agent display order (comma-separated ids)"))
            .child(Input::new(&self.agent_order_input))
            .child(settings_heading("Backup and snapshots"))
            .child(field_label(format!(
                "Snapshot retention: {}",
                self.session.preferences.snapshot_retention
            )))
            .child(muted(
                cx,
                "Zero keeps no extra snapshots after success; Apply still uses a temporary transaction snapshot until completion.",
            ))
            .child(Input::new(&self.retention_input))
            .child(field_label("Snapshot folder"))
            .child(Input::new(&self.snapshot_root_input))
            .child(field_label("Backup remote"))
            .child(Input::new(&self.remote_input))
            .child(field_label(format!(
                "Push mode: {}",
                self.session.push_mode_label()
            )))
            .child(
                Button::new("toggle-push")
                    .ghost()
                    .label("Toggle Commit Locally / Commit and Push")
                    .on_click(move |_, _, cx| {
                        push.update(cx, |app, cx| {
                            app.session.toggle_push_mode();
                            cx.notify();
                        });
                    }),
            )
            .child(field_label("Backup size policy (bytes)"))
            .child(Input::new(&self.size_policy_input))
            .child(muted(cx, self.session.credential_status()))
            .child(
                Button::new("save-fields")
                    .primary()
                    .label("Save fields")
                    .on_click(move |_, window, cx| {
                        save.update(cx, |app, cx| {
                            app.session.preferences.editor =
                                app.editor_input.read(cx).value().to_string();
                            app.session.preferences.proxy =
                                app.proxy_input.read(cx).value().to_string();
                            app.session.preferences.backup_remote =
                                app.remote_input.read(cx).value().to_string();
                            app.session.preferences.agent_order =
                                app.agent_order_input.read(cx).value().to_string();
                            if let Ok(count) = app.retention_input.read(cx).value().parse() {
                                app.session.preferences.snapshot_retention = count;
                            }
                            let snapshot_root = app.snapshot_root_input.read(cx).value().to_string();
                            if !snapshot_root.trim().is_empty() {
                                app.session.preferences.snapshot_root =
                                    std::path::PathBuf::from(snapshot_root);
                            }
                            if let Ok(bytes) = app.size_policy_input.read(cx).value().parse() {
                                app.session.preferences.size_policy_bytes = bytes;
                            }
                            app.session.save_preferences();
                            apply_appearance(&app.session.preferences, Some(window), cx);
                            app.session.status = "Settings saved".to_owned();
                            app.push_status(window, cx);
                            cx.notify();
                        });
                    }),
            )
            .child(
                Button::new("export-logs")
                    .ghost()
                    .label("Export sanitized diagnostics")
                    .on_click(move |_, window, cx| {
                        export.update(cx, |app, cx| {
                            app.session.export_diagnostics();
                            app.push_status(window, cx);
                            cx.notify();
                        });
                    }),
            )
    }
}
