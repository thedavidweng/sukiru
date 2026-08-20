//! Session-scoped application state for the GPUI surfaces.
//!
//! Views derive from this model. Selection, search, and planning never write
//! Skill files; the only write path is [`Session::apply_pending`].

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

use gino_core::agents::AgentRegistry;
use gino_core::command::equivalent_command;
use gino_core::discovery::DiscoveryResult;
use gino_core::executor::{ApplyExecutor, ApplyResult, Snapshot, SnapshotStore};
use gino_core::git::{
    CommitInfo, GitRepository, PushMode, PushStatus, RemoteChangeStatus, RemoteSkillChange,
    SyncProposal,
};
use gino_core::inventory::{
    DuplicateClass, DuplicateGroup, Inventory, InventoryScanner, PlacementKind, SkillPlacement,
    SkillState, Workspace, WorkspaceKind,
};
use gino_core::marketplace::{self, MarketplaceSkill};
use gino_core::metadata::{
    APP_VERSION, ActivityRecord, MetadataStore, Preferences, RELEASES_URL, RegisteredWorkspace,
};
use gino_core::planner::{
    ApplyPlan, InstallMode, PendingChange, PendingChanges, PlanAction, Planner, Preset, PresetMode,
};
use gino_core::platform;
use gino_core::protocol::{LockScope, SkillSource, collect_skill_files};
use gino_core::source::SourceCache;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Section {
    Library,
    Marketplace,
    Global,
    Projects,
    Agents,
    CustomWorkspaces,
    Duplicates,
    Presets,
    Backup,
    Activity,
    Settings,
    Pending,
}

impl Section {
    pub const SIDEBAR: &[Self] = &[
        Self::Library,
        Self::Marketplace,
        Self::Global,
        Self::Projects,
        Self::Agents,
        Self::CustomWorkspaces,
        Self::Duplicates,
        Self::Presets,
        Self::Backup,
        Self::Activity,
        Self::Settings,
    ];

