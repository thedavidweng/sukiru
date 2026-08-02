# Native Agent Skills Application — Product and Implementation Specification

Status: Final implementation specification  
Primary implementation: Rust + GPUI + `longbridge/gpui-component`  
Supported platforms: macOS, Windows, Linux

## 1. Problem Statement

Developers increasingly use multiple AI coding agents, each with its own Skill directories, project-local conventions, and installation state. Vercel's `skills` CLI and skills.sh define the public installation protocol and ecosystem behavior, but command-line workflows remain inefficient for large libraries, multi-agent targeting, duplicate cleanup, workspace comparison, backup, and multi-device use.

The product is a native GUI companion to Vercel `skills`. It exposes the actual Skill state already present on disk, remains interoperable with `npx skills`, and adds visual management without creating a competing installation protocol.

The application must solve five concrete problems:

1. Show every Skill that the supported agents actually see, across global, project, agent-specific, and user-registered workspaces.
2. Make multi-select installation, movement, update, removal, deduplication, and preset application safe and predictable.
3. Keep every write operation pending until the user explicitly applies a reviewed batch.
4. Preserve reversible local history and Git-backed backup/synchronization without turning Git into a second installation authority.
5. Maintain behavior compatible with the current public contract of Vercel `skills` and skills.sh.

## 2. Product Contract

### 2.1 Normative upstream

The current public behavior of `vercel-labs/skills` is normative for:

- supported source formats;
- Skill discovery;
- installation layout;
- supported agents and their paths;
- global and project scopes;
- copy and symlink behavior;
- lockfile formats and semantics;
- update behavior;
- skills.sh search and marketplace behavior;
- validation and safety behavior exposed by the CLI.

The application must not invent a parallel interpretation for these concerns. Compatibility is verified against a pinned upstream version and continuously checked against the latest upstream release.

### 2.2 Native implementation

The shipping application contains a Rust-native implementation of the required protocol. It does not require Node.js or invoke `npx skills` during normal operation.

The official CLI serves as:

- the protocol reference;
- a differential test oracle;
- the command-line companion shown to users when an equivalent command exists.

### 2.3 Source of truth

The actual filesystem and Vercel-compatible lockfiles are the source of truth for installed state.

The application database stores only reconstructible or application-specific state, including:

- registered project bookmarks;
- custom workspace registrations;
- tags;
- presets;
- UI preferences;
- activity metadata;
- ignored duplicate decisions;
- Git synchronization metadata;
- snapshot metadata.

The database must never be required to reconstruct which Skills physically exist or which lock entries are active.

### 2.4 No implicit mutation

The application may scan, hash, compare, fetch remote metadata, detect updates, detect duplicates, and generate plans automatically.

It must not install, update, delete, move, copy, relink, restore, merge, or otherwise modify a Skill until the user explicitly applies a pending batch.

## 3. Product Principles

1. **Protocol compatibility first.** A Skill installed or removed by the GUI remains understandable to `npx skills`, and a Skill changed by `npx skills` appears correctly after application refresh.
2. **Real state, not an imagined catalog.** The Library represents the current filesystem, not an independent central inventory.
3. **Plan before write.** Every write begins as a visible pending change.
4. **One Apply, one transaction, one commit.** A successful Apply forms one reversible filesystem transaction and one Git commit.
5. **No hidden background synchronization.** Startup scans once; later filesystem refreshes and remote checks are user-triggered.
6. **No in-app editing.** Skill content is permanently read-only inside the application and opens in an external editor for modification.
7. **Explicit failures.** Errors identify the Skill, action, source, destination, and underlying cause.
8. **Delete rather than archive.** Obsolete implementation paths are removed. Git history preserves prior implementations.

## 4. Glossary

### Skill

A directory containing a valid `SKILL.md` and any supporting files recognized by the Vercel `skills` protocol.

### Installed Skill

A Skill physically present in a supported workspace or reachable there through a supported link.

### Managed Skill

An installed Skill with sufficient compatible source and lock metadata to support update tracking.

### Untracked Skill

An installed Skill present on disk without compatible source metadata. It remains fully visible and supports preview, removal, movement, copy, export, tagging, duplicate analysis, and source attachment. Update remains unavailable until the user explicitly attaches a source.

### Workspace

A concrete Skill root visible to the user. Workspace classes include Global, Project, Agent, and Custom Workspace.

### Pending Change

A user-selected write operation that has not yet modified the filesystem.

### Apply Batch

The ordered set of selected Pending Changes executed as one atomic user action.

### Snapshot

A local pre-Apply recovery capture sufficient to restore changed files, links, and lockfiles to their pre-Apply state.

### Preset

A named reusable set of Skills that generates Pending Changes for a selected workspace and agent target.

### Tag

Application metadata used only for classification, filtering, and search.

### Duplicate Group

A deterministic relationship among two or more installed Skills classified as Exact Duplicate, Source Duplicate, or Name Collision.

