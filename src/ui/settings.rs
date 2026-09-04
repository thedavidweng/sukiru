use gino_core::metadata::ActivityRecord;
use gpui::{
    App, Context, Entity, IntoElement, ParentElement as _, SharedString, Styled, Window, div,
    prelude::FluentBuilder as _, px, rems, uniform_list,
};
use gpui_component::{
    ActiveTheme, Sizable as _, StyledExt,
    button::{Button, ButtonVariants as _},
    form::{field, v_form},
    group_box::{GroupBox, GroupBoxVariants as _},
    h_flex,
    input::Input,
    link::Link,
    list::ListItem,
    scroll::ScrollableElement,
    select::Select,
    switch::Switch,
    tag::Tag,
    v_flex,
};

use super::GinoWindow;
use super::widgets::{apply_appearance, empty_state, muted};

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
                this.child(empty_state(cx, "No activity recorded yet."))
            })
            .when(count > 0, |this| {
                this.child(
                    uniform_list("activity-list", count, {
                        let records = records.clone();
                        move |range, _, cx| {
                            records
                                .iter()
                                .skip(range.start)
                                .take(range.end.saturating_sub(range.start))
                                .map(|record| activity_row(record, cx))
                                .collect::<Vec<_>>()
                        }
                    })
                    .flex_1()
                    .h_full(),
                )
            })
    }

    pub(crate) fn render_settings(
        &self,
        entity: Entity<Self>,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let save = entity.clone();
        let export = entity.clone();
        let releases = entity.clone();
        let backup_switch = entity;
        let (version, releases_url) = super::session::Session::about();

        // Opt-in/out for the local backup repo; mirrors set_backup_enabled
        // semantics (opting in creates the repository right away).
        let backup_toggle = Switch::new("backup-enabled")
            .checked(self.session.preferences.backup_enabled)
            .on_click(move |checked: &bool, window, cx| {
                backup_switch.update(cx, |app, cx| {
                    app.session.set_backup_enabled(*checked);
                    app.push_status(window, cx);
                    cx.notify();
                })
            });

        v_flex()
            .flex_1()
            .p_4()
            .gap_4()
            .overflow_y_scrollbar()
            .child(
                settings_group("about-group", "About")
                    .child(
                        div()
                            .text_lg()
                            .font_semibold()
                            .child(format!("Gino {version}")),
                    )
                    .child(
                        Link::new("open-releases")
                            .on_click(move |_, window, cx| {
                                releases.update(cx, |app, cx| {
                                    app.session.open_releases();
                                    app.push_status(window, cx);
                                    cx.notify();
                                });
                            })
                            .child(releases_url),
                    )
                    .child(muted(cx, "No telemetry. No in-app self-update.")),
            )
            .child(
                settings_group("appearance-group", "Appearance").child(
                    v_form()
                        .child(
                            field()
                                .label("Theme")
                                .child(Select::new(&self.theme_select).small()),
                        )
                        .child(
                            field()
                                .label("Text size")
                                .child(Select::new(&self.text_size_select).small()),
                        ),
                ),
            )
            .child(muted(
                cx,
                format!(
                    "Interface language: {}. 1.0 ships English only.",
                    self.session.language_label()
                ),
            ))
            .child(
                settings_group("editing-group", "Editing and network").child(
                    v_form()
                        .child(
                            field()
                                .label("External editor")
                                .child(Input::new(&self.editor_input)),
                        )
                        .child(
                            field()
                                .label("HTTP proxy (source / marketplace)")
                                .child(Input::new(&self.proxy_input)),
                        )
                        .child(
                            field()
                                .label("Agent display order (comma-separated ids)")
                                .child(Input::new(&self.agent_order_input)),
                        ),
                ),
            )
            .child(
                settings_group("backup-group", "Backup and snapshots").child(
                    v_form()
                        .child(
                            field()
                                .label("Local backup repository")
                                .description(
                                    "Off creates no ~/.gino/backup, commits nothing, and never \
                                     pushes. Snapshots still guard every Apply either way.",
                                )
                                .child(backup_toggle),
                        )
                        .child(
                            field()
                                .label("Backup remote")
                                .child(Input::new(&self.remote_input)),
                        )
                        .child(
                            field()
                                .label("Push mode")
                                .child(Select::new(&self.push_mode_select).small()),
                        )
                        .child(
                            field()
                                .label("Snapshot folder")
                                .child(Input::new(&self.snapshot_root_input)),
                        )
                        .child(
                            field()
                                .label("Snapshot retention")
                                .description(
                                    "Zero keeps no extra snapshots after success; Apply still \
                                     uses a temporary transaction snapshot until completion.",
                                )
                                .child(Input::new(&self.retention_input)),
                        )
                        .child(
                            field()
                                .label("Backup size policy (bytes)")
                                .child(Input::new(&self.size_policy_input)),
                        ),
                ),
            )
            .child(muted(cx, self.session.credential_status()))
            .child(
                h_flex()
                    .gap_2()
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
                                    if let Ok(count) = app.retention_input.read(cx).value().parse()
                                    {
                                        app.session.preferences.snapshot_retention = count;
                                    }
                                    let snapshot_root =
                                        app.snapshot_root_input.read(cx).value().to_string();
                                    if !snapshot_root.trim().is_empty() {
                                        app.session.preferences.snapshot_root =
                                            std::path::PathBuf::from(snapshot_root);
                                    }
                                    if let Ok(bytes) =
                                        app.size_policy_input.read(cx).value().parse()
                                    {
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
                    ),
            )
    }
}