    pub fn label(self) -> &'static str {
        match self {
            Self::Library => "Library",
            Self::Marketplace => "Marketplace",
            Self::Global => "Global",
            Self::Projects => "Projects",
            Self::Agents => "Agents",
            Self::CustomWorkspaces => "Custom Workspaces",
            Self::Duplicates => "Duplicates",
            Self::Presets => "Presets",
            Self::Backup => "Backup",
            Self::Activity => "Activity",
            Self::Settings => "Settings",
            Self::Pending => "Pending Changes",
        }
    }

    pub fn from_digit(digit: &str) -> Option<Self> {
        Some(match digit {
            "1" => Self::Library,
            "2" => Self::Marketplace,
            "3" => Self::Global,
            "4" => Self::Projects,
            "5" => Self::Agents,
            "6" => Self::CustomWorkspaces,
            "7" => Self::Duplicates,
            "8" => Self::Presets,
            "9" => Self::Backup,
            "0" => Self::Activity,
            _ => return None,
        })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PreviewTab {
    SkillMd,
    Readme,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TagFilter {
    All,
    Untagged,
    Tag(String),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SyncChoice {
    KeepLocal,
    UseRemote,
    KeepBoth,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum QuitDecision {
    Exit,
    Prompt,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum KeyEffect {
    Ignored,
    Handled,
    PromptQuit,
    Quit,
    ShowHelp,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BusyOp {
    Refresh,
    Search,
    Apply,
    Remote,
    Discover,
    Folder,
}

impl BusyOp {
    pub fn label(self) -> &'static str {
        match self {
            Self::Refresh => "Refreshing inventory…",
            Self::Search => "Searching skills.sh…",
            Self::Apply => "Applying selected changes…",
            Self::Remote => "Checking remote backup…",
            Self::Discover => "Resolving Skill source…",
            Self::Folder => "Waiting for folder picker…",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TargetMenu {
    None,
    Move,
    Copy,
    Install,
}

#[derive(Clone, Debug)]
pub struct DetailPreview {
    pub path: PathBuf,
    pub skill_md: String,
    pub readme: Option<String>,
    pub files: Vec<String>,
}

pub struct ApplyJob {
    plan: ApplyPlan,
    selected_ids: Vec<u64>,
    snapshot_root: PathBuf,
    snapshot_retention: usize,
    backup: GitRepository,
    push_mode: PushMode,
    workspaces: Vec<Workspace>,
    metadata_path: Option<PathBuf>,
    generation: u64,
}

pub struct ApplyJobOutcome {
    selected_ids: Vec<u64>,
    result: std::result::Result<ApplyResult, String>,
    inventory: Option<Inventory>,
}

impl ApplyJob {
    pub fn run(self) -> ApplyJobOutcome {
        let selected_ids = self.selected_ids.clone();
        let generation = self.generation;
        let workspaces = self.workspaces.clone();
        match self.execute() {
            Ok(result) => {
                let inventory = InventoryScanner::new(&workspaces)
                    .scan(generation.saturating_add(1))
                    .ok();
                ApplyJobOutcome {
                    selected_ids,
                    result: Ok(result),
                    inventory,
                }
            }
            Err(error) => ApplyJobOutcome {
                selected_ids,
                result: Err(error),
                inventory: None,
            },
        }
    }

    fn execute(&self) -> std::result::Result<ApplyResult, String> {
        let metadata = self
            .metadata_path
            .as_ref()
            .and_then(|path| MetadataStore::open(path).ok());
        let mut executor = ApplyExecutor::new(self.snapshot_root.clone(), self.snapshot_retention)
            .with_git(self.backup.clone(), self.push_mode)
            .with_workspaces(self.workspaces.clone());
        if let Some(store) = metadata {
            if let Ok(backup_metadata) = store.backup_metadata() {
                executor = executor.with_backup_metadata(backup_metadata);
            }
            executor = executor.with_metadata(store);
        }
        executor
            .apply(&self.plan)
            .map_err(|error| error.to_string())
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SnapshotInfo {
    pub id: String,
    pub created_at: String,
    pub entry_count: usize,
}

/// Expand a stored bookmark into the scan roots the UI should register.
pub fn expand_registered_workspace(registered: RegisteredWorkspace) -> Vec<Workspace> {
    let mut workspace = Workspace::new(
        registered.id.clone(),
        registered.display_name.clone(),
        registered.kind.clone(),
        &registered.path,
    );
    let mut extras = Vec::new();
    if registered.kind == WorkspaceKind::Project {
        for candidate in [
            gino_core::protocol::project_lock_path(&registered.path),
            registered.path.join(".agents/.skill-lock.json"),
            registered.path.join(".skill-lock.json"),
        ] {
            if candidate.is_file() {
                workspace = workspace.with_lock(candidate, LockScope::Project);
                break;
            }
        }
        let home = AgentRegistry::default().home().to_path_buf();
        for (agent, root) in AgentRegistry::from_home(&home).project_skill_roots(&registered.path) {
            if root == workspace.root {
                continue;
            }
            let mut agent_ws = Workspace::new(
                format!("{}:{}", registered.id, agent.id.0),
                format!("{} / {}", registered.display_name, agent.display_name),
                WorkspaceKind::Agent,
                root,
            )
            .with_agent(agent.id.clone());
            if let Some(lock) = &workspace.lock {
                agent_ws = agent_ws.with_lock(&lock.path, lock.scope);
            }
            extras.push(agent_ws);
        }
    }
    let mut out = vec![workspace];
    out.extend(extras);
    out
}

pub struct Session {
    pub workspaces: Vec<Workspace>,
    pub inventory: Inventory,
    pub active_section: Section,
    pub selected_paths: BTreeSet<PathBuf>,
    pub selected_detail: Option<PathBuf>,
    pub selection_anchor: Option<PathBuf>,
    pub pending: PendingChanges,
    pub pending_selected: BTreeSet<u64>,
    pub refresh_error: Option<String>,
    pub action_error: Option<String>,
    pub backup: Option<GitRepository>,
    pub backup_error: Option<String>,
    pub metadata_path: Option<PathBuf>,
    pub preferences: Preferences,
    pub marketplace_query: String,
    pub marketplace_results: Vec<MarketplaceSkill>,
    pub marketplace_selected: BTreeSet<usize>,
    pub marketplace_source: String,
    pub install_target_id: String,
    pub status: String,
    pub quit_offered: bool,
    pub sync_proposal: Option<SyncProposal>,
    pub focused_sync_index: Option<usize>,
    pub tag_filter: TagFilter,
    pub preview_tab: PreviewTab,
    pub preset_mode: PresetMode,
    pub target_menu: TargetMenu,
    tag_index: BTreeMap<String, BTreeSet<String>>,
    all_tags_cache: BTreeSet<String>,
    ignored_duplicates: BTreeSet<(String, String)>,
    presets_cache: Vec<Preset>,
    activity_cache: Vec<ActivityRecord>,
    snapshots_cache: Vec<SnapshotInfo>,
    commits_cache: Vec<CommitInfo>,
    last_commit_cache: Option<CommitInfo>,
    detail_preview: Option<DetailPreview>,
}

impl Session {
    pub fn new(
        workspaces: Vec<Workspace>,
        inventory: Inventory,
        backup: gino_core::Result<GitRepository>,
        metadata_path: PathBuf,
        preferences: Preferences,
    ) -> Self {
        let (backup, backup_error) = match backup {
            Ok(repository) => (Some(repository), None),
            Err(error) => (None, Some(error.to_string())),
        };
        let mut session = Self {
            workspaces,
            inventory,
            active_section: Section::Library,
            selected_paths: BTreeSet::new(),
            selected_detail: None,
            selection_anchor: None,
            pending: PendingChanges::default(),
            pending_selected: BTreeSet::new(),
            refresh_error: None,
            action_error: None,
            backup,
            backup_error,
            metadata_path: Some(metadata_path),
            preferences,
            marketplace_query: String::new(),
            marketplace_results: Vec::new(),
            marketplace_selected: BTreeSet::new(),
            marketplace_source: String::new(),
            install_target_id: "global".to_owned(),
            status: format!("Gino {APP_VERSION}"),
            quit_offered: false,
            sync_proposal: None,
            focused_sync_index: None,
            tag_filter: TagFilter::All,
            preview_tab: PreviewTab::SkillMd,
            preset_mode: PresetMode::AddMissing,
            target_menu: TargetMenu::None,
            tag_index: BTreeMap::new(),
            all_tags_cache: BTreeSet::new(),
            ignored_duplicates: BTreeSet::new(),
            presets_cache: Vec::new(),
            activity_cache: Vec::new(),
            snapshots_cache: Vec::new(),
            commits_cache: Vec::new(),
            last_commit_cache: None,
            detail_preview: None,
        };
        session.reload_caches();
        session
    }

    pub fn reload_caches(&mut self) {
        if let Some(store) = self.store() {
            self.tag_index = store
                .backup_metadata()
                .map(|metadata| metadata.tags)
                .unwrap_or_default();
            self.ignored_duplicates = store.ignored_duplicates().unwrap_or_default();
            self.presets_cache = store.presets().unwrap_or_default();
            self.activity_cache = store.activity().unwrap_or_default();
        } else {
            self.tag_index.clear();
            self.ignored_duplicates.clear();
            self.presets_cache.clear();
            self.activity_cache.clear();
        }
        self.all_tags_cache = self.tag_index.values().flatten().cloned().collect();
        self.snapshots_cache = read_snapshots(&self.preferences.snapshot_root);
        self.commits_cache = self
            .backup
            .as_ref()
            .and_then(|repository| repository.log(20).ok())
            .unwrap_or_default();
        self.last_commit_cache = self.commits_cache.first().cloned();
        self.warm_detail_preview();
    }

    pub fn toggle_target_menu(&mut self, menu: TargetMenu) {
        self.target_menu = if self.target_menu == menu {
            TargetMenu::None
        } else {
            menu
        };
    }

    pub fn close_target_menu(&mut self) {
        self.target_menu = TargetMenu::None;
    }

    pub fn issue_summaries(&self) -> Vec<String> {
        self.inventory
            .issues
            .iter()
            .map(|issue| format!("{}: {}", issue.path.display(), issue.reason))
            .collect()
    }

    pub fn has_broken_symlinks(&self) -> bool {
        self.inventory
            .placements
            .iter()
            .any(|placement| placement.placement_kind == PlacementKind::BrokenSymlink)
    }

    pub fn theme_label(&self) -> &'static str {
        match self.preferences.theme.as_str() {
            "dark" => "Dark",
            "system" => "System",
            _ => "Light",
        }
    }

    pub fn text_size_label(&self) -> &'static str {
        match self.preferences.text_size.as_str() {
            "small" => "Small",
            "large" => "Large",
            _ => "Medium",
        }
    }

    pub fn push_mode_label(&self) -> &'static str {
        if self.preferences.commit_locally() {
            "Commit locally"
        } else {
            "Commit and push"
        }
    }

    pub fn language_label(&self) -> String {
        match self.preferences.language.as_str() {
            "en" | "" => "English".to_owned(),
            other => format!("{other} (English UI in 1.0)"),
        }
    }

    pub fn credential_status(&self) -> &'static str {
        #[cfg(target_os = "macos")]
        {
            "Tokens stay in the macOS Keychain. They never enter settings, logs, or backup."
        }
        #[cfg(target_os = "windows")]
        {
            "Tokens stay in Windows Credential Manager. They never enter settings, logs, or backup."
        }
        #[cfg(not(any(target_os = "macos", target_os = "windows")))]
        {
            "Tokens stay in the OS secret store (secret-tool). They never enter settings, logs, or backup."
        }
    }

    pub fn cached_snapshots(&self) -> &[SnapshotInfo] {
        &self.snapshots_cache
    }

    pub fn cached_commits(&self) -> &[CommitInfo] {
        &self.commits_cache
    }

    pub fn cached_last_commit(&self) -> Option<&CommitInfo> {
        self.last_commit_cache.as_ref()
    }

    pub fn detail_preview(&self) -> Option<&DetailPreview> {
        self.detail_preview.as_ref()
    }

    pub fn warm_detail_preview(&mut self) {
        let Some(path) = self.selected_detail.clone() else {
            self.detail_preview = None;
            return;
        };
        if self
            .detail_preview
            .as_ref()
            .is_some_and(|preview| preview.path == path)
        {
            return;
        }
        self.detail_preview = Some(DetailPreview {
            path: path.clone(),
            skill_md: read_preview(&path, "SKILL.md").unwrap_or_default(),
            readme: read_preview(&path, "README.md"),
            files: file_tree(&path),
        });
    }

    pub fn store(&self) -> Option<MetadataStore> {
        self.metadata_path
            .as_ref()
            .and_then(|path| MetadataStore::open(path).ok())
    }

    pub fn push_mode(&self) -> PushMode {
        if self.preferences.commit_locally() {
            PushMode::CommitLocally
        } else {
            PushMode::CommitAndPush
        }
    }

    pub fn declared_roots(&self) -> Vec<PathBuf> {
        self.workspaces
            .iter()
            .flat_map(|workspace| {
                let lock_root = workspace
                    .lock
                    .as_ref()
                    .and_then(|lock| lock.path.parent())
                    .map(Path::to_path_buf);
                std::iter::once(workspace.root.clone()).chain(lock_root)
            })
            .collect()
    }

    pub fn refresh(&mut self) {
        let result = InventoryScanner::new(&self.workspaces)
            .scan(self.inventory.generation.saturating_add(1));
        self.apply_scan_result(result);
    }

    pub fn apply_scan_result(&mut self, result: gino_core::Result<Inventory>) {
        match result {
            Ok(inventory) => {
                self.inventory = inventory;
                self.refresh_error = None;
                self.selected_paths.retain(|path| {
                    self.inventory
                        .placements
                        .iter()
                        .any(|placement| &placement.path == path)
                });
                if self.selected_detail.as_ref().is_some_and(|path| {
                    !self
                        .inventory
                        .placements
                        .iter()
                        .any(|placement| &placement.path == path)
                }) {
                    self.selected_detail = None;
                    self.detail_preview = None;
                }
                self.pending.mark_unavailable();
                self.status = "Refresh complete".to_owned();
            }
            Err(error) => self.refresh_error = Some(error.to_string()),
        }
        self.reload_caches();
    }

    pub fn visible_placements(&self) -> Vec<&SkillPlacement> {
        let duplicate_indexes = self
            .inventory
            .duplicate_groups
            .iter()
            .filter(|group| !self.duplicate_is_ignored(group))
            .flat_map(|group| group.placement_indexes.iter().copied())
            .collect::<BTreeSet<_>>();
        self.inventory
            .placements
            .iter()
            .enumerate()
            .filter(|(index, placement)| {
                let in_section = match self.active_section {
                    Section::Global => placement.workspace_kind == WorkspaceKind::Global,
                    Section::Projects => placement.workspace_kind == WorkspaceKind::Project,
                    Section::Agents => placement.workspace_kind == WorkspaceKind::Agent,
                    Section::CustomWorkspaces => placement.workspace_kind == WorkspaceKind::Custom,
                    Section::Duplicates => duplicate_indexes.contains(index),
                    Section::Library => true,
                    _ => false,
                };
                in_section && self.matches_tag_filter(placement)
            })
            .map(|(_, placement)| placement)
            .collect()
    }

    fn matches_tag_filter(&self, placement: &SkillPlacement) -> bool {
        match &self.tag_filter {
            TagFilter::All => true,
            TagFilter::Untagged => self.tags_for(&placement.name).is_empty(),
            TagFilter::Tag(tag) => self.tags_for(&placement.name).contains(tag),
        }
    }

    pub fn selected_placement(&self) -> Option<&SkillPlacement> {
        let path = self.selected_detail.as_ref()?;
        self.inventory
            .placements
            .iter()
            .find(|placement| &placement.path == path)
    }

    pub fn click_placement(&mut self, path: PathBuf, shift: bool) {
        if shift {
            self.select_range_to(&path);
        } else {
            self.toggle_selected(&path);
            self.selection_anchor = Some(path.clone());
        }
        self.selected_detail = Some(path);
        self.warm_detail_preview();
    }

    pub fn toggle_selected(&mut self, path: &PathBuf) {
        if !self.selected_paths.insert(path.clone()) {
            self.selected_paths.remove(path);
        }
    }

    fn select_range_to(&mut self, path: &Path) {
        let visible = self
            .visible_placements()
            .into_iter()
            .map(|placement| placement.path.clone())
            .collect::<Vec<_>>();
        let target = visible.iter().position(|candidate| candidate == path);
        let anchor = self
            .selection_anchor
            .as_ref()
            .and_then(|anchor| visible.iter().position(|candidate| candidate == anchor));
        if let (Some(start), Some(end)) = (anchor, target) {
            let (low, high) = if start <= end {
                (start, end)
            } else {
                (end, start)
            };
            for candidate in &visible[low..=high] {
                self.selected_paths.insert(candidate.clone());
            }
        } else {
            self.selected_paths.insert(path.to_path_buf());
            self.selection_anchor = Some(path.to_path_buf());
        }
    }

    pub fn select_visible(&mut self) {
        let paths = self
            .visible_placements()
            .into_iter()
            .map(|placement| placement.path.clone())
            .collect::<Vec<_>>();
        self.selected_paths.extend(paths);
    }

    pub fn clear_selection(&mut self) {
        self.selected_paths.clear();
    }

    pub fn move_detail(&mut self, delta: isize) {
        let visible = self
            .visible_placements()
            .into_iter()
            .map(|placement| placement.path.clone())
            .collect::<Vec<_>>();
        if visible.is_empty() {
            return;
        }
        let current = self
            .selected_detail
            .as_ref()
            .and_then(|path| visible.iter().position(|candidate| candidate == path))
            .unwrap_or(0);
        let next = (current as isize + delta).clamp(0, visible.len() as isize - 1) as usize;
        self.selected_detail = Some(visible[next].clone());
        self.warm_detail_preview();
    }

    pub fn queue_remove_selected(&mut self) {
        let placements = self
            .inventory
            .placements
            .iter()
            .filter(|placement| self.selected_paths.contains(&placement.path))
            .cloned()
            .collect::<Vec<_>>();
        if placements.is_empty() {
            return;
        }
        let refs = placements.iter().collect::<Vec<_>>();
        match Planner::new(&self.inventory, self.declared_roots()).remove(&refs) {
            Ok(plan) => {
                self.enqueue_plan(plan);
                self.selected_paths.clear();
            }
            Err(error) => self.action_error = Some(error.to_string()),
        }
    }

    /// Queue removal of every broken symlink found across all workspaces.
    /// Produces a single Apply plan (snapshot + git backup) that the user
    /// reviews before anything is written.
    pub fn queue_cleanup_broken_symlinks(&mut self) {
        let broken_count = self
            .inventory
            .placements
            .iter()
            .filter(|placement| placement.placement_kind == PlacementKind::BrokenSymlink)
            .count();
        if broken_count == 0 {
            self.action_error = Some("No broken symlinks found".to_owned());
            return;
        }
        match Planner::new(&self.inventory, self.declared_roots()).cleanup_broken_symlinks() {
            Ok(plan) => {
                self.enqueue_plan(plan);
            }
            Err(error) => self.action_error = Some(error.to_string()),
        }
    }

    pub fn queue_move_to(&mut self, workspace_id: &str) {
        let Some(target) = self
            .workspaces
            .iter()
            .find(|workspace| workspace.id == workspace_id)
            .cloned()
        else {
            self.action_error = Some("Target workspace is not registered".to_owned());
            return;
        };
        let placements = self
            .inventory
            .placements
            .iter()
            .filter(|placement| self.selected_paths.contains(&placement.path))
            .cloned()
            .collect::<Vec<_>>();
        let planner = Planner::new(&self.inventory, self.declared_roots());
        let mut plans = Vec::new();
        for placement in &placements {
            if placement.workspace_id == target.id {
                continue;
            }
            let destination = target.root.join(&placement.name);
            match planner.move_placement_with_lock(
                placement,
                destination,
                InstallMode::Copy,
                target.lock.as_ref(),
            ) {
                Ok(plan) => plans.push(plan),
                Err(error) => self.action_error = Some(error.to_string()),
            }
        }
        drop(planner);
        for plan in plans {
            self.enqueue_plan(plan);
        }
        self.selected_paths.clear();
    }

    pub fn queue_copy_to(&mut self, workspace_id: &str) {
        let Some(target) = self
            .workspaces
            .iter()
            .find(|workspace| workspace.id == workspace_id)
            .cloned()
        else {
            self.action_error = Some("Target workspace is not registered".to_owned());
            return;
        };
        let placements = self
            .inventory
            .placements
            .iter()
            .filter(|placement| self.selected_paths.contains(&placement.path))
            .cloned()
            .collect::<Vec<_>>();
        let planner = Planner::new(&self.inventory, self.declared_roots());
        let mut plans = Vec::new();
        for placement in &placements {
            let destination = target.root.join(&placement.name);
            match planner.copy(placement, destination) {
                Ok(plan) => plans.push(plan),
                Err(error) => self.action_error = Some(error.to_string()),
            }
        }
        drop(planner);
        for plan in plans {
            self.enqueue_plan(plan);
        }
    }

    pub fn queue_attach_source(&mut self, source_input: &str) {
        let Some(placement) = self.selected_placement().cloned() else {
            self.action_error = Some("Select an Untracked Skill first".to_owned());
            return;
        };
        let source = match SkillSource::parse(source_input) {
            Ok(source) => source,
            Err(error) => {
                self.action_error = Some(error.to_string());
                return;
            }
        };
        let discovered = match self.source_cache().discover(&source, false) {
            Ok(discovered) => discovered,
            Err(error) => {
                self.action_error = Some(error.to_string());
                return;
            }
        };
        let Some(skill) = discovered
            .skills
            .iter()
            .find(|skill| skill.metadata.name == placement.name)
            .or_else(|| discovered.skills.first())
        else {
            self.action_error = Some("Source did not discover a Skill".to_owned());
            return;
        };
        let lock = placement
            .lock_file
            .as_deref()
            .zip(placement.lock_scope)
            .or_else(|| {
                self.workspaces
                    .iter()
                    .find(|workspace| workspace.kind == WorkspaceKind::Global)
                    .and_then(|workspace| {
                        workspace
                            .lock
                            .as_ref()
                            .map(|lock| (lock.path.as_path(), lock.scope))
                    })
            });
        let Some((lock_path, scope)) = lock else {
            self.action_error =
                Some("No compatible lockfile is available for Attach Source".to_owned());
            return;
        };
        match Planner::new(&self.inventory, self.declared_roots()).attach_source(
            &placement,
            &source,
            &skill.path,
            (lock_path, scope),
        ) {
            Ok(plan) => self.enqueue_plan(plan),
            Err(error) => self.action_error = Some(error.to_string()),
        }
    }

    pub fn enqueue_plan(&mut self, plan: ApplyPlan) {
        if !plan.blockers.is_empty() {
            self.action_error = Some(plan.blockers.join("; "));
        } else {
            self.action_error = None;
        }
        let count = plan.operation_count();
        let ids = self.pending.add_plan(&plan);
        self.pending_selected.extend(ids);
        self.status = format!("Queued {count} change(s); nothing written until Apply");
    }

    pub fn toggle_pending(&mut self, id: u64) {
        let siblings = self.pending.sibling_ids(id);
        let all_on = siblings
            .iter()
            .all(|sibling| self.pending_selected.contains(sibling));
        if all_on {
            for sibling in siblings {
                self.pending_selected.remove(&sibling);
            }
        } else {
            self.pending_selected.extend(siblings);
        }
    }

    pub fn drop_pending(&mut self, id: u64) {
        for sibling in self.pending.sibling_ids(id) {
            self.pending_selected.remove(&sibling);
        }
        self.pending.remove(id);
        self.status = "Removed a pending plan".to_owned();
    }

    pub fn selected_pending_count(&self) -> usize {
        self.pending
            .items()
            .iter()
            .filter(|item| self.pending_selected.contains(&item.id))
            .count()
    }

    pub fn apply_label(&self) -> String {
        let count = self.selected_pending_count();
        match count {
            1 => "Apply 1 change".to_owned(),
            _ => format!("Apply {count} changes"),
        }
    }

    pub fn apply_plan(&self) -> ApplyPlan {
        let mut pending = self.pending.clone();
        let unselected = pending
            .items()
            .into_iter()
            .filter(|item| !self.pending_selected.contains(&item.id))
            .map(|item| item.id)
            .collect::<Vec<_>>();
        for id in unselected {
            pending.remove(id);
        }
        pending.plan(self.inventory.generation, self.declared_roots())
    }

    pub fn can_apply(&self) -> bool {
        self.apply_block_reason().is_none()
    }

    pub fn apply_block_reason(&self) -> Option<String> {
        if self.selected_pending_count() == 0 {
            return Some("Select at least one pending change to apply".to_owned());
        }
        if self
            .pending
            .items()
            .iter()
            .any(|item| self.pending_selected.contains(&item.id) && !item.available())
        {
            return Some(
                "Deselect or remove Unavailable items before Apply (Missing after refresh)"
                    .to_owned(),
            );
        }
        if self.backup.is_none() {
            return self
                .backup_error
                .clone()
                .or_else(|| Some("Git backup is unavailable; Apply is disabled".to_owned()));
        }
        let plan = self.apply_plan();
        if let Err(error) = plan.validate() {
            return Some(error.to_string());
        }
        if !plan.can_apply() {
            return Some(
                plan.blockers
                    .first()
                    .cloned()
                    .unwrap_or_else(|| "Plan cannot be applied".to_owned()),
            );
        }
        None
    }

    pub fn apply_job(&self) -> std::result::Result<ApplyJob, String> {
        if let Some(reason) = self.apply_block_reason() {
            return Err(reason);
        }
        let repository = self
            .backup
            .clone()
            .ok_or_else(|| "Git backup is unavailable; Apply is disabled".to_owned())?;
        Ok(ApplyJob {
            plan: self.apply_plan(),
            selected_ids: self
                .pending
                .items()
                .into_iter()
                .filter(|item| self.pending_selected.contains(&item.id))
                .map(|item| item.id)
                .collect(),
            snapshot_root: self.preferences.snapshot_root.clone(),
            snapshot_retention: self.preferences.snapshot_retention,
            backup: repository,
            push_mode: self.push_mode(),
            workspaces: self.workspaces.clone(),
            metadata_path: self.metadata_path.clone(),
            generation: self.inventory.generation,
        })
    }

    pub fn complete_apply(&mut self, outcome: ApplyJobOutcome) -> bool {
        match outcome.result {
            Ok(result) => {
                for id in outcome.selected_ids {
                    self.pending.remove(id);
                    self.pending_selected.remove(&id);
                }
                self.pending_selected
                    .retain(|id| self.pending.items().iter().any(|item| item.id == *id));
                self.action_error = None;
                let status = match result.push_status {
                    PushStatus::NotPushed(reason) => format!("Applied; not pushed: {reason}"),
                    PushStatus::Pushed => "Applied and pushed".to_owned(),
                    _ => "Applied".to_owned(),
                };
                if let Some(inventory) = outcome.inventory {
                    self.apply_scan_result(Ok(inventory));
                } else {
                    self.refresh();
                }
                self.status = status;
                true
            }
            Err(error) => {
                self.action_error = Some(error);
                false
            }
        }
    }

    pub fn apply_pending(&mut self) -> bool {
        match self.apply_job() {
            Ok(job) => self.complete_apply(job.run()),
            Err(reason) => {
                self.action_error = Some(reason);
                false
            }
        }
    }

    pub fn register_folder_path(&mut self, kind: WorkspaceKind, path: PathBuf) {
        if !path.is_dir() {
            self.action_error = Some(format!("Selected path is not a folder: {}", path.display()));
            return;
        }
        let prefix = match kind {
            WorkspaceKind::Project => "project",
            WorkspaceKind::Custom => "custom",
            _ => "ws",
        };
        let id = format!("{prefix}:{}", path.display());
        let display = path
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| path.display().to_string());
        let registered = RegisteredWorkspace {
            id,
            display_name: display,
            kind,
            path,
            preferred_mode: InstallMode::Copy,
        };
        if let Some(store) = self.store() {
            if let Err(error) = store.save_workspace(&registered) {
                self.action_error = Some(error.to_string());
                return;
            }
        }
        for workspace in expand_registered_workspace(registered) {
            if !self
                .workspaces
                .iter()
                .any(|existing| existing.id == workspace.id)
            {
                self.workspaces.push(workspace);
            }
        }
        self.action_error = None;
        self.refresh();
        self.status = "Folder registered (bookmark only)".to_owned();
    }

    pub fn remove_bookmark(&mut self, id: &str) {
        let Some(workspace) = self
            .workspaces
            .iter()
            .find(|workspace| workspace.id == id)
            .cloned()
        else {
            return;
        };
        if self.plan_references(&workspace) {
            self.action_error = Some(
                "Remove corresponding Pending Changes before removing this bookmark".to_owned(),
            );
            return;
        }
        if let Some(store) = self.store() {
            let _ = store.remove_workspace(id);
        }
        let prefix = format!("{id}:");
        self.workspaces
            .retain(|workspace| workspace.id != id && !workspace.id.starts_with(&prefix));
        self.action_error = None;
        self.refresh();
        self.status = "Bookmark removed; files were not deleted".to_owned();
    }

    fn plan_references(&self, workspace: &Workspace) -> bool {
        self.pending.items().iter().any(|item| {
            path_under(&item.destination, &workspace.root)
                || item
                    .source
                    .as_ref()
                    .is_some_and(|source| path_under(source, &workspace.root))
        })
    }

    pub fn bookmarks(&self, kind: WorkspaceKind) -> Vec<RegisteredWorkspace> {
        self.store()
            .and_then(|store| store.workspaces().ok())
            .unwrap_or_default()
            .into_iter()
            .filter(|workspace| workspace.kind == kind)
            .collect()
    }

    #[cfg_attr(not(test), allow(dead_code))]
    pub fn search_marketplace(&mut self) {
        if self.marketplace_query.trim().len() < 2 {
            self.action_error = Some("Type at least 2 characters to search skills.sh".to_owned());
            return;
        }
        match marketplace::search_skills(
            &self.marketplace_query,
            marketplace::DEFAULT_MARKETPLACE_URL,
            (!self.preferences.proxy.is_empty()).then_some(self.preferences.proxy.as_str()),
        ) {
            Ok(results) => {
                self.marketplace_results = results;
                self.marketplace_selected.clear();
                self.action_error = None;
                self.status = format!("{} marketplace results", self.marketplace_results.len());
            }
            Err(error) => self.action_error = Some(error.to_string()),
        }
    }

    pub fn toggle_marketplace(&mut self, index: usize) {
        if !self.marketplace_selected.insert(index) {
            self.marketplace_selected.remove(&index);
        }
    }

    #[cfg_attr(not(test), allow(dead_code))]
    pub fn queue_selected_marketplace(&mut self) {
        let selected = self
            .marketplace_selected
            .iter()
            .filter_map(|index| self.marketplace_results.get(*index).cloned())
            .collect::<Vec<_>>();
        if selected.is_empty() {
            self.action_error = Some("Select one or more marketplace Skills".to_owned());
            return;
        }
        for skill in selected {
            let source = if skill.source.is_empty() {
                skill.id.clone()
            } else {
                skill.source.clone()
            };
            self.queue_install_source(&source, Some(&skill.name));
        }
    }

    pub fn discover_source_input(
        source_input: &str,
    ) -> std::result::Result<(SkillSource, DiscoveryResult), String> {
        let source = SkillSource::parse(source_input).map_err(|error| error.to_string())?;
        let home = AgentRegistry::default().home().to_path_buf();
        let discovered = SourceCache::new(home.join(".gino/source-cache"))
            .discover(&source, false)
            .map_err(|error| error.to_string())?;
        Ok((source, discovered))
    }

    pub fn queue_discovered_install(
        &mut self,
        source: SkillSource,
        discovered: DiscoveryResult,
        skill_hint: Option<&str>,
    ) {
        let Some(target) = self.install_target() else {
            self.action_error = Some("No install target workspace is available".to_owned());
            return;
        };
        let planner = Planner::new(&self.inventory, self.declared_roots());
        let mut queued = 0;
        let mut plans = Vec::new();
        for skill in discovered.skills {
            if skill_hint.is_some_and(|hint| skill.metadata.name != hint) {
                continue;
            }
            let destination = target.root.join(&skill.metadata.name);
            let lock = target
                .lock
                .as_ref()
                .map(|lock| (lock.path.as_path(), lock.scope));
            match planner.install_source(&source, skill.path, destination, InstallMode::Copy, lock)
            {
                Ok(plan) => {
                    queued += 1;
                    plans.push(plan);
                }
                Err(error) => self.action_error = Some(error.to_string()),
            }
        }
        drop(planner);
        for plan in plans {
            self.enqueue_plan(plan);
        }
        if queued > 0 {
            self.status = format!("Queued {queued} installs (no files written)");
        }
    }

    pub fn queue_install_source(&mut self, source_input: &str, skill_hint: Option<&str>) {
        match Self::discover_source_input(source_input) {
            Ok((source, discovered)) => {
                self.queue_discovered_install(source, discovered, skill_hint)
            }
            Err(error) => self.action_error = Some(error),
        }
    }

    fn install_target(&self) -> Option<Workspace> {
        self.workspaces
            .iter()
            .find(|workspace| workspace.id == self.install_target_id)
            .cloned()
            .or_else(|| {
                self.workspaces
                    .iter()
                    .find(|workspace| workspace.kind == WorkspaceKind::Global)
                    .cloned()
            })
            .or_else(|| self.workspaces.first().cloned())
    }

    fn source_cache(&self) -> SourceCache {
        let home = AgentRegistry::default().home().to_path_buf();
        SourceCache::new(home.join(".gino/source-cache"))
    }

    pub fn keep_duplicate(&mut self, group_index: usize, keep_placement_index: usize) {
        let Some(group) = self.inventory.duplicate_groups.get(group_index).cloned() else {
            return;
        };
        match Planner::new(&self.inventory, self.declared_roots())
            .resolve_duplicate_group(&group, keep_placement_index)
        {
            Ok(plan) => self.enqueue_plan(plan),
            Err(error) => self.action_error = Some(error.to_string()),
        }
    }

    pub fn ignore_duplicate(&mut self, group_index: usize) {
        let Some(group) = self.inventory.duplicate_groups.get(group_index) else {
            return;
        };
        let skill_name = group.skill_name.clone();
        let fingerprint = group.fingerprint.clone();
        if let Some(store) = self.store() {
            if let Err(error) = store.ignore_duplicate(&skill_name, &fingerprint, "ignored") {
                self.action_error = Some(error.to_string());
                return;
            }
        }
        self.reload_caches();
        self.status = format!("Ignored duplicate group {skill_name}");
    }

    pub fn visible_duplicate_groups(&self) -> Vec<(usize, &DuplicateGroup)> {
        self.inventory
            .duplicate_groups
            .iter()
            .enumerate()
            .filter(|(_, group)| !self.duplicate_is_ignored(group))
            .collect()
    }

    fn duplicate_is_ignored(&self, group: &DuplicateGroup) -> bool {
        self.ignored_duplicates
            .contains(&(group.skill_name.clone(), group.fingerprint.clone()))
    }

    pub fn duplicate_class_for(&self, path: &Path) -> Option<DuplicateClass> {
        let index = self
            .inventory
            .placements
            .iter()
            .position(|placement| placement.path == path)?;
        self.inventory
            .duplicate_groups
            .iter()
            .find(|group| {
                group.placement_indexes.contains(&index) && !self.duplicate_is_ignored(group)
            })
            .map(|group| group.class.clone())
    }

    #[cfg_attr(not(test), allow(dead_code))]
    pub fn check_remote(&mut self) {
        let Some(repository) = &self.backup else {
            self.action_error = Some("Backup repository is unavailable".to_owned());
            return;
        };
        match repository
            .fetch()
            .and_then(|_| repository.propose_sync(&self.inventory))
        {
            Ok(proposal) => {
                let count = proposal
                    .changes
                    .iter()
                    .filter(|change| change.status != RemoteChangeStatus::Unchanged)
                    .count();
                let short = &proposal.remote_commit[..7.min(proposal.remote_commit.len())];
                self.status = format!("Remote {short}: {count} changes (nothing written)");
                self.sync_proposal = Some(proposal);
                self.focused_sync_index = None;
                self.action_error = None;
                self.reload_caches();
            }
            Err(error) => self.action_error = Some(error.to_string()),
        }
    }

    pub fn resolve_focused_sync(&mut self, choice: SyncChoice) {
        let Some(index) = self.focused_sync_index else {
            return;
        };
        self.resolve_sync(index, choice);
    }

    pub fn resolve_sync(&mut self, index: usize, choice: SyncChoice) {
        let Some(proposal) = self.sync_proposal.clone() else {
            self.action_error = Some("Check Remote first".to_owned());
            return;
        };
        let Some(change) = proposal.changes.get(index).cloned() else {
            return;
        };
        match (change.status, choice) {
            (_, SyncChoice::KeepLocal) | (RemoteChangeStatus::Unchanged, _) => {
                self.status = format!("Kept local {}", change.skill_name);
            }
            (RemoteChangeStatus::Removed, SyncChoice::UseRemote) => {
                self.queue_remove_remote_gone(&change);
            }
            (RemoteChangeStatus::Removed, SyncChoice::KeepBoth) => {
                self.status = format!("Kept local-only {}", change.skill_name);
            }
            (_, SyncChoice::KeepBoth) => {
                self.queue_remote_restore(&change, &proposal.remote_commit, true);
            }
            (_, SyncChoice::UseRemote) => {
                self.queue_remote_restore(&change, &proposal.remote_commit, false);
            }
        }
    }

    fn queue_remove_remote_gone(&mut self, change: &RemoteSkillChange) {
        let Some(placement) = self
            .inventory
            .placements
            .iter()
            .find(|placement| {
                placement.workspace_id == change.workspace_id && placement.name == change.skill_name
            })
            .cloned()
        else {
            self.action_error = Some(format!(
                "Local placement for `{}` is already gone",
                change.skill_name
            ));
            return;
        };
        match Planner::new(&self.inventory, self.declared_roots()).remove(&[&placement]) {
            Ok(plan) => self.enqueue_plan(plan),
            Err(error) => self.action_error = Some(error.to_string()),
        }
    }

    fn queue_remote_restore(&mut self, change: &RemoteSkillChange, commit: &str, keep_both: bool) {
        let Some(repository) = self.backup.clone() else {
            self.action_error = Some("Backup repository is unavailable".to_owned());
            return;
        };
        let manifest = match repository.manifest_from_ref(commit) {
            Ok(manifest) => manifest,
            Err(error) => {
                self.action_error = Some(error.to_string());
                return;
            }
        };
        let Some(placement) = manifest.skills.get(&change.skill_name).and_then(|skill| {
            skill.placements.iter().find(|placement| {
                placement.workspace_id == change.workspace_id
                    && placement.relative_path == change.relative_path
            })
        }) else {
            self.action_error = Some(format!(
                "Remote manifest has no placement for `{}`",
                change.skill_name
            ));
            return;
        };
        let scratch = self
            .restore_scratch()
            .join(commit)
            .join(&placement.repository_path);
        if let Err(error) = fs::create_dir_all(&scratch) {
            self.action_error = Some(error.to_string());
            return;
        }
        if let Err(error) = repository.extract_tree(commit, &placement.repository_path, &scratch) {
            self.action_error = Some(error.to_string());
            return;
        }
        let Some(workspace) = self
            .workspaces
            .iter()
            .find(|workspace| workspace.id == change.workspace_id)
            .cloned()
        else {
            self.action_error = Some(format!(
                "Workspace `{}` is not registered on this device",
                change.workspace_id
            ));
            return;
        };
        let destination = workspace.root.join(&change.relative_path);
        let lock = workspace
            .lock
            .as_ref()
            .map(|lock| (lock.path.as_path(), lock.scope));
        let planner = Planner::new(&self.inventory, self.declared_roots());
        let plan = if keep_both {
            let alias = destination.with_file_name(format!("{}-remote", change.skill_name));
            planner.keep_both(&scratch, alias, lock)
        } else {
            planner.restore_from_dir(
                &scratch,
                destination,
                lock,
                None,
                format!("commit {commit}"),
            )
        };
        match plan {
            Ok(plan) => self.enqueue_plan(plan),
            Err(error) => self.action_error = Some(error.to_string()),
        }
    }

    pub fn queue_restore_snapshot(&mut self, id: &str) {
        let store = SnapshotStore::new(
            &self.preferences.snapshot_root,
            self.preferences.snapshot_retention,
        );
        match store.load(id).and_then(|snapshot| {
            Planner::new(&self.inventory, self.declared_roots()).restore_snapshot(&snapshot)
        }) {
            Ok(plan) => self.enqueue_plan(plan),
            Err(error) => self.action_error = Some(error.to_string()),
        }
    }

    pub fn queue_restore_commit(&mut self, commit_id: &str) {
        let Some(repository) = self.backup.clone() else {
            self.action_error = Some("Backup repository is unavailable".to_owned());
            return;
        };
        let manifest = match repository.manifest_from_ref(commit_id) {
            Ok(manifest) => manifest,
            Err(error) => {
                self.action_error = Some(error.to_string());
                return;
            }
        };
        let planner = Planner::new(&self.inventory, self.declared_roots());
        let mut queued = 0;
        let mut plans = Vec::new();
        for skill in manifest.skills.values() {
            for placement in &skill.placements {
                let Some(workspace) = self
                    .workspaces
                    .iter()
                    .find(|workspace| workspace.id == placement.workspace_id)
                    .cloned()
                else {
                    continue;
                };
                let scratch = self
                    .restore_scratch()
                    .join(commit_id)
                    .join(&placement.repository_path);
                if let Err(error) = fs::create_dir_all(&scratch) {
                    self.action_error = Some(error.to_string());
                    return;
                }
                if let Err(error) =
                    repository.extract_tree(commit_id, &placement.repository_path, &scratch)
                {
                    self.action_error = Some(error.to_string());
                    return;
                }
                let destination = workspace.root.join(&placement.relative_path);
                let lock = workspace
                    .lock
                    .as_ref()
                    .map(|lock| (lock.path.as_path(), lock.scope));
                match planner.restore_from_dir(
                    &scratch,
                    destination,
                    lock,
                    None,
                    format!("commit {commit_id}"),
                ) {
                    Ok(plan) => {
                        queued += 1;
                        plans.push(plan);
                    }
                    Err(error) => self.action_error = Some(error.to_string()),
                }
            }
        }
        drop(planner);
        for plan in plans {
            self.enqueue_plan(plan);
        }
        if queued == 0 {
            self.action_error =
                Some("No restoreable placements mapped to local workspaces".to_owned());
        }
    }

    fn restore_scratch(&self) -> PathBuf {
        self.preferences
            .snapshot_root
            .parent()
            .unwrap_or(Path::new("."))
            .join("restore-scratch")
    }

    #[cfg_attr(not(test), allow(dead_code))]
    pub fn list_snapshots(&self) -> Vec<SnapshotInfo> {
        self.snapshots_cache.clone()
    }

    #[cfg_attr(not(test), allow(dead_code))]
    pub fn last_commit(&self) -> Option<CommitInfo> {
        self.last_commit_cache.clone()
    }

    #[cfg_attr(not(test), allow(dead_code))]
    pub fn commit_history(&self) -> Vec<CommitInfo> {
        self.commits_cache.clone()
    }

    pub fn activity_records(&self) -> Vec<ActivityRecord> {
        self.activity_cache.clone()
    }

    pub fn presets(&self) -> Vec<Preset> {
        self.presets_cache.clone()
    }

    pub fn tags_for(&self, skill_name: &str) -> BTreeSet<String> {
        self.tag_index.get(skill_name).cloned().unwrap_or_default()
    }

    pub fn all_tags(&self) -> BTreeSet<String> {
        self.all_tags_cache.clone()
    }

    pub fn add_tag(&mut self, skill_name: &str, tag: &str) {
        let tag = tag.trim();
        if tag.is_empty() || skill_name.is_empty() {
            return;
        }
        let Some(store) = self.store() else {
            return;
        };
        let mut tags = store.tags_for(skill_name).unwrap_or_default();
        tags.insert(tag.to_owned());
        if let Err(error) = store.set_tags(skill_name, &tags) {
            self.action_error = Some(error.to_string());
            return;
        }
        self.reload_caches();
        self.status = format!("Tagged {skill_name} as {tag}");
    }

    pub fn remove_tag(&mut self, skill_name: &str, tag: &str) {
        let Some(store) = self.store() else {
            return;
        };
        let mut tags = store.tags_for(skill_name).unwrap_or_default();
        tags.remove(tag);
        if let Err(error) = store.set_tags(skill_name, &tags) {
            self.action_error = Some(error.to_string());
            return;
        }
        self.reload_caches();
        self.status = format!("Removed tag {tag} from {skill_name}");
    }

    pub fn save_preset_from_selection(&mut self, name: &str) {
        let name = name.trim();
        if name.is_empty() {
            self.action_error = Some("Preset name is required".to_owned());
            return;
        }
        let skills = self
            .inventory
            .placements
            .iter()
            .filter(|placement| self.selected_paths.contains(&placement.path))
            .map(|placement| placement.name.clone())
            .collect::<BTreeSet<_>>();
        if skills.is_empty() {
            self.action_error = Some("Select Skills in Library before saving a Preset".to_owned());
            return;
        }
        let id = name
            .to_lowercase()
            .chars()
            .map(|character| {
                if character.is_ascii_alphanumeric() {
                    character
                } else {
                    '-'
                }
            })
            .collect::<String>();
        let Some(store) = self.store() else {
            return;
        };
        if let Err(error) = store.save_preset(&Preset {
            id,
            name: name.to_owned(),
            skills,
            mode: self.preset_mode,
        }) {
            self.action_error = Some(error.to_string());
            return;
        }
        self.reload_caches();
        self.action_error = None;
        self.status = format!("Saved preset {name}");
    }

    pub fn queue_preset(&mut self, preset_id: &str, workspace_id: &str) {
        let Some(mut preset) = self
            .presets()
            .into_iter()
            .find(|preset| preset.id == preset_id)
        else {
            self.action_error = Some("Preset not found".to_owned());
            return;
        };
        preset.mode = self.preset_mode;
        let Some(target) = self
            .workspaces
            .iter()
            .find(|workspace| workspace.id == workspace_id)
            .cloned()
        else {
            self.action_error = Some("Choose a workspace to apply the Preset".to_owned());
            return;
        };
        let mut source_dirs = BTreeMap::new();
        for skill_name in &preset.skills {
            if let Some(placement) = self
                .inventory
                .placements
                .iter()
                .find(|placement| &placement.name == skill_name)
            {
                source_dirs.insert(skill_name.clone(), placement.path.clone());
            }
        }
        match Planner::new(&self.inventory, self.declared_roots()).apply_preset(
            &preset,
            &target,
            &source_dirs,
        ) {
            Ok(plan) => self.enqueue_plan(plan),
            Err(error) => self.action_error = Some(error.to_string()),
        }
    }

    pub fn save_preferences(&mut self) {
        if let Some(store) = self.store() {
            if let Err(error) = store.save_preferences(&self.preferences) {
                self.action_error = Some(error.to_string());
            }
        }
    }

    pub fn toggle_push_mode(&mut self) {
        self.preferences.push_mode = if self.preferences.commit_locally() {
            "commit_and_push".to_owned()
        } else {
            "commit_locally".to_owned()
        };
        self.save_preferences();
        self.status = format!("Push mode: {}", self.preferences.push_mode);
    }

    pub fn cycle_theme(&mut self) {
        self.preferences.theme = match self.preferences.theme.as_str() {
            "light" => "dark",
            "dark" => "system",
            _ => "light",
        }
        .to_owned();
        self.save_preferences();
    }

    pub fn cycle_text_size(&mut self) {
        self.preferences.text_size = match self.preferences.text_size.as_str() {
            "small" => "medium",
            "medium" => "large",
            _ => "small",
        }
        .to_owned();
        self.save_preferences();
    }

    pub fn about() -> (&'static str, &'static str) {
        (APP_VERSION, RELEASES_URL)
    }

    /// Open the GitHub Releases page. 1.0 has no in-app self-update.
    pub fn open_releases(&mut self) {
        match platform::open_url(RELEASES_URL) {
            Ok(()) => self.status = format!("Opened {RELEASES_URL}"),
            Err(error) => self.action_error = Some(error.to_string()),
        }
    }

    pub fn export_diagnostics(&mut self) {
        let dest = self
            .preferences
            .snapshot_root
            .parent()
            .unwrap_or(Path::new("."))
            .join("gino-diagnostics.zip");
        match platform::export_diagnostics(
            &dest,
            self.action_error.as_deref().unwrap_or(""),
            &format!("gino {APP_VERSION}"),
        ) {
            Ok(()) => self.status = format!("Wrote {}", dest.display()),
            Err(error) => self.action_error = Some(error.to_string()),
        }
    }

    pub fn request_quit(&mut self) -> QuitDecision {
        if self.pending.is_empty() {
            QuitDecision::Exit
        } else {
            self.quit_offered = true;
            self.status = "Pending Changes: Apply and Quit, Discard and Quit, or Cancel".to_owned();
            QuitDecision::Prompt
        }
    }

    pub fn discard_and_prepare_quit(&mut self) {
        self.pending.clear();
        self.pending_selected.clear();
        self.quit_offered = false;
        self.status = "Pending Changes discarded".to_owned();
    }

    pub fn cancel_quit(&mut self) {
        self.quit_offered = false;
    }

    pub fn handle_key(&mut self, stroke: &str) -> KeyEffect {
        if let Some(section) = Section::from_digit(stroke) {
            self.active_section = section;
            return KeyEffect::Handled;
        }
        match stroke {
            "r" => {
                self.refresh();
                KeyEffect::Handled
            }
            "a" => {
                let ok = self.apply_pending();
                if self.quit_offered && ok {
                    KeyEffect::Quit
                } else {
                    KeyEffect::Handled
                }
            }
            "backspace" | "delete" => {
                self.queue_remove_selected();
                KeyEffect::Handled
            }
            "p" => {
                self.active_section = Section::Pending;
                KeyEffect::Handled
            }
            "s" | "," => {
                self.active_section = Section::Settings;
                KeyEffect::Handled
            }
            "?" | "shift-/" => KeyEffect::ShowHelp,
            "q" => match self.request_quit() {
                QuitDecision::Exit => KeyEffect::Quit,
                QuitDecision::Prompt => KeyEffect::PromptQuit,
            },
            "d" if self.quit_offered => {
                self.discard_and_prepare_quit();
                KeyEffect::Quit
            }
            "escape" => {
                self.cancel_quit();
                KeyEffect::Handled
            }
            "up" => {
                self.move_detail(-1);
                KeyEffect::Handled
            }
            "down" => {
                self.move_detail(1);
                KeyEffect::Handled
            }
            "space" => {
                if let Some(path) = self.selected_detail.clone() {
                    self.toggle_selected(&path);
                }
                KeyEffect::Handled
            }
            "l" if self.active_section == Section::Backup => {
                self.resolve_focused_sync(SyncChoice::KeepLocal);
                KeyEffect::Handled
            }
            "u" if self.active_section == Section::Backup => {
                self.resolve_focused_sync(SyncChoice::UseRemote);
                KeyEffect::Handled
            }
            "b" if self.active_section == Section::Backup => {
                self.resolve_focused_sync(SyncChoice::KeepBoth);
                KeyEffect::Handled
            }
            "cmd-a" | "ctrl-a" => {
                self.select_visible();
                KeyEffect::Handled
            }
            _ => KeyEffect::Ignored,
        }
    }

    pub fn pending_items(&self) -> Vec<PendingChange> {
        self.pending.items()
    }

    pub fn pending_warnings(&self) -> Vec<String> {
        self.pending.warnings()
    }

    pub fn pending_blockers(&self) -> Vec<String> {
        self.pending.blockers()
    }
}

fn read_snapshots(root: &Path) -> Vec<SnapshotInfo> {
    let mut out = Vec::new();
    let Ok(entries) = fs::read_dir(root) else {
        return out;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        let manifest = path.join("manifest.json");
        let Ok(bytes) = fs::read(&manifest) else {
            continue;
        };
        let Ok(snapshot) = serde_json::from_slice::<Snapshot>(&bytes) else {
            continue;
        };
        out.push(SnapshotInfo {
            id: snapshot.id,
            created_at: snapshot.created_at,
            entry_count: snapshot.entries.len(),
        });
    }
    out.sort_by(|left, right| right.created_at.cmp(&left.created_at));
    out
}

pub fn file_tree(path: &Path) -> Vec<String> {
    collect_skill_files(path)
        .map(|files| files.into_iter().map(|file| file.relative_path).collect())
        .unwrap_or_default()
}

pub fn read_preview(path: &Path, file_name: &str) -> Option<String> {
    fs::read_to_string(path.join(file_name)).ok()
}

pub fn equivalent_cli(placement: &SkillPlacement) -> String {
    let source = placement
        .lock_entry
        .as_ref()
        .and_then(|entry| SkillSource::parse(&entry.source).ok());
    equivalent_command(
        PlanAction::Remove,
        &placement.name,
        source.as_ref(),
        placement.workspace_kind == WorkspaceKind::Global,
        None,
    )
    .unwrap_or_default()
}

pub fn state_label(state: &SkillState) -> &'static str {
    match state {
        SkillState::Managed => "Managed",
        SkillState::Untracked => "Untracked",
    }
}

pub fn preset_mode_label(mode: PresetMode) -> &'static str {
    match mode {
        PresetMode::AddMissing => "Add missing",
        PresetMode::MatchExactly => "Match exactly",
    }
}

pub fn kind_label(kind: &WorkspaceKind) -> &'static str {
    match kind {
        WorkspaceKind::Global => "Global",
        WorkspaceKind::Project => "Project",
        WorkspaceKind::Agent => "Agent",
        WorkspaceKind::Custom => "Custom",
    }
}

pub fn action_label(action: PlanAction) -> &'static str {
    match action {
        PlanAction::Install => "Install",
        PlanAction::Update => "Update",
        PlanAction::Remove => "Remove",
        PlanAction::Move => "Move",
        PlanAction::Copy => "Copy",
        PlanAction::Relink => "Relink",
        PlanAction::AttachSource => "Attach Source",
        PlanAction::Restore => "Restore",
        PlanAction::Metadata => "Lockfile",
    }
}

pub fn duplicate_label(class: &DuplicateClass) -> &'static str {
    match class {
        DuplicateClass::ExactDuplicate => "Exact Duplicate",
        DuplicateClass::SourceDuplicate => "Source Duplicate",
        DuplicateClass::NameCollision => "Name Collision",
    }
}