## 5. Supported Scope

### 5.1 Platforms

macOS, Windows, and Linux are equal 1.0 targets. No platform may ship as a reduced-function experimental build.

WSL is not an independent target. Windows-accessible WSL paths may be registered as ordinary paths, but automatic WSL agent discovery and Linux link semantics are not guaranteed.

### 5.2 Product surfaces

The 1.0 application contains:

- Library;
- Marketplace/Search;
- Global workspace;
- explicit Project workspaces;
- Agent workspaces derived from upstream registry behavior;
- Custom Workspaces;
- Duplicates workspace;
- Pending Changes review;
- Presets and Tags;
- Git Backup and Sync;
- Settings;
- local Activity and exported diagnostic logs.

### 5.3 Explicitly excluded

- an application-specific CLI;
- in-app Skill editing;
- semantic or AI-based duplicate detection;
- background filesystem watchers;
- periodic remote polling;
- automatic background pull or merge;
- product telemetry;
- application self-update in 1.0;
- a second custom Skill installation protocol;
- a hidden central installed-Skill library separate from real workspaces.

## 6. Information Architecture

### 6.1 Primary navigation

The sidebar contains:

1. Library
2. Marketplace
3. Global
4. Projects
5. Agents
6. Custom Workspaces
7. Duplicates
8. Presets
9. Backup
10. Activity
11. Settings

A persistent Pending Changes control appears in the window chrome whenever the plan contains at least one item. It displays the selected count and opens the review surface.

### 6.2 Context model

Global is always available.

Projects enter the application only through explicit registration by one of these actions:

- Open Project Folder;
- drag a folder onto the application;
- operating-system “Open With” integration;
- launching the application with a project path.

The application does not scan the entire filesystem for repositories.

A registered project may be any folder. Detection inspects its relevant lockfiles, shared Skill roots, supported agent roots, and repository metadata. Removing a project from the sidebar removes only the bookmark.

### 6.3 Custom Workspaces

A user may register an arbitrary Skill root as a Custom Workspace. Custom Workspaces remain distinct from official upstream agents and do not modify the upstream registry.

Each Custom Workspace stores:

- stable local identifier;
- display name;
- local path;
- preferred copy or link mode where applicable.

Removing a Custom Workspace registration never deletes its contents.

## 7. Startup and Refresh

### 7.1 Startup sequence

At application startup:

1. Load preferences and registered workspaces.
2. Detect supported agents using the upstream-compatible registry.
3. Scan all active workspace roots once.
4. Parse Skill metadata and compatible lockfiles.
5. Reconstruct installed state.
6. Recompute duplicate groups.
7. Reconcile stale application metadata with actual files.
8. Fetch Git remote references once when backup is configured, without modifying local content.
9. Render the application only after the initial state model is internally consistent.

### 7.2 Manual Refresh

A visible Refresh action rescans the current context. A global Refresh action rescans all registered contexts.

Refresh:

- adds newly discovered Skills;
- removes Skills no longer present;
- updates modified content hashes and metadata;
- recomputes managed/untracked status;
- recomputes duplicate groups;
- updates link state;
- marks pending plan items whose inputs no longer exist as Unavailable.

Refresh never changes files or automatically alters the user's Pending Changes selection.

### 7.3 No live monitoring

The application does not use filesystem watchers or polling to track external changes while running. The UI reflects startup state plus later user-triggered Refresh results.

## 8. Library Model

### 8.1 Unified projection

Library is a projection over every installed Skill found in active Global, Project, Agent, and Custom Workspaces.

A single logical Skill may appear in multiple placements. The list supports grouping by:

- Skill identity;
- workspace;
- source;
- agent availability;
- managed/untracked state;
- update state;
- duplicate state;
- tag.

### 8.2 Skill detail

The detail surface displays:

- name and description;
- source and source type;
- source ref and path where known;
- installed placements;
- agent availability;
- lock status;
- update status;
- duplicate status;
- content hash;
- file tree;
- read-only `SKILL.md` preview;
- read-only `README.md` preview where present;
- upstream comparison when available;
- Reveal in Finder/Explorer/File Manager;
- Open in External Editor;
- equivalent `npx skills` command where representable.

No text editor or save action exists in the application.

### 8.3 Managed and Untracked

A valid compatible lock/source record yields Managed state.

Files without a compatible source record yield Untracked state. The application never guesses source identity from the Skill name.

Attach Source allows the user to bind an Untracked Skill to an explicit Git URL, local path, direct source, or skills.sh identity supported by upstream behavior.

Attach Source compares actual content to the selected source:

- matching content creates compatible metadata through Pending Changes;
- differing content requires the user to keep local content or reinstall from the selected source.

## 9. Marketplace and Installation

Marketplace behavior and data fields follow skills.sh and the Vercel `skills` implementation.

The installation flow is:

1. Select or enter a supported source.
2. Discover Skills using upstream-compatible rules.
3. Select one or multiple discovered Skills.
4. Select scope, project, and supported target agents.
5. Select upstream-compatible copy/link behavior where applicable.
6. Review conflicts and resulting lockfile changes.
7. Add operations to Pending Changes.
8. Apply from the global review surface.

The marketplace and installation flow must support every source form currently supported by the pinned Vercel `skills` version. Unsupported inventions are prohibited.

## 10. Pending Changes

### 10.1 Plan behavior

Install, update, remove, move, copy, relink, duplicate cleanup, preset application, restore, remote sync, source attachment, and metadata-affecting repository operations create Pending Changes.

Pending Changes are session-only. They are not persisted across application restarts.

The user may:

- select and deselect individual operations;
- remove plan items;
- inspect source and destination;
- inspect file and lockfile effects;
- group by action, workspace, Skill, or origin;
- return to other application surfaces while retaining the plan.

### 10.2 Unavailable plan items

After Refresh, an operation whose required source Skill or path no longer exists remains visible and is marked Unavailable.

Unavailable items show:

- original Skill identity;
- original path;
- requested action;
- missing dependency;
- `Missing after refresh` state.

Apply remains disabled until the user deselects every Unavailable item.

### 10.3 Apply review

Before execution, the review surface displays:

- exact operation count;
- Skills affected;
- workspaces affected;
- source and destination paths;
- link/copy mode;
- lockfile changes;
- Git effects;
- snapshot creation;
- warnings and conflicts.

The action button uses specific wording such as `Apply 12 changes` rather than a generic confirmation label.

### 10.4 Exit protection

When Pending Changes exist, closing the application presents exactly:

- Apply and Quit;
- Discard and Quit;
- Cancel.

Pending Changes cannot be saved as a draft for a later session.

Switching context does not discard the plan. Removing a project or Custom Workspace referenced by the plan requires the user to remove corresponding plan items first.

## 11. Apply Transaction

### 11.1 Atomic behavior

An Apply Batch is all-or-nothing.

Execution order is derived from operation dependencies, including creation before linking and unlinking before removal.

Before the first write, the application creates one snapshot covering every path and lockfile the batch may change.

The executor then performs the original selected tasks directly. It does not add speculative external-change guards or maintain a parallel optimistic-concurrency protocol.

### 11.2 Failure behavior

The first failed operation stops the batch.

The application restores every already-applied step from the batch snapshot. No later task executes. No Git commit is created.

The error view states:

- Skill;
- action;
- source workspace and path;
- target workspace and path;
- original operating-system or protocol error;
- concise recovery guidance.

The plan remains available so the user may deselect the failed item, Refresh, or correct the external condition before trying again.

### 11.3 Success behavior

After all operations succeed:

1. Write compatible lockfiles atomically.
2. Rescan affected roots.
3. Verify that expected final state exists.
4. Update reconstructible application metadata.
5. Materialize backup repository changes.
6. Create exactly one Git commit.
7. Push when configured for Commit and Push.
8. Clear successful Pending Changes.
9. Record local activity.

A push failure does not roll back the successful filesystem transaction or local commit. The application shows `Not pushed` and permits manual retry.

## 12. Recovery Snapshots

### 12.1 Contents

A snapshot includes only material needed to reverse the Apply Batch:

- deleted or overwritten Skill files;
- prior symlink/junction targets and types;
- prior compatible lockfiles;
- operation manifest;
- result metadata.

Snapshots are local and never enter the Git backup repository.

### 12.2 Retention

Settings contains a numeric option for the maximum number of retained snapshots.

After a successful Apply, retention removes the oldest snapshots beyond the configured count. Git history is never pruned by this setting.

### 12.3 Restore

Restoring a snapshot produces Pending Changes rather than writing immediately. Applying a restore first snapshots the current state, then performs the restore as a normal atomic Apply and Git commit.

## 13. Duplicate Detection

### 13.1 Deterministic classes

#### Exact Duplicate

Two Skills have identical deterministic directory hashes after applying the same path normalization and exclusion rules.

#### Source Duplicate

Two Skills resolve to the same source identity, source path, and ref but have different local content.

#### Name Collision

Two Skills declare the same Skill name while differing in source identity or content.

No semantic, embedding-based, or AI duplicate detection exists.

### 13.2 Duplicates workspace

The Duplicates workspace displays groups by class and provides:

- placement comparison;
- source comparison;
- file hash comparison;
- read-only diff;
- affected agent and workspace badges;
- batch selection for Exact Duplicates;
- per-group decisions for Source Duplicates and Name Collisions.

The normal Library displays only a lightweight duplicate badge.

Duplicate cleanup actions enter Pending Changes and follow normal Apply semantics.

Name Collisions may be ignored. An ignored decision remains hidden only while the relevant source/content identity remains unchanged.

## 14. Updates and Local Modifications

Update Check is read-only.

