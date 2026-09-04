mod backup;
mod duplicates;
mod library;
mod marketplace;
mod options;
mod pending;
mod presets;
pub mod session;
mod settings;
mod widgets;
mod workspaces;

use gpui::{
    App, AppContext, Context, Entity, FocusHandle, InteractiveElement, IntoElement, KeyDownEvent,
    Keystroke, ParentElement, Render, Styled, Subscription, Window, div,
    prelude::FluentBuilder as _, px, rems,
};
use gpui_component::{
    ActiveTheme, Icon, IndexPath, Sizable as _, StyledExt as _, TitleBar, WindowExt,
    badge::Badge,
    button::{Button, ButtonVariants as _},
    dialog::DialogButtonProps,
    h_flex,
    input::{InputEvent, InputState},
    kbd::Kbd,
    notification::Notification,
    select::{SelectEvent, SelectState},
    sidebar::{Sidebar, SidebarFooter, SidebarGroup, SidebarHeader, SidebarMenu, SidebarMenuItem},
    v_flex,
};
use options::ChoiceOption;

use session::{BusyOp, KeyEffect, Section, Session, TagFilter};
use widgets::{
    apply_appearance, issue_banner, primary_button, progress_bar, section_icon, toolbar_button,
};

use gino_core::git::GitRepository;
use gino_core::inventory::{Inventory, InventoryScanner, Workspace};
use gino_core::metadata::Preferences;

fn position_of(options: &[ChoiceOption], value: &str) -> Option<IndexPath> {
    options
        .iter()
        .position(|option| option.value() == value)
        .map(IndexPath::new)
}

/// 1875 → "1,875" so large library counts stay readable at a glance.
fn format_count(count: usize) -> String {
    let digits = count.to_string();
    let mut grouped = String::with_capacity(digits.len() + digits.len() / 3);
    for (index, digit) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index) % 3 == 0 {
            grouped.push(',');
        }
        grouped.push(digit);
    }
    grouped
}

fn position_of_theme(current: &str) -> Option<IndexPath> {
    position_of(
        &[
            ChoiceOption::new("System", "system"),
            ChoiceOption::new("Light", "light"),
            ChoiceOption::new("Dark", "dark"),
        ],
        current,
    )
}

fn position_of_text_size(current: &str) -> Option<IndexPath> {
    position_of(
        &[
            ChoiceOption::new("Small", "small"),
            ChoiceOption::new("Medium", "medium"),
            ChoiceOption::new("Large", "large"),
        ],
        current,
    )
}

fn position_of_push_mode(current: &str) -> Option<IndexPath> {
    position_of(
        &[
            ChoiceOption::new("Commit locally", "commit_locally"),
            ChoiceOption::new("Commit and push", "commit_and_push"),
        ],
        current,
    )
}