pub fn remote_status_label(status: RemoteChangeStatus) -> &'static str {
    match status {
        RemoteChangeStatus::Available => "Available from backup",
        RemoteChangeStatus::Conflict => "Conflict",
        RemoteChangeStatus::Unchanged => "Unchanged",
        RemoteChangeStatus::Removed => "Local only",
    }
}

fn path_under(path: &Path, root: &Path) -> bool {
    path == root || path.starts_with(root)
}

#[cfg(test)]
mod tests {
    use super::*;
    use gino_core::metadata::default_snapshot_root;
    use tempfile::tempdir;

    fn write_skill(root: &Path, name: &str) -> PathBuf {
        let skill = root.join(name);
        fs::create_dir_all(&skill).expect("skill dir");
        fs::write(
            skill.join("SKILL.md"),
            format!("---\nname: {name}\ndescription: demo\n---\n# {name}\nbody\n"),
        )
        .expect("skill");
        fs::write(skill.join("README.md"), format!("# {name} readme\n")).expect("readme");
        skill
    }

    fn session_at(root: &Path, skills: &[&str]) -> Session {
        let skill_root = root.join("skills");
        fs::create_dir_all(&skill_root).expect("skills");
        for name in skills {
            write_skill(&skill_root, name);
        }
        let workspace = Workspace::new("custom", "Custom", WorkspaceKind::Custom, &skill_root);
        let inventory = InventoryScanner::new(std::slice::from_ref(&workspace))
            .scan(1)
            .expect("scan");
        let metadata = root.join("state.sqlite");
        let preferences = Preferences {
            snapshot_root: root.join("snapshots"),
            push_mode: "commit_locally".to_owned(),
            snapshot_retention: 5,
            ..Preferences::default()
        };
        MetadataStore::open(&metadata)
            .expect("store")
            .save_preferences(&preferences)
            .expect("prefs");
        let backup = GitRepository::open_or_init(root.join("backup")).expect("git");
        Session::new(
            vec![workspace],
            inventory,
            Ok(backup),
            metadata,
            preferences,
        )
    }