For a Managed Git-based Skill:

- unchanged local content may directly generate an update Pending Change;
- modified local content is marked Locally Modified and must display a local/upstream diff.

The user chooses:

- Keep Local;
- Use Upstream;
- Keep Both.

Keep Local creates no filesystem operation and may record the ignored upstream identity until upstream changes again.

Use Upstream creates a replacement Pending Change.

Keep Both preserves local content and creates a separate upstream-derived placement through Pending Changes.

No automatic textual merge exists for Skill content.

## 15. Tags and Presets

### 15.1 Tags

Tags are multi-value application metadata used only for grouping, filtering, and search. Tags do not affect installation or agent behavior.

### 15.2 Presets

A Preset is a named Skill set. Applying it to a chosen workspace and agent target generates Pending Changes.

Preset modes:

- **Add Missing**: add absent Skills and leave unrelated existing Skills untouched.
- **Match Exactly**: add missing Skills and generate removal operations for Skills outside the Preset.

Add Missing is the default.

Preset application is one-time. It does not establish continuous synchronization.

Tags, Presets, and logical targets are included in Git backup data.

## 16. Git Backup and Multi-Device Sync

### 16.1 Role of Git

Git provides version history, backup, and cross-device transfer. It is not the authority for current installation state.

A Skill present only in backup is shown as `Available from backup`, not installed.

Remote or restored content becomes installed only after the user reviews and applies generated Pending Changes.

### 16.2 Repository contents

The backup repository includes:

- complete backed-up Skill contents;
- source metadata;
- stable manifest data;
- Tags;
- Presets;
- logical agent/workspace target intent;
- data required for skill-aware conflict handling.

It excludes:

- tokens and credentials;
- proxy configuration;
- OS keychain data;
- absolute machine paths;
- project bookmarks tied to local paths;
- caches;
- logs;
- window state;
- Pending Changes;
- local recovery snapshots;
- SQLite database files.

Logical targets use stable tool/scope identifiers rather than machine paths. A new device maps those identities to locally detected agents before generating restore plans.

### 16.3 Connection methods

Backup supports:

- GitHub device-flow authentication and private repository creation;
- existing HTTPS remotes;
- SSH remotes;
- self-hosted Git remotes.

Tokens are stored only in the operating-system credential store.

### 16.4 Apply and push modes

Every successful Apply creates a local Git commit.

Settings offers:

- Commit and Push;
- Commit Locally.

Commit and Push is the default.

A push failure produces a retryable `Not pushed` state without undoing local changes.

### 16.5 Remote checks

At startup, the application performs one Git fetch when configured.

During the session, it does not poll. The user triggers Check Remote manually.

Remote changes are shown as a comparison and converted into Pending Changes only after user selection. The application never performs an automatic background pull, merge, or overwrite.

### 16.6 Conflict handling

Conflicts are grouped by Skill rather than exposed as raw text-line conflicts.

For a true same-Skill conflict, the user selects:

- Keep Local;
- Use Remote;
- Keep Both.

The selection creates Pending Changes and follows normal Apply semantics.

Unrelated nonconflicting Skills may be presented together in the same proposed sync plan, but no remote content changes local state before Apply.

### 16.7 Large content

The application never silently excludes large Skills.

A configurable repository size policy identifies content above the configured threshold. The user must explicitly choose one of:

- exclude from backup;
- configure Git LFS where supported;
- cancel the Apply.

The UI permanently marks excluded Skills as local-only.

## 17. Lockfile and Filesystem Compatibility

The Rust core reads and writes the same global and project lockfile structures used by the pinned Vercel `skills` version.

Requirements:

- preserve unknown JSON fields during read-modify-write;
- preserve entries unrelated to the current operation;
- use deterministic serialization where field ordering is under application control;
- perform atomic replacement rather than in-place partial writes;
- match upstream content-hash behavior;
- support current source type and source URL semantics;
- support current agent path registry and detection rules;
- recognize both copy and supported link placements;
- never reinterpret a private agent directory as a new custom protocol.

Upstream schema evolution must fail visibly when a safe round trip is impossible. The implementation must not discard unknown data to force compatibility.

## 18. Architecture

### 18.1 Crate boundaries

The implementation is organized around behavior, not UI screens.

#### Protocol Core

Owns upstream-compatible source parsing, discovery, agent registry, lockfiles, hashing, installation rules, update comparison, and equivalent CLI command generation.

#### Inventory Core

Scans workspace roots and produces the normalized installed-state graph. It contains no UI code and no write operations.

#### Planner

Converts user intent and current inventory into an immutable Apply plan with ordered operations, warnings, dependencies, and expected effects.

#### Apply Executor

Executes one plan transaction, creates/restores snapshots, writes lockfiles, verifies final state, and reports exact failures.

#### Duplicate Engine

Computes Exact Duplicate, Source Duplicate, and Name Collision groups from normalized inventory.

