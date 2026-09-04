use gino_core::inventory::SkillState;
use gino_core::metadata::Preferences;
use gpui::{
    App, Corner, Entity, InteractiveElement, IntoElement, ParentElement, SharedString, Styled,
    Window, div, px, rems,
};
use gpui_component::{
    ActiveTheme, Disableable, Icon, IconName, Sizable as _, StyledExt,
    alert::Alert,
    button::{Button, ButtonVariants as _},
    clipboard::Clipboard,
    h_flex,
    popover::Popover,
    scroll::ScrollableElement as _,
    spinner::Spinner,
    v_flex,
};
use gpui_component::{Theme, ThemeMode};

use super::GinoWindow;
use super::session::{BusyOp, Section};

pub fn apply_appearance(preferences: &Preferences, window: Option<&mut Window>, cx: &mut App) {
    let mode = match preferences.theme.as_str() {
        "dark" => ThemeMode::Dark,
        "light" => ThemeMode::Light,
        _ => window
            .as_deref()
            .map(|window| ThemeMode::from(window.appearance()))
            .unwrap_or(ThemeMode::Light),
    };
    Theme::change(mode, window, cx);
    let theme = Theme::global_mut(cx);
    theme.font_size = match preferences.text_size.as_str() {
        "small" => px(12.),
        "large" => px(16.),
        _ => px(13.),
    };
}

pub fn section_icon(section: Section) -> IconName {
    match section {
        Section::Library => IconName::LayoutDashboard,
        Section::Marketplace => IconName::Search,
        Section::Global => IconName::Globe,
        Section::Projects => IconName::Folder,
        Section::Agents => IconName::Bot,
        Section::CustomWorkspaces => IconName::FolderOpen,
        Section::Duplicates => IconName::Copy,
        Section::Presets => IconName::Star,
        Section::Backup => IconName::GitHub,
        Section::Activity => IconName::Inbox,
        Section::Settings => IconName::Settings,
        Section::Pending => IconName::CircleCheck,
    }
}

pub fn toolbar_button(
    entity: Entity<GinoWindow>,
    id: impl Into<SharedString>,
    label: impl Into<SharedString>,
    disabled: bool,
    on_click: impl Fn(&mut GinoWindow, &mut Window, &mut gpui::Context<GinoWindow>) + 'static,
) -> Button {
    Button::new(id.into())
        .ghost()
        .xsmall()
        .disabled(disabled)
        .label(label.into())
        .on_click(move |_, window, cx| {
            entity.update(cx, |app, cx| {
                on_click(app, window, cx);
                cx.notify();
            });
        })
}

pub fn primary_button(
    entity: Entity<GinoWindow>,
    id: impl Into<SharedString>,
    label: impl Into<SharedString>,
    disabled: bool,
    on_click: impl Fn(&mut GinoWindow, &mut Window, &mut gpui::Context<GinoWindow>) + 'static,
) -> Button {
    Button::new(id.into())
        .primary()
        .xsmall()
        .disabled(disabled)
        .label(label.into())
        .on_click(move |_, window, cx| {
            entity.update(cx, |app, cx| {
                on_click(app, window, cx);
                cx.notify();
            });
        })
}

pub fn muted(cx: &App, text: impl Into<SharedString>) -> impl IntoElement {
    div()
        .text_sm()
        .text_color(cx.theme().muted_foreground)
        .child(text.into())
}

/// Compact tracking indicator for list rows: filled dot for Managed skills,
/// hollow ring for Untracked ones.
pub fn status_dot(state: &SkillState, cx: &App) -> impl IntoElement {
    match state {
        SkillState::Managed => div()
            .size_2()
            .rounded_full()
            .bg(cx.theme().success)
            .into_any_element(),
        SkillState::Untracked => div()
            .size_2()
            .rounded_full()
            .bg(gpui::transparent_black())
            .border_1()
            .border_color(cx.theme().muted_foreground)
            .into_any_element(),
    }
}