    #[test]
    fn settings_report_version_and_github_releases_without_self_update() {
        let root = tempdir().expect("root");
        let session = session_at(root.path(), &["demo"]);
        let (version, releases) = Session::about();
        assert_eq!(version, "1.0.0");
        assert_eq!(releases, RELEASES_URL);
        assert!(releases.starts_with("https://github.com/"));
        assert!(releases.ends_with("/releases"));
        assert_eq!(session.status, format!("Gino {version}"));
        let encoded = serde_json::to_string(&session.preferences).expect("prefs");
        assert!(!encoded.contains("telemetry"));
        assert!(!encoded.contains("self_update"));
    }

    #[test]
    fn keyboard_digits_switch_numbered_sections() {
        let root = tempdir().expect("root");
        let mut session = session_at(root.path(), &["demo"]);
        assert_eq!(session.handle_key("1"), KeyEffect::Handled);
        assert_eq!(session.active_section, Section::Library);
        assert_eq!(session.handle_key("2"), KeyEffect::Handled);
        assert_eq!(session.active_section, Section::Marketplace);
        assert_eq!(session.handle_key("6"), KeyEffect::Handled);
        assert_eq!(session.active_section, Section::CustomWorkspaces);
        assert_eq!(session.handle_key("8"), KeyEffect::Handled);
        assert_eq!(session.active_section, Section::Presets);
        assert_eq!(session.handle_key("9"), KeyEffect::Handled);
        assert_eq!(session.active_section, Section::Backup);
        assert_eq!(session.handle_key("0"), KeyEffect::Handled);
        assert_eq!(session.active_section, Section::Activity);
        assert_eq!(session.handle_key("s"), KeyEffect::Handled);
        assert_eq!(session.active_section, Section::Settings);
        assert_eq!(session.handle_key("p"), KeyEffect::Handled);
        assert_eq!(session.active_section, Section::Pending);
        assert_eq!(session.handle_key("?"), KeyEffect::ShowHelp);
    }

