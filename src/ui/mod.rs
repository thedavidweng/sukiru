mod backup;
mod duplicates;
mod library;
mod marketplace;
mod pending;
mod presets;
pub mod session;
mod settings;
mod widgets;
mod workspaces;

use gpui::{
    App, AppContext, Context, Entity, FocusHandle, InteractiveElement, IntoElement, KeyDownEvent,
    ParentElement, Render, Styled, Subscription, Window, div,
};
use gpui_component::{
    ActiveTheme, Icon, StyledExt, WindowExt,
    button::{Button, ButtonVariants as _},
    dialog::DialogButtonProps,
    h_flex,
    input::{InputEvent, InputState},
    notification::Notification,
    sidebar::{Sidebar, SidebarMenu, SidebarMenuItem},
    v_flex,
};

use session::{BusyOp, KeyEffect, Section, Session};
use widgets::{
    apply_appearance, issue_bar, primary_button, progress_bar, section_icon, toolbar_button,
};

use gino_core::git::GitRepository;
use gino_core::inventory::{Inventory, InventoryScanner, Workspace};
use gino_core::metadata::Preferences;

pub struct GinoWindow {
    session: Session,
    query_input: Entity<InputState>,
    source_input: Entity<InputState>,
    attach_input: Entity<InputState>,
    preset_input: Entity<InputState>,
    tag_input: Entity<InputState>,
    editor_input: Entity<InputState>,
    proxy_input: Entity<InputState>,
    remote_input: Entity<InputState>,
    retention_input: Entity<InputState>,
    snapshot_root_input: Entity<InputState>,
    size_policy_input: Entity<InputState>,
    agent_order_input: Entity<InputState>,
    focus: FocusHandle,
    allow_exit: bool,
    busy: Option<BusyOp>,
    _subscriptions: Vec<Subscription>,
}