/// A titled GroupBox section on the settings page.
fn settings_group(id: &'static str, title: &'static str) -> GroupBox {
    GroupBox::new().id(id).normal().title(title)
}

/// One structured activity record: timestamp, action, outcome tag, short
/// commit id, and restore origin, wrapped in a hoverable ListItem.
fn activity_row(record: &ActivityRecord, cx: &App) -> gpui::AnyElement {
    // Short 7-char commit display; the full id stays in the metadata store.
    let commit = record
        .commit_id
        .as_deref()
        .map(|id| id.chars().take(7).collect::<String>());
    ListItem::new(SharedString::from(format!(
        "{} {}",
        record.created_at, record.action
    )))
    .child(
        h_flex()
            .w_full()
            .min_w(px(0.))
            .gap_x_3()
            .items_center()
            .child(
                div()
                    .w(rems(10.))
                    .flex_shrink_0()
                    .text_sm()
                    .text_color(cx.theme().muted_foreground)
                    .truncate()
                    .child(record.created_at.clone()),
            )
            .child(
                div()
                    .flex_1()
                    .min_w(px(0.))
                    .text_sm()
                    .truncate()
                    .child(record.action.clone()),
            )
            .child(outcome_tag(&record.outcome))
            .children(commit.map(|commit| {
                div()
                    .flex_shrink_0()
                    .font_family(cx.theme().mono_font_family.clone())
                    .text_sm()
                    .text_color(cx.theme().muted_foreground)
                    .child(commit)
            }))
            .when_some(record.restore_origin.clone(), |row, origin| {
                row.child(
                    div()
                        .w(rems(8.))
                        .flex_shrink_0()
                        .text_sm()
                        .text_color(cx.theme().muted_foreground)
                        .truncate()
                        .child(origin),
                )
            }),
    )
    .into_any_element()
}

/// Success-y outcomes get a success tag; rollback/failed land on danger.
fn outcome_tag(outcome: &str) -> Tag {
    let lower = outcome.to_lowercase();
    if lower.contains("ok") || lower.contains("success") {
        Tag::success().small().child(outcome.to_owned())
    } else {
        Tag::danger().small().child(outcome.to_owned())
    }
}