    #[test]
    fn refresh_is_read_only_and_drops_ghost_skills() {
        let root = tempdir().expect("root");
        let mut session = session_at(root.path(), &["demo", "other"]);
        let skill = root.path().join("skills/other");
        let before = fs::read_to_string(skill.join("SKILL.md")).expect("skill");
        fs::remove_dir_all(&skill).expect("delete external");
        session.handle_key("r");
        assert!(
            !session
                .inventory
                .placements
                .iter()
                .any(|placement| placement.name == "other")
        );
        assert!(root.path().join("skills/demo/SKILL.md").is_file());
        assert!(before.contains("other"));
        assert!(session.pending.is_empty());
    }

    #[test]
    fn selection_never_writes_files() {
        let root = tempdir().expect("root");
        let mut session = session_at(root.path(), &["demo"]);
        let path = session.inventory.placements[0].path.clone();
        let stamp = fs::metadata(&path)
            .expect("meta")
            .modified()
            .expect("mtime");
        session.click_placement(path.clone(), false);
        session.select_visible();
        session.clear_selection();
        session.click_placement(path.clone(), true);
        assert_eq!(
            fs::metadata(&path)
                .expect("meta")
                .modified()
                .expect("mtime"),
            stamp
        );
        assert!(path.join("SKILL.md").is_file());
    }