#### Git Sync Core

Owns backup materialization, commits, fetch, push, remote comparison, repository history, restore proposals, and skill-aware conflict models.

#### Metadata Store

Owns reconstructible/UI-only SQLite state. No filesystem truth is hidden here.

#### Platform Services

Owns credential storage, file dialogs, external editor launch, reveal-in-file-manager behavior, process restart where needed, path normalization, and platform-specific link creation.

#### GPUI Application

Owns windows, navigation, commands, state subscriptions, keyboard behavior, and rendering through GPUI and `gpui-component`.

### 18.2 Dependency direction

UI depends on application services. Application services depend on pure cores. Pure cores do not depend on GPUI, SQLite presentation models, or platform window code.

Planner and inventory models are serializable for fixtures and diagnostics, but no public application-specific CLI is shipped.

### 18.3 Concurrency

Scanning, hashing, Git network work, source downloads, and diff generation run off the UI thread.

All mutations for one Apply Batch are serialized through a single executor.

The UI displays cancellable progress before the first write where cancellation is safe. Once filesystem mutation begins, cancellation is disabled until success or rollback completes.

### 18.4 State ownership

The application maintains one immutable inventory snapshot per refresh generation and one session-scoped Pending Changes model.

Views derive display state from these models. Individual screens do not maintain competing copies of installed state.

## 19. GPUI User Experience Requirements

### 19.1 Component use

Use `longbridge/gpui-component` for mature shared primitives including:

- sidebar;
- tree;
- table/list virtualization;
- dialogs;
- command palette;
- checkboxes;
- tabs;
- markdown rendering;
- notifications;
- theme primitives.

Custom components are justified only when existing primitives cannot satisfy the interaction without compromising accessibility or performance.

### 19.2 List and selection behavior

Every Skill list with batch actions supports:

- checkbox selection;
- shift-range selection;
- select visible;
- select all matching current filter;
- clear selection;
- keyboard navigation;
- stable selection across sorting and filtering when the selected Skill remains in scope;
- a visible count and resulting operation summary.

Selection alone never mutates files.

### 19.3 Keyboard and accessibility

All primary actions are operable without a pointer.

Requirements include:

- deterministic focus order;
- visible focus ring;
- accessible names for icon-only actions;
- no color-only state communication;
- screen-reader-compatible labels and status announcements where supported by GPUI/platform APIs;
- keyboard access to sidebar, lists, details, plan review, dialogs, Refresh, Apply, and conflict choices;
- text scaling without clipped controls;
- light and dark themes with sufficient contrast.

### 19.4 Progress and errors

Long operations display the current high-level stage and current Skill without flooding the user with internal implementation details.

Error dialogs preserve exact technical details behind an expandable disclosure and provide a Copy Details action.

## 20. Settings

Settings includes:

- theme and text size;
- language;
- external editor selection;
- registered projects;
- Custom Workspaces;
- snapshot retention count;
- backup repository path and remote;
- Commit and Push / Commit Locally mode;
- Git credentials/status controls;
- backup size policy;
- proxy settings where upstream source access requires them;
- agent display order;
- diagnostic log export;
- current application version and GitHub Releases link.

No telemetry setting exists because the application sends no product telemetry.

No self-update control exists in 1.0.

## 21. Activity and Diagnostics

The local Activity view records user-triggered operations and outcomes, including:

- Apply commit identifier;
- Skills and actions;
- timestamp;
- workspace;
- success or rollback;
- push status;
- restore origin where relevant.

Activity history is local and does not enter the backup repository.

Export Logs creates a zip containing sanitized application logs, environment metadata, operation manifests, and error details. It must exclude Skill file contents, tokens, credentials, and unrelated local paths unless the user explicitly opts into a broader diagnostic export.

## 22. User Stories and Acceptance Criteria

### US-001 — Inspect all installed Skills

As a user, I can open Library and see every Skill currently present in registered workspaces.

Acceptance:

1. Startup scan discovers real files and links.
2. Skills installed outside the application appear.
3. Missing files disappear after Refresh.
4. Each placement identifies its workspace and agent availability.

### US-002 — Register a project

As a user, I can add a project folder without allowing an application-wide disk scan.

Acceptance:

1. The folder appears in Projects.
2. Relevant Skill roots and lockfiles are detected.
3. Removing the project bookmark leaves files unchanged.
4. Recent projects remain available after restart.

### US-003 — Install several Skills

As a user, I can choose multiple discovered Skills and targets in one flow.

Acceptance:

1. Discovery matches upstream behavior.
2. Multiple Skills and target agents can be selected.
3. No file changes occur before Apply.
4. Review shows all paths and lockfile effects.
5. One successful Apply creates one commit.

### US-004 — Move a Skill between workspaces

As a user, I can move one or more Skills from one workspace to another.

Acceptance:

1. Move is represented as a plan before mutation.
2. If a selected source disappears before Apply, execution fails with `Source skill is missing` or the platform-equivalent error.
3. The batch rolls back and creates no commit.
4. Refresh marks missing planned inputs Unavailable.
5. Deselecting invalid entries permits a later Apply.

### US-005 — Remove Skills explicitly

As a user, I can select several Skills for removal and review the exact paths before applying.

Acceptance:

1. No deletion occurs at selection time.
2. The confirmation button states the removal count.
3. Snapshot recovery covers deleted content.
4. Lock entries remain compatible after success.

### US-006 — Refresh external changes

As a user, I can ask the application to reflect changes made by a CLI or file manager.

Acceptance:

1. Refresh is visible in every workspace context.
2. Newly added Skills appear.
3. Deleted Skills disappear.
4. Changed content and duplicate state update.
5. Refresh performs no writes.

### US-007 — Detect exact duplicates

As a user, I can inspect groups of byte-equivalent Skills and plan batch cleanup.

Acceptance:

1. Deterministic hashing identifies exact copies.
2. Legitimate shared links do not appear as redundant copied content.
3. Cleanup does not execute before Apply.
4. The user chooses which placement remains.

### US-008 — Inspect divergent copies

As a user, I can see when copies share a source but differ locally.

Acceptance:

1. The group is classified Source Duplicate.
2. Read-only file comparison is available.
3. No automatic merge occurs.
4. Resolution choices create Pending Changes.

### US-009 — Handle a name collision

As a user, I can see Skills with the same declared name but different source or content.

Acceptance:

1. The application does not auto-merge them.
2. Both identities remain inspectable.
3. Ignore remains valid only until identifying content/source changes.

### US-010 — Preview without editing

As a user, I can read a Skill and open it in my editor.

Acceptance:

1. Markdown preview is read-only.
2. No in-app editing control exists.
3. Open in External Editor launches the configured editor.
4. Reveal opens the concrete placement.

### US-011 — Update an unmodified Skill

As a user, I can check a Managed Skill and plan an upstream update.

Acceptance:

1. Check is read-only.
2. The plan identifies old and new source refs/hashes.
3. Apply updates files and compatible lock metadata in one transaction.

### US-012 — Resolve a locally modified update

As a user, I can compare local and upstream content and choose Keep Local, Use Upstream, or Keep Both.

Acceptance:

1. No automatic merge is attempted.
2. Use Upstream and Keep Both generate visible plan operations.
3. Keep Local makes no file mutation.

### US-013 — Use Tags

As a user, I can tag Skills and filter by one or more tags.

Acceptance:

1. Tagging does not change installation state.
2. Tags synchronize through backup.
3. An Untagged filter exists.

### US-014 — Apply a Preset

As a user, I can apply a named group to selected targets.

Acceptance:

1. Add Missing is the default.
2. Match Exactly clearly shows removal operations.
3. Preset application creates a plan, not immediate changes.
4. A Preset does not remain continuously bound to the target.

### US-015 — Back up with Git

As a user, every successful Apply creates a local version.

Acceptance:

1. One Apply creates one commit.
2. Failed Apply creates no commit.
3. Secrets, local paths, database, snapshots, and logs are excluded.
4. The repository remains usable as a normal Git repository.

### US-016 — Push automatically

As a user, I can choose Commit and Push.

Acceptance:

1. Push runs after the local commit.
2. Push failure leaves the local commit intact.
3. `Not pushed` is visible and retryable.

### US-017 — Check another device's changes

As a user, I can inspect remote changes without allowing automatic mutation.

Acceptance:

1. Startup performs one fetch.
2. Check Remote is available manually.
3. Remote differences generate a proposed plan.
4. No remote content changes local files before Apply.

### US-018 — Resolve a backup conflict

As a user, I can choose Keep Local, Use Remote, or Keep Both per conflicting Skill.

Acceptance:

1. Unrelated Skills remain independently reviewable.
2. Resolution produces Pending Changes.
3. Apply snapshots the current state before changing it.

### US-019 — Restore a version

As a user, I can select a prior Git version or local snapshot and review a restore plan.

Acceptance:

1. Restore never writes immediately.
2. Current state is snapshotted before the restore Apply.
3. A successful restore creates a new commit rather than rewriting history.

### US-020 — Configure snapshot retention

As a user, I can set the number of local snapshots retained.

Acceptance:

1. The configured count is enforced after successful Apply.
2. Git history is unaffected.
3. Zero is permitted only when the UI explicitly explains that Apply rollback still requires a temporary transaction snapshot until completion.

### US-021 — Exit with an unapplied plan

As a user, I am warned before losing Pending Changes.

Acceptance:

1. Apply and Quit applies the batch, then exits only after success.
2. Discard and Quit clears the plan and exits.
3. Cancel returns to the application.
4. The application does not silently persist a draft.

### US-022 — Interoperate with `npx skills`

As a user, I can alternate between the GUI and official CLI.

