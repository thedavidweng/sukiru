use gino_core::inventory::SkillState;
use gino_core::metadata::Preferences;
use gpui::{
    App, ClipboardItem, Entity, IntoElement, ParentElement, SharedString, Styled, Window, div,
    prelude::FluentBuilder as _, px,
};
use gpui_component::{
    ActiveTheme, Disableable, IconName, StyledExt,
    button::{Button, ButtonVariants as _},
    h_flex,
    tag::Tag,
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
    Theme::global_mut(cx).font_size = match preferences.text_size.as_str() {
        "small" => px(13.),
        "large" => px(18.),
        _ => px(16.),
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
) -> impl IntoElement {
    Button::new(id.into())
        .ghost()
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
) -> impl IntoElement {
    Button::new(id.into())
        .primary()
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

pub fn status_badge(state: SkillState) -> impl IntoElement {
    match state {
        SkillState::Managed => Tag::success().child("Managed"),
        SkillState::Untracked => Tag::warning().child("Untracked"),
    }
}

pub fn empty_state(cx: &App, text: impl Into<SharedString>) -> impl IntoElement {
    div()
        .p_8()
        .text_sm()
        .text_color(cx.theme().muted_foreground)
        .child(text.into())
}

pub fn settings_heading(text: impl Into<SharedString>) -> impl IntoElement {
    div().pt_3().text_sm().font_semibold().child(text.into())
}

pub fn field_label(text: impl Into<SharedString>) -> impl IntoElement {
    div().text_sm().child(text.into())
}

pub fn progress_bar(cx: &App, busy: Option<BusyOp>) -> impl IntoElement {
    match busy {
        Some(op) => div()
            .w_full()
            .px_4()
            .py_2()
            .bg(cx.theme().info.opacity(0.10))
            .text_sm()
            .child(op.label())
            .into_any_element(),
        None => div().into_any_element(),
    }
}

pub fn issue_bar(
    cx: &App,
    entity: Entity<GinoWindow>,
    refresh: &Option<String>,
    action: &Option<String>,
    issues: &[String],
) -> impl IntoElement {
    let mut lines = Vec::new();
    if let Some(refresh) = refresh {
        lines.push(refresh.clone());
    }
    if let Some(action) = action {
        lines.push(action.clone());
    }
    lines.extend(issues.iter().cloned());
    if lines.is_empty() {
        return div().into_any_element();
    }
    let details = lines.join("\n");
    h_flex()
        .w_full()
        .px_4()
        .py_2()
        .gap_2()
        .items_start()
        .bg(cx.theme().danger.opacity(0.08))
        .child(
            v_flex()
                .flex_1()
                .gap_1()
                .children(lines.into_iter().map(|line| {
                    div()
                        .text_xs()
                        .text_color(cx.theme().danger)
                        .child(line)
                        .into_any_element()
                })),
        )
        .child(
            Button::new("copy-details")
                .ghost()
                .label("Copy details")
                .on_click(move |_, _, cx| {
                    cx.write_to_clipboard(ClipboardItem::new_string(details.clone()));
                    entity.update(cx, |app, cx| {
                        app.session.status = "Copied error details".to_owned();
                        cx.notify();
                    });
                }),
        )
        .into_any_element()
}

pub fn row_shell(cx: &App, selected: bool) -> gpui::Div {
    h_flex()
        .h(px(48.))
        .w_full()
        .px_4()
        .gap_x_3()
        .items_center()
        .border_b_1()
        .border_color(cx.theme().border)
        .when(selected, |this| this.bg(cx.theme().list_active))
}