impl GinoWindow {
    pub fn new(
        workspaces: Vec<Workspace>,
        inventory: Inventory,
        backup: gino_core::Result<GitRepository>,
        metadata_path: std::path::PathBuf,
        preferences: Preferences,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        apply_appearance(&preferences, Some(window), cx);
        window.set_window_title("Gino");
        let query_input = cx.new(|cx| {
            InputState::new(window, cx).placeholder("Search skills.sh (min 2 characters)")
        });
        let source_input = cx.new(|cx| {
            InputState::new(window, cx).placeholder("owner/repo@skill, local path, or URL")
        });
        let attach_input = cx.new(|cx| {
            InputState::new(window, cx).placeholder("owner/repo@skill, local path, or URL")
        });
        let preset_input = cx.new(|cx| InputState::new(window, cx).placeholder("Preset name"));
        let tag_input =
            cx.new(|cx| InputState::new(window, cx).placeholder("Tag for selected Skill"));
        let editor_input = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder("External editor command")
                .default_value(preferences.editor.clone())
        });
        let proxy_input = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder("http://proxy:port")
                .default_value(preferences.proxy.clone())
        });
        let remote_input = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder("git@host:org/backup.git")
                .default_value(preferences.backup_remote.clone())
        });
        let retention_input = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder("Snapshot retention count")
                .default_value(preferences.snapshot_retention.to_string())
        });
        let snapshot_root_input = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder("Snapshot folder")
                .default_value(preferences.snapshot_root.display().to_string())
        });
        let size_policy_input = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder("Backup size policy in bytes")
                .default_value(preferences.size_policy_bytes.to_string())
        });
        let agent_order_input = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder("claude,codex,opencode")
                .default_value(preferences.agent_order.clone())
        });
        let focus = cx.focus_handle();
        focus.focus(window);
        let entity = cx.entity();
        window.on_window_should_close(cx, move |window, cx| {
            entity.update(cx, |app, cx| app.allow_close(window, cx))
        });
        let subscriptions = vec![
            cx.subscribe_in(
                &query_input,
                window,
                |this, _, event: &InputEvent, window, cx| {
                    if matches!(event, InputEvent::PressEnter { .. }) {
                        this.start_search(window, cx);
                    }
                },
            ),
            cx.subscribe_in(
                &source_input,
                window,
                |this, _, event: &InputEvent, window, cx| {
                    if matches!(event, InputEvent::PressEnter { .. }) {
                        this.queue_source_from_input(window, cx);
                    }
                },
            ),
            cx.subscribe_in(
                &attach_input,
                window,
                |this, _, event: &InputEvent, window, cx| {
                    if matches!(event, InputEvent::PressEnter { .. }) {
                        this.queue_attach_from_input(window, cx);
                    }
                },
            ),
            cx.observe_window_appearance(window, |this, window, cx| {
                if this.session.preferences.theme == "system" {
                    apply_appearance(&this.session.preferences, Some(window), cx);
                    cx.notify();
                }
            }),
        ];
        let mut this = Self {
            session: Session::new(workspaces, inventory, backup, metadata_path, preferences),
            query_input,
            source_input,
            attach_input,
            preset_input,
            tag_input,
            editor_input,
            proxy_input,
            remote_input,
            retention_input,
            snapshot_root_input,
            size_policy_input,
            agent_order_input,
            focus,
            allow_exit: false,
            busy: None,
            _subscriptions: subscriptions,
        };
        if this.session.inventory.generation == 0 {
            this.start_refresh(window, cx);
        }
        this
    }

    fn allow_close(&mut self, window: &mut Window, cx: &mut Context<Self>) -> bool {
        if self.allow_exit || self.session.pending.is_empty() {
            return true;
        }
        self.open_exit_dialog(window, cx);
        false
    }

    fn open_exit_dialog(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.session.quit_offered = true;
        let entity = cx.entity();
        window.open_dialog(cx, move |dialog, _, _| {
            let apply = entity.clone();
            let discard = entity.clone();
            dialog
                .title("Pending Changes")
                .overlay_closable(false)
                .close_button(false)
                .button_props(DialogButtonProps::default().cancel_text("Cancel"))
                .child(
                    "Apply and Quit applies the batch, then exits only after success. Discard and Quit clears the plan. Cancel returns to the application. Pending Changes are not saved as a draft.",
                )
                .footer(move |_ok, cancel, window, cx| {
                    vec![
                        Button::new("apply-quit")
                            .primary()
                            .label("Apply and Quit")
                            .on_click({
                                let apply = apply.clone();
                                move |_, window, cx| {
                                    apply.update(cx, |app, cx| {
                                        if app.session.apply_pending() {
                                            app.allow_exit = true;
                                            window.close_dialog(cx);
                                            cx.quit();
                                        } else {
                                            window.push_notification(
                                                Notification::error(
                                                    app.session
                                                        .action_error
                                                        .clone()
                                                        .unwrap_or_else(|| {
                                                            "Apply failed".to_owned()
                                                        }),
                                                ),
                                                cx,
                                            );
                                            window.close_dialog(cx);
                                        }
                                        cx.notify();
                                    });
                                }
                            })
                            .into_any_element(),
                        Button::new("discard-quit")
                            .danger()
                            .label("Discard and Quit")
                            .on_click({
                                let discard = discard.clone();
                                move |_, window, cx| {
                                    discard.update(cx, |app, cx| {
                                        app.session.discard_and_prepare_quit();
                                        app.allow_exit = true;
                                        window.close_dialog(cx);
                                        cx.quit();
                                        cx.notify();
                                    });
                                }
                            })
                            .into_any_element(),
                        cancel(window, cx),
                    ]
                })
                .on_cancel({
                    let entity = entity.clone();
                    move |_, _, cx| {
                        entity.update(cx, |app, _| app.session.cancel_quit());
                        true
                    }
                })
        });
    }

    fn is_busy(&self) -> bool {
        self.busy.is_some()
    }

    fn start_job<T, F, D>(
        &mut self,
        op: BusyOp,
        window: &mut Window,
        cx: &mut Context<Self>,
        work: F,
        done: D,
    ) where
        T: Send + 'static,
        F: FnOnce() -> T + Send + 'static,
        D: FnOnce(&mut Self, T, &mut Window, &mut Context<Self>) + 'static,
    {
        if self.busy.is_some() {
            self.session.action_error =
                Some("Wait for the current operation to finish, then try again".to_owned());
            self.push_status(window, cx);
            return;
        }
        self.busy = Some(op);
        self.session.status = op.label().to_owned();
        cx.spawn_in(window, async move |this, cx| {
            let result = cx.background_executor().spawn(async move { work() }).await;
            this.update_in(cx, |this, window, cx| {
                this.busy = None;
                done(this, result, window, cx);
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    fn start_refresh(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let workspaces = self.session.workspaces.clone();
        let generation = self.session.inventory.generation;
        self.start_job(
            BusyOp::Refresh,
            window,
            cx,
            move || InventoryScanner::new(&workspaces).scan(generation.saturating_add(1)),
            |this, result, window, cx| {
                this.session.apply_scan_result(result);
                this.push_status(window, cx);
            },
        );
    }

    fn start_apply(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        match self.session.apply_job() {
            Ok(job) => self.start_job(
                BusyOp::Apply,
                window,
                cx,
                move || job.run(),
                |this, outcome, window, cx| {
                    this.session.complete_apply(outcome);
                    this.push_status(window, cx);
                },
            ),
            Err(reason) => {
                self.session.action_error = Some(reason);
                self.push_status(window, cx);
            }
        }
    }

    pub(crate) fn start_search(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.session.marketplace_query = self.query_input.read(cx).value().to_string();
        if self.session.marketplace_query.trim().len() < 2 {
            self.session.action_error =
                Some("Type at least 2 characters to search skills.sh".to_owned());
            self.push_status(window, cx);
            return;
        }
        let query = self.session.marketplace_query.clone();
        let proxy = (!self.session.preferences.proxy.is_empty())
            .then(|| self.session.preferences.proxy.clone());
        self.start_job(
            BusyOp::Search,
            window,
            cx,
            move || {
                gino_core::marketplace::search_skills(
                    &query,
                    gino_core::marketplace::DEFAULT_MARKETPLACE_URL,
                    proxy.as_deref(),
                )
            },
            |this, result, window, cx| {
                match result {
                    Ok(results) => {
                        this.session.marketplace_results = results;
                        this.session.marketplace_selected.clear();
                        this.session.action_error = None;
                        this.session.status = format!(
                            "{} marketplace results",
                            this.session.marketplace_results.len()
                        );
                    }
                    Err(error) => this.session.action_error = Some(error.to_string()),
                }
                this.push_status(window, cx);
            },
        );
    }

    pub(crate) fn start_remote_check(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(repository) = self.session.backup.clone() else {
            self.session.action_error = Some("Backup repository is unavailable".to_owned());
            self.push_status(window, cx);
            return;
        };
        let inventory = self.session.inventory.clone();
        self.start_job(
            BusyOp::Remote,
            window,
            cx,
            move || {
                repository
                    .fetch()
                    .and_then(|_| repository.propose_sync(&inventory))
            },
            |this, result, window, cx| {
                match result {
                    Ok(proposal) => {
                        let count = proposal
                            .changes
                            .iter()
                            .filter(|change| {
                                change.status != gino_core::git::RemoteChangeStatus::Unchanged
                            })
                            .count();
                        let short = &proposal.remote_commit[..7.min(proposal.remote_commit.len())];
                        this.session.status =
                            format!("Remote {short}: {count} changes (nothing written)");
                        this.session.sync_proposal = Some(proposal);
                        this.session.focused_sync_index = None;
                        this.session.action_error = None;
                        this.session.reload_caches();
                    }
                    Err(error) => this.session.action_error = Some(error.to_string()),
                }
                this.push_status(window, cx);
            },
        );
    }

    pub(crate) fn queue_source_from_input(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.session.marketplace_source = self.source_input.read(cx).value().to_string();
        let source = self.session.marketplace_source.clone();
        if source.trim().is_empty() {
            self.session.action_error = Some("Enter a source to install".to_owned());
            self.push_status(window, cx);
            return;
        }
        self.start_discover(source, None, window, cx);
    }

    pub(crate) fn queue_attach_from_input(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let source = self.attach_input.read(cx).value().to_string();
        if source.trim().is_empty() {
            self.session.action_error = Some("Enter a source, then queue Attach Source".to_owned());
            self.push_status(window, cx);
            return;
        }
        self.session.queue_attach_source(&source);
        self.push_status(window, cx);
    }

    pub(crate) fn start_queue_marketplace(
        &mut self,
        selected: Vec<gino_core::marketplace::MarketplaceSkill>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.start_job(
            BusyOp::Discover,
            window,
            cx,
            move || {
                selected
                    .into_iter()
                    .map(|skill| {
                        let source = if skill.source.is_empty() {
                            skill.id.clone()
                        } else {
                            skill.source.clone()
                        };
                        Session::discover_source_input(&source)
                            .map(|(source, discovered)| (source, discovered, skill.name))
                    })
                    .collect::<std::result::Result<Vec<_>, _>>()
            },
            |this, result, window, cx| {
                match result {
                    Ok(items) => {
                        for (source, discovered, name) in items {
                            this.session.queue_discovered_install(
                                source,
                                discovered,
                                Some(name.as_str()),
                            );
                        }
                    }
                    Err(error) => this.session.action_error = Some(error),
                }
                this.push_status(window, cx);
            },
        );
    }

    pub(crate) fn start_discover(
        &mut self,
        source: String,
        hint: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.start_job(
            BusyOp::Discover,
            window,
            cx,
            move || Session::discover_source_input(&source),
            move |this, result, window, cx| {
                match result {
                    Ok((source, discovered)) => {
                        this.session
                            .queue_discovered_install(source, discovered, hint.as_deref())
                    }
                    Err(error) => this.session.action_error = Some(error),
                }
                this.push_status(window, cx);
            },
        );
    }

    pub(crate) fn start_folder_pick(
        &mut self,
        kind: gino_core::inventory::WorkspaceKind,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.start_job(
            BusyOp::Folder,
            window,
            cx,
            gino_core::platform::pick_folder,
            move |this, result, window, cx| {
                match result {
                    Ok(Some(path)) => this.session.register_folder_path(kind.clone(), path),
                    Ok(None) => this.session.status = "Folder picker cancelled".to_owned(),
                    Err(error) => this.session.action_error = Some(error.to_string()),
                }
                this.push_status(window, cx);
            },
        );
    }

    fn open_help_dialog(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        window.open_dialog(cx, move |dialog, _, _| {
            dialog
                .title("Keyboard")
                .child(
                    "1–9 Library through Backup · 0 Activity · S Settings · P Pending · R Refresh · A Apply · arrows move selection · Space toggle · Delete queue remove · ⌘A/Ctrl+A select visible · L/U/B backup choices · Q quit · Enter submits search or source · ? this list",
                )
        });
    }

    fn dispatch_key(&mut self, stroke: &str, window: &mut Window, cx: &mut Context<Self>) {
        if self.is_busy() && matches!(stroke, "r" | "a") {
            self.session.action_error =
                Some("Wait for the current operation to finish, then try again".to_owned());
            self.push_status(window, cx);
            cx.notify();
            return;
        }
        if stroke == "r" {
            self.start_refresh(window, cx);
            cx.notify();
            return;
        }
        if stroke == "a" {
            self.start_apply(window, cx);
            cx.notify();
            return;
        }
        match self.session.handle_key(stroke) {
            KeyEffect::Ignored => {}
            KeyEffect::Handled => cx.notify(),
            KeyEffect::ShowHelp => {
                self.open_help_dialog(window, cx);
                cx.notify();
            }
            KeyEffect::PromptQuit => {
                self.open_exit_dialog(window, cx);
                cx.notify();
            }
            KeyEffect::Quit => {
                self.allow_exit = true;
                cx.quit();
            }
        }
    }

    pub(crate) fn push_status(&self, window: &mut Window, cx: &mut App) {
        if let Some(error) = &self.session.action_error {
            window.push_notification(Notification::error(error.clone()), cx);
        } else if self.session.refresh_error.is_none() {
            window.push_notification(Notification::success(self.session.status.clone()), cx);
        }
    }
}

impl Render for GinoWindow {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let entity = cx.entity();
        let key_entity = entity.clone();
        let sidebar = Sidebar::left()
            .collapsible(false)
            .child(
                SidebarMenu::new().children(Section::SIDEBAR.iter().map(|section| {
                    let label = section.label().to_owned();
                    let target = *section;
                    SidebarMenuItem::new(label)
                        .icon(Icon::new(section_icon(*section)))
                        .active(self.session.active_section == *section)
                        .on_click({
                            let entity = entity.clone();
                            move |_, _, cx| {
                                entity.update(cx, |app, cx| {
                                    app.session.active_section = target;
                                    cx.notify();
                                });
                            }
                        })
                })),
            );
        let pending_count = self.session.selected_pending_count();
        let can_apply = self.session.can_apply();
        let chrome = h_flex()
            .h_16()
            .w_full()
            .px_4()
            .gap_x_2()
            .items_center()
            .border_b_1()
            .border_color(cx.theme().border)
            .child(
                div()
                    .flex_1()
                    .text_xl()
                    .font_semibold()
                    .child(self.session.active_section.label().to_owned()),
            )
            .child(
                div()
                    .text_xs()
                    .text_color(cx.theme().muted_foreground)
                    .child(self.session.status.clone()),
            )
            .child(toolbar_button(
                entity.clone(),
                "refresh",
                "Refresh",
                self.is_busy(),
                |app, window, cx| app.start_refresh(window, cx),
            ))
            .child(toolbar_button(
                entity.clone(),
                "remove",
                "Queue Remove",
                self.is_busy(),
                |app, _, _| {
                    app.session.queue_remove_selected();
                },
            ))
            .child(toolbar_button(
                entity.clone(),
                "cleanup-broken",
                "Clean Broken Links",
                !self.session.has_broken_symlinks() || self.is_busy(),
                |app, _, _| {
                    app.session.queue_cleanup_broken_symlinks();
                },
            ))
            .child(toolbar_button(
                entity.clone(),
                "pending",
                &format!("{pending_count} pending"),
                false,
                |app, _, _| app.session.active_section = Section::Pending,
            ))
            .child(primary_button(
                entity.clone(),
                "apply",
                self.session.apply_label(),
                !can_apply || self.is_busy(),
                |app, window, cx| app.start_apply(window, cx),
            ))
            .child(toolbar_button(
                entity.clone(),
                "shortcuts",
                "Shortcuts",
                false,
                |app, window, cx| app.open_help_dialog(window, cx),
            ));

        let body = match self.session.active_section {
            Section::Marketplace => self
                .render_marketplace(entity.clone(), window, cx)
                .into_any_element(),
            Section::Pending => self
                .render_pending(entity.clone(), window, cx)
                .into_any_element(),
            Section::Duplicates => self
                .render_duplicates(entity.clone(), window, cx)
                .into_any_element(),
            Section::Presets => self
                .render_presets(entity.clone(), window, cx)
                .into_any_element(),
            Section::Backup => self
                .render_backup(entity.clone(), window, cx)
                .into_any_element(),
            Section::Activity => self
                .render_activity(entity.clone(), window, cx)
                .into_any_element(),
            Section::Settings => self
                .render_settings(entity.clone(), window, cx)
                .into_any_element(),
            Section::Projects | Section::CustomWorkspaces => self
                .render_workspace_admin(entity.clone(), window, cx)
                .into_any_element(),
            Section::Agents => self
                .render_workspace_admin(entity.clone(), window, cx)
                .into_any_element(),
            Section::Library | Section::Global => self
                .render_library(entity.clone(), window, cx)
                .into_any_element(),
        };

        v_flex()
            .id("gino-root")
            .track_focus(&self.focus)
            .size_full()
            .bg(cx.theme().background)
            .text_color(cx.theme().foreground)
            .on_key_down(move |event: &KeyDownEvent, window, cx| {
                if window.has_focused_input(cx) {
                    let stroke = format!("{}", event.keystroke);
                    if stroke != "escape" {
                        return;
                    }
                }
                let stroke = format!("{}", event.keystroke);
                key_entity.update(cx, |app, cx| app.dispatch_key(&stroke, window, cx));
            })
            .child(
                h_flex().size_full().child(sidebar).child(
                    v_flex()
                        .flex_1()
                        .h_full()
                        .child(chrome)
                        .child(progress_bar(cx, self.busy))
                        .child(issue_bar(
                            cx,
                            entity,
                            &self.session.refresh_error,
                            &self.session.action_error,
                            &self.session.issue_summaries(),
                        ))
                        .child(body),
                ),
            )
    }
}