    #[test]
    fn shift_range_selection_covers_visible_span() {
        let root = tempdir().expect("root");
        let mut session = session_at(root.path(), &["alpha", "beta", "gamma"]);
        let paths = session
            .visible_placements()
            .into_iter()
            .map(|placement| placement.path.clone())
            .collect::<Vec<_>>();
        assert_eq!(paths.len(), 3);
        session.click_placement(paths[0].clone(), false);
        session.click_placement(paths[2].clone(), true);
        assert_eq!(session.selected_paths.len(), 3);
    }

    #[test]
    fn queue_remove_does_not_delete_until_apply() {
        let root = tempdir().expect("root");
        let mut session = session_at(root.path(), &["demo"]);
        let path = session.inventory.placements[0].path.clone();
        session.click_placement(path.clone(), false);
        session.handle_key("backspace");
        assert!(path.join("SKILL.md").is_file());
        assert_eq!(session.selected_pending_count(), 1);
        assert!(session.apply_label().contains("Apply 1 change"));
        assert_eq!(session.active_section, Section::Library);
    }

    #[test]
    fn unavailable_items_block_apply_until_deselected() {
        let root = tempdir().expect("root");
        let mut session = session_at(root.path(), &["keep", "gone"]);
        for placement in session.inventory.placements.clone() {
            session.selected_paths.clear();
            session.selected_paths.insert(placement.path);
            session.queue_remove_selected();
        }
        assert!(session.can_apply());
        fs::remove_dir_all(root.path().join("skills/gone")).expect("external delete");
        session.refresh();
        assert!(!session.can_apply());
        let unavailable = session
            .pending_items()
            .into_iter()
            .find(|item| !item.available())
            .expect("unavailable");
        assert!(
            unavailable
                .unavailable_reason
                .as_deref()
                .unwrap_or_default()
                .contains("Missing after refresh")
        );
        session.toggle_pending(unavailable.id);
        assert!(session.can_apply());
        assert_eq!(session.selected_pending_count(), 1);
    }