Acceptance:

1. CLI-created state appears after Refresh.
2. GUI-created state is accepted by the pinned CLI.
3. Unknown lockfile fields survive GUI writes.
4. Equivalent commands are shown where representable.

### US-023 — Manage an Untracked Skill

As a user, I can inspect and organize an existing Skill with no lock metadata.

Acceptance:

1. It appears as Untracked rather than hidden.
2. Update is disabled.
3. Removal, movement, copy, export, tagging, duplicate analysis, and preview remain available.
4. Source attachment requires an explicit user-selected source.

### US-024 — Use a Custom Workspace

As a user, I can register an arbitrary Skill root without pretending it is an official agent.

Acceptance:

1. Its path remains local-only metadata.
2. It participates in inventory, duplicate analysis, planning, and backup intent.
3. Removing registration leaves files unchanged.

### US-025 — Operate entirely by keyboard

As a keyboard user, I can complete discovery, selection, planning, review, Apply, Refresh, and conflict resolution.

Acceptance:

1. No primary operation requires a pointer.
2. Focus is always visible.
3. Selection counts and errors are accessible.
4. Dialog focus is trapped and restored correctly.

## 23. Testing Strategy

### 23.1 Highest-priority seam

The primary test seam is the Planner plus Apply Executor running against an isolated real filesystem.

This suite verifies the product's central contract without depending on GPUI rendering.

### 23.2 Planner tests

Planner tests cover:

- install;
- update;
- remove;
- move;
- copy;
- link/relink;
- duplicate cleanup;
- source attachment;
- preset Add Missing;
- preset Match Exactly;
- restore;
- remote sync proposal;
- conflict choice;
- unavailable plan items;
- dependency ordering;
- lockfile effects;
- Git materialization intent.

Assertions include:

- no filesystem mutation;
- deterministic operations for the same inventory and intent;
- clear warnings and blockers;
- exact source and target resolution;
- no operation outside declared workspace roots.

### 23.3 Executor transaction tests

Use temporary directories and real filesystem operations on each platform.

For every operation type, test:

1. successful final state;
2. lockfile state;
3. snapshot contents;
4. one Git commit;
5. push-mode behavior through a local bare remote;
6. injected failure at each mutation boundary;
7. complete rollback;
8. no commit after failure;
9. exact error attribution.

Failure injection must include:

- missing source;
- permission denial;
- destination collision;
- invalid link target;
- lockfile write failure;
- snapshot write failure;
- Git commit failure;
- network/push failure.

Push failure is the sole post-commit failure that does not roll back the applied local state.

### 23.4 Refresh and inventory tests

Fixtures cover:

- real directories;
- valid and broken links;
- exact copied Skills;
- same-source divergent copies;
- same-name unrelated Skills;
- nested Skill directories;
- externally added Skills;
- externally deleted Skills;
- unknown lockfile fields;
- Managed and Untracked states;
- project/global/custom roots.

Assertions verify that Refresh updates inventory without writes and marks invalid pending inputs correctly.

### 23.5 Differential compatibility tests

CI pins a known Vercel `skills` version.

A differential harness runs equivalent scenarios through:

- the official CLI in an isolated fixture environment;
- the Rust protocol core.

Compare:

- discovered Skills;
- installed directory layout;
- supported agent targets;
- copy/link outcomes;
- global and project lockfiles;
- content hashes;
- remove/update results;
- source parsing;
- error classes where behavior is contractual.

A separate scheduled compatibility job runs against `skills@latest`. A latest-only mismatch reports upstream drift without silently changing the pinned production contract.

### 23.6 Git synchronization tests

Use multiple working clones and a local bare remote to test:

- initial backup;
- Commit and Push;
- Commit Locally;
- startup fetch;
- manual remote check;
- new-device restore proposal;
- independent nonconflicting changes;
- same-Skill conflict;
- rename plus edit;
- Keep Local;
- Use Remote;
- Keep Both;
- restore as a new commit;
- excluded large content;
- missing credentials;
- push rejection.

### 23.7 GPUI tests

UI tests cover critical flows rather than core correctness:

- initial empty state;
- project registration;
- multi-select and range selection;
- Pending Changes review;
- Apply success;
- Apply rollback error;
- Refresh removing a ghost Skill;
- Duplicates workspace;
- update conflict choice;
- Git remote changes;
- exit warning;
- keyboard-only completion;
- light/dark and text scaling smoke tests.

Use component-level state tests where possible. End-to-end automation covers one representative path per critical workflow on all three platforms.

### 23.8 Property and fuzz tests

Apply property-based tests to:

- source parsing;
- path normalization;
- lockfile round trips with unknown fields;
- deterministic hashing;
- operation dependency sorting;
- repository manifest round trips.

Fuzz archive and direct-source parsing wherever the upstream protocol accepts archives or remote payloads.

### 23.9 Performance gates