/// Rows for the Keyboard dialog: a description plus native keycaps.
fn help_rows() -> Vec<(&'static str, Vec<Kbd>)> {
    fn keys(strokes: &[&str]) -> Vec<Kbd> {
        strokes
            .iter()
            .map(|stroke| Kbd::new(Keystroke::parse(stroke).expect("valid keystroke")))
            .collect()
    }
    vec![
        (
            "Switch section",
            keys(&["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]),
        ),
        ("Settings · Pending", keys(&["s", "p"])),
        ("Refresh · Apply", keys(&["r", "a"])),
        ("Search library · Shortcuts", keys(&["cmd-f", "cmd-k"])),
        ("Move selection", keys(&["up", "down"])),
        ("Toggle selection", keys(&["space"])),
        ("Queue remove", keys(&["backspace"])),
        ("Select visible", keys(&["cmd-a"])),
        ("Backup choices (in Backup)", keys(&["l", "u", "b"])),
        ("Submit search or source", keys(&["enter"])),
        ("Quit", keys(&["q"])),
    ]
}

// Native app-menu quit (⌘Q). The binding and menu item are registered in
// `main.rs`; the action lands here through the window's dispatch tree.
use gpui::actions;

actions!(gino, [QuitApp]);

pub struct GinoWindow {
    session: Session,
    query_input: Entity<InputState>,
    library_search_input: Entity<InputState>,
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
    tag_filter_select: Entity<SelectState<Vec<ChoiceOption>>>,
    workspace_filter_select: Entity<SelectState<Vec<ChoiceOption>>>,
    theme_select: Entity<SelectState<Vec<ChoiceOption>>>,
    text_size_select: Entity<SelectState<Vec<ChoiceOption>>>,
    push_mode_select: Entity<SelectState<Vec<ChoiceOption>>>,
    focus: FocusHandle,
    allow_exit: bool,
    issues_open: bool,
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
        let library_search_input =
            cx.new(|cx| InputState::new(window, cx).placeholder("Search skills…"));
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
        let theme_options = vec![
            ChoiceOption::new("System", "system"),
            ChoiceOption::new("Light", "light"),
            ChoiceOption::new("Dark", "dark"),
        ];
        let theme_select = cx.new(|cx| {
            SelectState::new(
                theme_options,
                position_of_theme(&preferences.theme),
                window,
                cx,
            )
        });
        let text_size_options = vec![
            ChoiceOption::new("Small", "small"),
            ChoiceOption::new("Medium", "medium"),
            ChoiceOption::new("Large", "large"),
        ];
        let text_size_select = cx.new(|cx| {
            SelectState::new(
                text_size_options,
                position_of_text_size(&preferences.text_size),
                window,
                cx,
            )
        });
        let push_mode_options = vec![
            ChoiceOption::new("Commit locally", "commit_locally"),
            ChoiceOption::new("Commit and push", "commit_and_push"),
        ];
        let push_mode_select = cx.new(|cx| {
            SelectState::new(
                push_mode_options,
                position_of_push_mode(&preferences.push_mode),
                window,
                cx,
            )
        });
        let tag_filter_select = cx.new(|cx| {
            SelectState::new(
                vec![ChoiceOption::all()],
                Some(IndexPath::new(0)),
                window,
                cx,
            )
        });
        let workspace_filter_select = cx.new(|cx| {
            SelectState::new(
                vec![ChoiceOption::all()],
                Some(IndexPath::new(0)),
                window,
                cx,
            )
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
                &library_search_input,
                window,
                |this, _, event: &InputEvent, _, cx| {
                    if let InputEvent::Change = event {
                        this.session.set_search(
                            this.library_search_input.read(cx).value().to_string(),
                        );
                        cx.notify();
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
            cx.subscribe_in(
                &theme_select,
                window,
                |this, _, event: &SelectEvent<Vec<ChoiceOption>>, window, cx| {
                    if let SelectEvent::Confirm(Some(value)) = event {
                        if this.session.preferences.theme != *value {
                            this.session.set_theme(value);
                            apply_appearance(&this.session.preferences, Some(window), cx);
                            cx.notify();
                        }
                    }
                },
            ),
            cx.subscribe_in(
                &text_size_select,
                window,
                |this, _, event: &SelectEvent<Vec<ChoiceOption>>, window, cx| {
                    if let SelectEvent::Confirm(Some(value)) = event {
                        if this.session.preferences.text_size != *value {
                            this.session.set_text_size(value);
                            apply_appearance(&this.session.preferences, Some(window), cx);
                            cx.notify();
                        }
                    }
                },
            ),
            cx.subscribe_in(
                &push_mode_select,
                window,
                |this, _, event: &SelectEvent<Vec<ChoiceOption>>, _, cx| {
                    if let SelectEvent::Confirm(Some(value)) = event {
                        if this.session.preferences.push_mode != *value {
                            this.session.set_push_mode(value);
                            cx.notify();
                        }
                    }
                },
            ),
            cx.subscribe_in(
                &tag_filter_select,
                window,
                |this, _, event: &SelectEvent<Vec<ChoiceOption>>, _, cx| {
                    if let SelectEvent::Confirm(Some(value)) = event {
                        this.session.tag_filter = match value.as_str() {
                            ChoiceOption::ALL => TagFilter::All,
                            ChoiceOption::UNTAGGED => TagFilter::Untagged,
                            tag => TagFilter::Tag(tag.to_owned()),
                        };
                        cx.notify();
                    }
                },
            ),
            cx.subscribe_in(
                &workspace_filter_select,
                window,
                |this, _, event: &SelectEvent<Vec<ChoiceOption>>, _, cx| {
                    if let SelectEvent::Confirm(Some(value)) = event {
                        this.session.workspace_filter =
                            (!value.is_empty()).then(|| value.to_owned());
                        cx.notify();
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
            library_search_input,
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
            tag_filter_select,
            workspace_filter_select,
            theme_select,
            text_size_select,
            push_mode_select,
            focus,
            allow_exit: false,
            issues_open: true,
            busy: None,
            _subscriptions: subscriptions,
        };
        if this.session.inventory.generation == 0 {
            this.start_refresh(window, cx);
        }
        this.sync_filter_options(window, cx);
        this
    }

    fn allow_close(&mut self, window: &mut Window, cx: &mut Context<Self>) -> bool {
        if self.allow_exit || self.session.pending.is_empty() {
            return true;
        }
        self.open_exit_dialog(window, cx);
        false
    }

    /// Quit request shared by the ⌘Q menu action and the `q` key: clean exit
    /// when nothing is pending, otherwise the apply/discard dialog gates it.
    /// ⌘Q reaches this through the app-level listener registered in `main.rs`,
    /// so it works regardless of which element holds focus.
    pub(crate) fn request_quit(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.allow_exit || self.session.pending.is_empty() {
            self.allow_exit = true;
            cx.quit();
        } else {
            self.open_exit_dialog(window, cx);
        }
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
        // A fresh scan re-raises the issue banner even if it was dismissed.
        self.issues_open = true;
        let workspaces = self.session.workspaces.clone();
        let generation = self.session.inventory.generation;
        self.start_job(
            BusyOp::Refresh,
            window,
            cx,
            move || InventoryScanner::new(&workspaces).scan(generation.saturating_add(1)),
            |this, result, window, cx| {
                this.session.apply_scan_result(result);
                this.sync_filter_options(window, cx);
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
            self.session.action_error = Some("Enter a source to attach".to_owned());
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
                    v_flex()
                        .w(rems(30.))
                        .gap_1()
                        .children(help_rows().into_iter().map(|(label, keys)| {
                            h_flex()
                                .justify_between()
                                .gap_4()
                                .py_0p5()
                                .child(div().text_sm().child(label))
                                .child(h_flex().gap_1().children(keys))
                        })),
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
        if stroke == "cmd-k" {
            self.open_help_dialog(window, cx);
            cx.notify();
            return;
        }
        if stroke == "cmd-f"
            && matches!(
                self.session.active_section,
                Section::Library | Section::Global
            )
        {
            self.library_search_input.update(cx, |state, cx| {
                state.focus(window, cx);
            });
            cx.notify();
            return;
        }
        if stroke == "escape" && !self.session.search.is_empty() {
            self.session.set_search(String::new());
            self.library_search_input.update(cx, |state, cx| {
                state.set_value("", window, cx);
            });
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

    /// Rebuild both filter dropdowns from the session caches and re-select
    /// the active filter. Items and selection are updated together so the
    /// menus never show a stale option list.
    pub(crate) fn sync_filter_options(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let mut workspaces = self.session.workspace_filter_options();
        workspaces.sort_by_cached_key(|(_, name)| name.to_lowercase());
        let mut workspace_options = vec![ChoiceOption::all()];
        workspace_options.extend(
            workspaces
                .into_iter()
                .map(|(id, name)| ChoiceOption::new(name, id)),
        );
        let workspace_current = self.session.workspace_filter.clone().unwrap_or_default();
        let workspace_index = position_of(&workspace_options, &workspace_current);

        let mut tag_options = vec![
            ChoiceOption::all(),
            ChoiceOption::new("Untagged", ChoiceOption::UNTAGGED),
        ];
        tag_options.extend(
            self.session
                .all_tags()
                .into_iter()
                .map(|tag| ChoiceOption::new(tag.clone(), tag)),
        );
        let tag_current = match &self.session.tag_filter {
            TagFilter::All => ChoiceOption::ALL.to_owned(),
            TagFilter::Untagged => ChoiceOption::UNTAGGED.to_owned(),
            TagFilter::Tag(tag) => tag.clone(),
        };
        let tag_index = position_of(&tag_options, &tag_current);

        self.workspace_filter_select.update(cx, |state, cx| {
            state.set_items(workspace_options, window, cx);
            state.set_selected_index(workspace_index, window, cx);
        });
        self.tag_filter_select.update(cx, |state, cx| {
            state.set_items(tag_options, window, cx);
            state.set_selected_index(tag_index, window, cx);
        });
    }
}

impl GinoWindow {
    fn render_sidebar_menu(
        &self,
        entity: Entity<Self>,
        cx: &mut Context<Self>,
    ) -> Vec<SidebarGroup<SidebarMenu>> {
        fn make_item(
            section: Section,
            active: Section,
            entity: &Entity<GinoWindow>,
            badge: Option<gpui::AnyElement>,
        ) -> SidebarMenuItem {
            let mut base =
                SidebarMenuItem::new(section.label()).icon(Icon::new(section_icon(section)));
            if active == section {
                base = base.active(true);
            }
            if let Some(badge) = badge {
                base = base.suffix(badge);
            }
            base.on_click({
                let entity = entity.clone();
                let target = section;
                move |_, _, cx| {
                    entity.update(cx, |app, cx| {
                        app.session.active_section = target;
                        cx.notify();
                    });
                }
            })
        }

        let active = self.session.active_section;
        let issue_count = self.session.inventory.issues.len();
        let duplicate_groups = self.session.visible_duplicate_groups().len();

        let library_badge = (issue_count > 0).then(|| {
            Badge::new()
                .count(issue_count)
                .color(cx.theme().danger)
                .into_any_element()
        });
        let duplicate_badge = (duplicate_groups > 0).then(|| {
            Badge::new()
                .count(duplicate_groups)
                .color(cx.theme().warning)
                .into_any_element()
        });

        vec![
            SidebarGroup::new("Skills").child(SidebarMenu::new().children([
                make_item(Section::Library, active, &entity, library_badge),
                make_item(Section::Marketplace, active, &entity, None),
            ])),
            SidebarGroup::new("Workspaces").child(SidebarMenu::new().children([
                make_item(Section::Global, active, &entity, None),
                make_item(Section::Projects, active, &entity, None),
                make_item(Section::Agents, active, &entity, None),
                make_item(Section::CustomWorkspaces, active, &entity, None),
            ])),
            SidebarGroup::new("Organize").child(SidebarMenu::new().children([
                make_item(Section::Duplicates, active, &entity, duplicate_badge),
                make_item(Section::Presets, active, &entity, None),
            ])),
            SidebarGroup::new("Maintenance").child(SidebarMenu::new().children([
                make_item(Section::Backup, active, &entity, None),
                make_item(Section::Activity, active, &entity, None),
            ])),
        ]
    }
}

impl Render for GinoWindow {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let entity = cx.entity();
        let key_entity = entity.clone();
        let sidebar = Sidebar::left()
            .collapsible(false)
            .header(
                SidebarHeader::new().child(
                    h_flex()
                        .px_3()
                        .py_2()
                        .gap_2()
                        .items_center()
                        .child(
                            div()
                                .size_6()
                                .rounded_sm()
                                .bg(cx.theme().primary)
                                .flex()
                                .items_center()
                                .justify_center()
                                .child(
                                    div()
                                        .text_xs()
                                        .font_bold()
                                        .text_color(cx.theme().primary_foreground)
                                        .child("G"),
                                ),
                        )
                        .child(
                            v_flex()
                                .min_w(px(0.))
                                .child(div().text_sm().font_semibold().child("Gino"))
                                .child(
                                    div()
                                        .text_xs()
                                        .text_color(cx.theme().muted_foreground)
                                        .child("Skills manager"),
                                ),
                        ),
                ),
            )
            .children(self.render_sidebar_menu(cx.entity(), cx))
            .footer(SidebarFooter::new().child({
                let entity = cx.entity();
                SidebarMenuItem::new("Settings")
                    .icon(Icon::new(section_icon(Section::Settings)))
                    .active(self.session.active_section == Section::Settings)
                    .on_click(move |_, _, cx| {
                        entity.update(cx, |app, cx| {
                            app.session.active_section = Section::Settings;
                            cx.notify();
                        });
                    })
            }));
        let pending_count = self.session.selected_pending_count();
        let can_apply = self.session.can_apply();
        let title_bar = TitleBar::new()
            .child(
                h_flex()
                    .min_w(px(0.))
                    .gap_2()
                    .pr_4()
                    .items_center()
                    .child(div().text_sm().font_semibold().child("Gino"))
                    .child(
                        div()
                            .min_w(px(0.))
                            .max_w(px(420.))
                            .truncate()
                            .text_xs()
                            .text_color(cx.theme().muted_foreground)
                            .child(self.session.status.clone()),
                    ),
            )
            .child(
                h_flex()
                    .flex_shrink_0()
                    .gap_1()
                    .items_center()
                    .pr_2()
                    .child(toolbar_button(
                        entity.clone(),
                        "refresh",
                        "Refresh",
                        self.is_busy(),
                        |app, window, cx| app.start_refresh(window, cx),
                    ))
                    .when(pending_count > 0 || can_apply, |this| {
                        this.child(toolbar_button(
                            entity.clone(),
                            "pending",
                            format!("{pending_count} pending"),
                            false,
                            |app, _, _| app.session.active_section = Section::Pending,
                        ))
                    })
                    .child(primary_button(
                        entity.clone(),
                        "apply",
                        self.session.apply_label(),
                        !can_apply || self.is_busy(),
                        |app, window, cx| app.start_apply(window, cx),
                    )),
            );

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

        let browsing_library = matches!(
            self.session.active_section,
            Section::Library | Section::Global
        );
        let visible_count = self.session.visible_placements().len();
        let selected_count = self.session.selected_paths.len();
        let content_header = h_flex()
            .flex_shrink_0()
            .px_4()
            .py_3()
            .gap_2()
            .items_center()
            .justify_between()
            .border_b_1()
            .border_color(cx.theme().border)
            .child(
                h_flex()
                    .min_w(px(0.))
                    .gap_2()
                    .items_center()
                    .child(
                        div()
                            .text_lg()
                            .font_semibold()
                            .child(if browsing_library {
                                "Skills Library".to_owned()
                            } else {
                                self.session.active_section.label().to_owned()
                            }),
                    )
                    .when(browsing_library, |this| {
                        this.child(
                            div()
                                .text_sm()
                                .text_color(cx.theme().muted_foreground)
                                .child(format_count(visible_count) + " skills"),
                        )
                        .when(selected_count > 0, |this| {
                            this.child(
                                div()
                                    .text_sm()
                                    .text_color(cx.theme().muted_foreground)
                                    .child(format!("· {selected_count} selected")),
                            )
                        })
                    }),
            )
            .child(
                Button::new("shortcuts")
                    .ghost()
                    .small()
                    .label("Shortcuts")
                    .child(Kbd::new(Keystroke::parse("cmd-k").expect("valid keystroke")))
                    .on_click({
                        let entity = entity.clone();
                        move |_, window, cx| {
                            entity.update(cx, |app, cx| app.open_help_dialog(window, cx));
                        }
                    }),
            );

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
            .child(title_bar)
            .child(
                h_flex().flex_1().min_h(px(0.)).child(sidebar).child(
                    v_flex()
                        .flex_1()
                        .min_w(px(0.))
                        .min_h(px(0.))
                        .h_full()
                        .child(content_header)
                        .child(progress_bar(cx, self.busy))
                        .child(issue_banner(
                            cx,
                            entity,
                            &self.session.refresh_error,
                            &self.session.action_error,
                            &self.session.issue_summaries(),
                            self.issues_open,
                        ))
                        .child(body),
                ),
            )
    }
}