    #[test]
    fn duplicate_keep_one_queues_without_writing() {
        let root = tempdir().expect("root");
        let first = root.path().join("first");
        let second = root.path().join("second");
        write_skill(&first, "demo");
        write_skill(&second, "demo");
        let workspaces = vec![
            Workspace::new("first", "First", WorkspaceKind::Custom, &first),
            Workspace::new("second", "Second", WorkspaceKind::Custom, &second),
        ];
        let inventory = InventoryScanner::new(&workspaces).scan(1).expect("scan");
        let metadata = root.path().join("state.sqlite");
        let preferences = Preferences {
            snapshot_root: root.path().join("snapshots"),
            push_mode: "commit_locally".to_owned(),
            ..Preferences::default()
        };
        let backup = GitRepository::open_or_init(root.path().join("backup")).expect("git");
        let mut session = Session::new(workspaces, inventory, Ok(backup), metadata, preferences);
        let group = session
            .inventory
            .duplicate_groups
            .iter()
            .find(|group| group.skill_name == "demo")
            .cloned()
            .expect("group");
        session.keep_duplicate(0, group.placement_indexes[0]);
        assert!(first.join("demo/SKILL.md").is_file());
        assert!(second.join("demo/SKILL.md").is_file());
        assert!(
            session
                .pending_items()
                .iter()
                .any(|item| item.action == PlanAction::Remove)
        );
    }