Test with representative libraries of 100, 1,000, and 10,000 placements.

Targets:

- UI remains responsive during scans and hashing;
- virtualized lists do not render all rows eagerly;
- unchanged file hashes are reused within the same scan generation where safe;
- Refresh progress is visible for long scans;
- selection and filtering remain interactive at 10,000 placements.

Performance optimization must not introduce a persistent cache that becomes a competing source of truth.

## 24. CI and Release Gates

Every pull request runs:

- formatting and linting;
- unit tests;
- planner tests;
- lockfile round-trip tests;
- isolated executor tests appropriate to the runner platform;
- component tests;
- protocol fixture tests;
- dependency and license checks.

Main/release CI runs:

- full macOS, Windows, and Linux executor matrix;
- pinned official CLI differential suite;
- GPUI end-to-end smoke suite;
- Git multi-clone synchronization suite;
- package installation smoke tests;
- artifact signing checks where credentials are available.

Scheduled CI runs:

- `skills@latest` compatibility watch;
- dependency security audit;
- packaging smoke tests.

A 1.0 release is blocked by any known data-loss defect, partial-Apply defect, lockfile incompatibility, unrecoverable rollback failure, ghost Skill after explicit Refresh, or unsupported platform feature gap.

## 25. Security and Privacy

The application sends no product telemetry.

Network access occurs only for user-visible source, marketplace, Git, and release-link workflows defined in this specification.

Credentials remain in operating-system credential storage and never enter logs, manifests, lockfiles, snapshots, or backup repositories.

All filesystem mutations are constrained to explicitly resolved operation paths. Source validation, archive handling, and protocol safety behavior remain aligned with Vercel `skills` rather than a separate application-specific policy.

Exported logs are sanitized by default.

## 26. Packaging and Distribution

The project uses a Rust-native packaging path suitable for GPUI applications on all three supported platforms.

1.0 publishes platform artifacts through GitHub Releases.

The application does not implement self-update. Settings displays the installed version and a link to the Releases page.

Packaging requirements:

- macOS application bundle, signing, and notarization for production distribution;
- Windows signed installer with clean install, upgrade, and uninstall behavior;
- Linux release artifacts appropriate to the selected distribution strategy, with documented desktop integration;
- no Node.js runtime dependency in shipped artifacts;
- no bundled unofficial `npx skills` copy used at runtime.

## 27. Implementation Sequence

The implementation sequence follows dependency order and keeps one production path at each step.

1. Protocol Core and pinned upstream compatibility fixtures.
2. Inventory Core and workspace scanning.
3. Lockfile round-trip preservation and agent registry.
4. Planner and immutable operation model.
5. Snapshot format and Apply Executor transaction behavior.
6. Git backup materialization and local commit.
7. GPUI shell, navigation, Library, and details.
8. Project, Agent, and Custom Workspace surfaces.
9. Marketplace and installation planning.
10. Pending Changes review and Apply UX.
11. Refresh and Unavailable plan handling.
12. Duplicate Engine and Duplicates workspace.
13. Updates and local/upstream diff.
14. Tags and Presets.
15. Git remote connection, fetch, push, restore, and conflict workflows.
16. Activity, settings, diagnostics, accessibility, and keyboard completion.
17. Cross-platform E2E, packaging, and release hardening.

Each completed step removes scaffolding and obsolete alternatives before the next step merges. Feature flags must not preserve parallel permanent implementations.

## 28. Definition of Done

The product is complete for 1.0 when:

1. All supported Vercel `skills` source forms and agent targets in the pinned contract work through the native core.
2. GUI and CLI can alternate without corrupting or losing compatible lock data.
3. No user write occurs outside Apply.
4. Every successful Apply creates one recoverable transaction and one Git commit.
5. Every failed Apply restores its pre-Apply state and creates no commit.
6. Manual Refresh removes ghost Skills and correctly marks invalid plan items.
7. Exact Duplicate, Source Duplicate, and Name Collision detection pass deterministic fixtures.
8. Git backup, remote comparison, push retry, new-device restore, and per-Skill conflicts pass multi-clone tests.
9. Read-only preview and external-editor behavior are complete.
10. All primary flows work by keyboard.
11. macOS, Windows, and Linux pass the same functional acceptance suite.
12. The shipped application has no Node.js runtime requirement.
13. There is one current implementation for each core behavior, with obsolete and defensive duplicate paths removed.
14. Release artifacts install, launch, operate, and uninstall cleanly on all supported platforms.

## 29. Normative References

- Vercel Skills CLI and protocol: `https://github.com/vercel-labs/skills`
- skills.sh: `https://skills.sh`
- GPUI: `https://github.com/zed-industries/zed/tree/main/crates/gpui`
- GPUI Component: `https://github.com/longbridge/gpui-component`

The pinned Vercel `skills` version must be recorded in the repository's dependency/compatibility metadata and updated only through an explicit compatibility change with differential test evidence.