pub fn empty_state(cx: &App, text: impl Into<SharedString>) -> impl IntoElement {
    v_flex()
        .flex_1()
        .items_center()
        .justify_center()
        .gap_2()
        .p_8()
        .child(
            div()
                .size_10()
                .rounded_full()
                .bg(cx.theme().muted)
                .flex()
                .items_center()
                .justify_center()
                .child(
                    Icon::new(IconName::Inbox)
                        .size_4()
                        .text_color(cx.theme().muted_foreground),
                ),
        )
        .child(
            div()
                .max_w(px(420.))
                .text_center()
                .text_sm()
                .text_color(cx.theme().muted_foreground)
                .child(text.into()),
        )
}

/// Slim strip shown while a background job runs, with an animated spinner.
pub fn progress_bar(cx: &App, busy: Option<BusyOp>) -> impl IntoElement {
    match busy {
        Some(op) => h_flex()
            .w_full()
            .px_4()
            .py_1()
            .gap_2()
            .items_center()
            .border_b_1()
            .border_color(cx.theme().border)
            .bg(cx.theme().info.opacity(0.06))
            .child(Spinner::new().color(cx.theme().info))
            .child(
                div()
                    .text_xs()
                    .font_medium()
                    .text_color(cx.theme().info)
                    .child(op.label()),
            )
            .into_any_element(),
        None => div().into_any_element(),
    }
}

/// Collapsed attention banner for scan/action errors and inventory issues.
///
/// One native Alert line carries the headline and the dismiss button; the
/// full list lives one click away in the Details popover, with a copy
/// button. Dismissing only hides the banner until the next refresh produces
/// a fresh scan.
pub fn issue_banner(
    _cx: &App,
    entity: Entity<GinoWindow>,
    refresh: &Option<String>,
    action: &Option<String>,
    issues: &[String],
    open: bool,
) -> impl IntoElement {
    let mut lines = Vec::new();
    if let Some(refresh) = refresh {
        lines.push(refresh.clone());
    }
    if let Some(action) = action {
        lines.push(action.clone());
    }
    lines.extend(issues.iter().cloned());
    if lines.is_empty() || !open {
        return div().into_any_element();
    }
    let total = lines.len();
    let details = lines.join("\n");
    let dismiss_entity = entity;
    let headline = if total == 1 {
        "1 issue needs attention".to_owned()
    } else {
        format!("{total} issues need attention")
    };
    // A failed refresh or action outranks inventory warnings in severity.
    let alert = if refresh.is_some() || action.is_some() {
        Alert::error("issue-banner", headline)
    } else {
        Alert::warning("issue-banner", headline)
    };

    h_flex()
        .w_full()
        .items_center()
        .gap_2()
        .pr_2()
        .child(
            div()
                .flex_1()
                .min_w(px(0.))
                .child(alert.banner().on_close(move |_, _, cx| {
                    dismiss_entity.update(cx, |app, cx| {
                        app.issues_open = false;
                        cx.notify();
                    });
                })),
        )
        .child(
            Popover::new("issue-details")
                .trigger(
                    Button::new("issue-details-trigger")
                        .ghost()
                        .xsmall()
                        .label(format!("{total} details")),
                )
                .anchor(Corner::TopRight)
                .content({
                    let muted_foreground = _cx.theme().muted_foreground;
                    move |_, _, _| {
                        v_flex()
                            .w(rems(28.))
                            .gap_1()
                            .child(
                                div()
                                    .id("issue-details-lines")
                                    .max_h(rems(16.))
                                    .overflow_y_scrollbar()
                                    .children(lines.iter().map(|line| {
                                        div()
                                            .text_xs()
                                            .text_color(muted_foreground)
                                            .truncate()
                                            .child(line.clone())
                                    })),
                            )
                            .child(
                                h_flex().justify_end().child(
                                    Clipboard::new("copy-issue-details").value(details.clone()),
                                ),
                            )
                    }
                }),
        )
        .into_any_element()
}