    #[test]
    fn register_and_remove_bookmark_leaves_files() {
        let root = tempdir().expect("root");
        let mut session = session_at(root.path(), &["demo"]);
        let project = root.path().join("project");
        fs::create_dir_all(project.join(".agents/skills")).expect("project");
        write_skill(&project.join(".agents/skills"), "from-project");
        session.register_folder_path(WorkspaceKind::Project, project.clone());
        assert!(
            session
                .bookmarks(WorkspaceKind::Project)
                .iter()
                .any(|bookmark| bookmark.path == project)
        );
        assert!(
            project
                .join(".agents/skills/from-project/SKILL.md")
                .is_file()
        );
        let id = session.bookmarks(WorkspaceKind::Project)[0].id.clone();
        session.remove_bookmark(&id);
        assert!(session.bookmarks(WorkspaceKind::Project).is_empty());
        assert!(
            project
                .join(".agents/skills/from-project/SKILL.md")
                .is_file()
        );
    }

    #[test]
    fn exit_prompt_when_pending_is_non_empty() {
        let root = tempdir().expect("root");
        let mut session = session_at(root.path(), &["demo"]);
        assert_eq!(session.request_quit(), QuitDecision::Exit);
        session.click_placement(session.inventory.placements[0].path.clone(), false);
        session.queue_remove_selected();
        assert_eq!(session.request_quit(), QuitDecision::Prompt);
        assert_eq!(session.handle_key("escape"), KeyEffect::Handled);
        assert!(!session.quit_offered);
        assert!(!session.pending.is_empty());
        session.request_quit();
        assert_eq!(session.handle_key("d"), KeyEffect::Quit);
        assert!(session.pending.is_empty());
    }

    #[test]
    fn marketplace_queue_from_local_source_does_not_write() {
        let root = tempdir().expect("root");
        let mut session = session_at(root.path(), &["demo"]);
        let source = write_skill(&root.path().join("source"), "fresh");
        let dest = root.path().join("skills/fresh");
        assert!(!dest.exists());
        session.install_target_id = "custom".to_owned();
        session.queue_install_source(&source.to_string_lossy(), Some("fresh"));
        assert!(!dest.exists());
        assert!(
            session
                .pending_items()
                .iter()
                .any(|item| item.action == PlanAction::Install && item.skill_name == "fresh")
        );
    }

    #[test]
    fn preset_apply_and_tags_are_metadata_only() {
        let root = tempdir().expect("root");
        let mut session = session_at(root.path(), &["demo", "other"]);
        session.add_tag("demo", "web");
        assert_eq!(session.tags_for("demo"), BTreeSet::from(["web".to_owned()]));
        assert!(root.path().join("skills/demo/SKILL.md").is_file());
        session.click_placement(session.inventory.placements[0].path.clone(), false);
        session.save_preset_from_selection("Daily");
        assert_eq!(session.presets().len(), 1);
        session.preset_mode = PresetMode::MatchExactly;
        session.queue_preset(&session.presets()[0].id, "custom");
        assert!(root.path().join("skills/other/SKILL.md").is_file());
        assert!(
            session
                .pending_items()
                .iter()
                .any(|item| item.action == PlanAction::Remove)
        );
    }

    #[test]
    fn marketplace_search_requires_two_characters() {
        let root = tempdir().expect("root");
        let mut session = session_at(root.path(), &["demo"]);
        session.marketplace_query = "a".to_owned();
        session.search_marketplace();
        assert!(
            session
                .action_error
                .as_deref()
                .unwrap_or_default()
                .contains("at least 2 characters")
        );
        session.queue_selected_marketplace();
        assert!(
            session
                .action_error
                .as_deref()
                .unwrap_or_default()
                .contains("Select one or more")
        );
    }

    #[test]
    fn apply_uses_settings_push_mode_and_snapshot_root() {
        let root = tempdir().expect("root");
        let mut session = session_at(root.path(), &["demo"]);
        assert_eq!(session.push_mode(), PushMode::CommitLocally);
        assert_eq!(
            Preferences::default().snapshot_root,
            default_snapshot_root()
        );
        assert_ne!(session.preferences.snapshot_root, std::env::temp_dir());
        let path = session.inventory.placements[0].path.clone();
        session.click_placement(path.clone(), false);
        session.queue_remove_selected();
        assert!(session.apply_pending());
        assert!(!path.exists());
        assert!(session.pending.is_empty());
        assert!(
            session
                .list_snapshots()
                .iter()
                .any(|snapshot| snapshot.entry_count > 0)
        );
        assert_eq!(
            session
                .backup
                .as_ref()
                .unwrap()
                .commit_count()
                .expect("commits"),
            1
        );
        assert!(
            session
                .activity_records()
                .iter()
                .any(|record| record.outcome.contains("success") || record.action.contains("Apply"))
        );
        assert!(session.last_commit().is_some());
        assert!(!session.commit_history().is_empty());
        session.check_remote();
        assert!(
            session.action_error.is_some() || session.sync_proposal.is_some(),
            "Check Remote should report a result or an error"
        );
    }

    #[test]
    fn restore_snapshot_is_pending_only() {
        let root = tempdir().expect("root");
        let mut session = session_at(root.path(), &["demo"]);
        let path = session.inventory.placements[0].path.clone();
        session.click_placement(path.clone(), false);
        session.queue_remove_selected();
        assert!(session.apply_pending());
        let snapshot_id = session.list_snapshots()[0].id.clone();
        session.queue_restore_snapshot(&snapshot_id);
        assert!(!path.exists());
        assert!(
            session
                .pending_items()
                .iter()
                .any(|item| item.action == PlanAction::Restore)
        );
    }
}
