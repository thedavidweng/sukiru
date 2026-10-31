# Host plugin management acceptance evidence

Parents: [#14](https://github.com/thedavidweng/sukiru/issues/14) and
[#31](https://github.com/thedavidweng/sukiru/issues/31).
Interface evidence: [verified host interfaces](host-plugin-interface-evidence.md).
Policy: [ADR-0008](adr/0008-host-plugin-management.md).

The implementation uses host-owned configuration and installation records,
the existing reviewed batch executor, and captured filesystem state. It adds
no installation ledger. Startup scanning invokes no host executable, fetches
no remote catalog, and runs no plugin or producer code. Installed, configured,
and runtime-loaded status remain separate; runtime status is unknown.

## Ticket coverage

| Ticket | Implemented path and evidence | Capability limits |
| --- | --- | --- |
| #15 | Post-execution file identities; restore/preserve choices; CLI preview and native conflict sheet. Rollback CLI/generic tests cover later edits, additions, deletions, empty directories, dangling links, linked roots and backup refusal. Execution transcripts persist before post-state capture; incomplete evidence requires explicit recovery choices and preserves unknown paths. | Non-filesystem backend state cannot be restored. |
| #16 | Claude passive user/project/local installation identities, local catalogs, components and settings precedence. Passive CLI fixtures verify no host invocation. | Managed enablement and current runtime loading remain unknown. |
| #17 | Codex explicit user/project declarations, active cache version selection, local catalogs and manifest precedence. Cache and symlink CLI fixtures prevent false installation/component claims. | Project trust and managed/profile layers are not inferred from declarations. |
| #18 | OpenCode v1/server/CLI configuration declarations, JSONC, custom/inline config, local discovery and scope identities. CLI fixtures cover precedence, local `file://` references and malformed input. | Without an explicit version probe, declarations are labelled by configuration generation; discovered runtime enablement remains unknown. |
| #19 | Static named async factory diagnosis, including TypeScript annotations; historical log evidence is labelled historical. Explicit v2-only local disable moves outside discovery, previews migration instructions and uses conflict-aware rollback. | Does not migrate code or restore behavior. Explicit or alternate references refuse a move. |
| #20 | Claude enable/disable plans include exact scope and complete captured roots. Substitute CLI tests cover success, approval refusal, partial effects and rollback. | Exact verified version/help gating; no config writer or approval bypass. |
| #21 | Claude catalog-selector install; separate official marketplace acquisition for supported source addresses. | Producer command sources and headersHelper sources are instructions only. |
| #22 | Native Claude update/uninstall, pin rejection, deletion impact and protected execution. | No producer scripts or automatic pin changes. |
| #23 | Native Codex configured-marketplace and curated remote add/remove. Curated operations require explicit backend-effects consent and preserve limits in history. | File rollback cannot reverse backend state. No independent enable/disable/update command exists in the verified CLI. |
| #24 | Verified v1 install and explicit force replacement in user/project scopes, with snapshot protection and batch-specific runtime-effects consent. CLI fixtures verify native argv, consent refusal, history and file recovery. | Initialization can run plugin code; effects outside captured files are disclosed and not claimed reversible. No native removal exists. |
| #25 | Verified v2 global add/remove and explicit runtime list/check/update in user/project scopes. Known config, payload, data, npm cache/log and temporary roots are captured. CLI fixtures cover consent refusal, preview isolation, failure diff and file recovery. | Runtime operations can start/connect to a server and load plugins; explicit consent is required. Exact locks/local update exclusions remain host-owned. |
| #26 | Claude marketplace add/update/remove; final-scope cascade preview/capture includes registered projects outside the Library selection. | Opaque command/header sources refuse automatic execution. |
| #27 | Codex marketplace add/upgrade/remove; local-marketplace update limits and full marketplace granularity are shown. | Curated backend installation changes require explicit consent and remain outside filesystem rollback. |

Skills and Plugins are separate sidebar destinations (stories 1 and 6): the
Library toolbar is unchanged, and each agent row in the Agents section
(Claude Code, Codex, OpenCode, Cursor, and the rest) holds its own Plugins
destination with its own count, beside its Skills, Hooks, Extensions, and MCP
Servers. Users choose which agents the section shows and their order in
Sidebar settings (a native reorderable list with a switch per agent, plus Move
Up/Down in the row menu), or with Move Up/Down in the sidebar row menu. The sidebar
itself does not drag: the system drag image of a vibrant sidebar row renders
black in Dark Mode. A host's list groups
User Library and each added project (stories 7 to 9) and shows only that
host's inspection issues. Rows carry an enablement switch where the host
toggles plugins, plus inline update, local-disable and remove buttons; the
context menu and detail form offer the remaining operations. Every control
opens a reviewed preview. Row, menu and management-sheet actions are limited
to the host's operation families; version and scope limits still come from the
reviewed preview (stories 22 and 29).

The native management sheet previews operations in shared Pending Changes.
Deletion consequences, scopes, observed versions and capture roots appear in
the reviewed batch. Host failures retain stdout/stderr and partial file diffs;
approval/authentication steps remain in the host, with no assumed automatic
resumption. The UI uses SwiftUI system controls, semantic styles, accessibility
identifiers/help, and English/Simplified Chinese String Catalog entries.

## CLI contract

`scan` includes `pluginInventory` when plugin facts or inspection issues exist;
each inventory issue names the `host` whose files produced it.
`plugins capabilities --host claude|codex|opencode|cursor` explicitly probes version/help.
`plugins plan --requests FILE` previews an array of requests with `host`,
`action`, `target`, `scope`, and absolute `scopeRoot` fields.
OpenCode v1 uses `install` or explicit `replace` (`--force`), with user scope
mapping to `--global` and project/local scope to the host's actual configuration
directory. Git subdirectories capture the worktree-root `.opencode`, which is
shown in the preview. OpenCode v2 `list`, `check`, and `update` are explicit
runtime operations; target `*` omits the optional target and includes all
packages in the selected runtime. A specific check/update target is passed
unchanged, preserving native exact-version and full-commit locks.
`plugins execute --requests FILE --yes` executes only supported plans;
destructive operations and runtime/backend effects also require `--confirm-dangerous`.
This acknowledges the disclosed effects and file rollback limits for that batch.
The shared executor independently refuses effects-bearing batches without consent.
Instructions-only plans do not execute a partial batch.

`rollback ID --dry-run` lists conflicts. Repeated `--restore PATH` and
`--preserve PATH` resolve them explicitly; unrelated later additions support
preservation only. Unresolved conflicts mutate nothing.

If post-execution file evidence fails, history retains the command transcript
and the exact evidence error. Recovery requires an explicit choice for each
captured file or link. It restores only selected snapshot entries, never
deletes unknown additions, and refuses to replace directories containing
unknown children. A failed semantic rescan retains the completed file diff.

Validation uses temporary homes, substitute host executables and the real CLI
scan/plan/execute/diff/rollback boundary. No actual host plugins were changed.

Component fixtures include custom manifest paths, mixed file/inline config
arrays, and conventional hook/MCP/LSP files. Commands and agents replace
their default directories when declared, following the official
[manifest merge rules](https://code.claude.com/docs/en/plugins-reference#how-each-key-combines-with-its-default-location).
Conventional `.lsp.json` accepts the direct server-name map documented under
[LSP servers](https://code.claude.com/docs/en/plugins/components#lsp-servers).

## Parent acceptance closeout (2026-10-25)

The complete bodies and comments of #14 and #31 were reviewed against the
implementation and existing contract tests. #14's first-generation host scope
is complete; Cursor is evaluated separately below under #31 and ADR-0008's
Cursor amendment. No additional lifecycle writer or dependency is required.

| #14 stories | Acceptance evidence | Result and limits |
| --- | --- | --- |
| 1–12 | `PluginLibraryView` separates hosts and groups concrete scope roots; `PluginCLIIntegrationTests.claudeInventory`, `.codexInventory`, and `.openCodeInventory` cover passive host/source/scope identity. `PluginInventoryComponentCLIIntegrationTests` covers bundled components. | Implemented. Components remain plugin evidence rather than standalone Skill ownership. |
| 13–15, 30–33, 44 | Inventory retains separate enablement/load evidence. `sourceShapeContext` and `openCodeInventory` distinguish static incompatibility, historical errors, and valid definitions. `PluginLifecycleCLIIntegrationTests.localDisableRoundTrip` and `.localDisableCaptureFailure` cover reversible explicit local disable. | Implemented. No plugin execution, runtime-success inference, code migration, or automatic author-script execution. |
| 16–29 | `ClaudePluginLifecycleCLIIntegrationTests.nativeRoutes`, `.roundTrip`, `.versionLock`, `.removeImpact`, and `.marketplaceScopes`; equivalent Codex route/round-trip/refusal/impact tests; `PluginEffectsCLIIntegrationTests.v1Installation`; `PluginRuntimeCLIIntegrationTests.runtimeOperation`; `PluginLifecycleCLIIntegrationTests.marketplaceCascade`. | Implemented through official host commands. Unsupported sources, scopes, operations and locks produce explicit limits; runtime/backend effects require consent. |
| 34–43 | `PluginLifecycleCLIIntegrationTests.authorCommand`, `.captureFailure`, and `.executionRoundTrip` cover approval boundaries, refused capture and post-failure diff/restore. Shared rollback tests cover later edits and restore/preserve choices; #15 evidence above remains applicable. | Implemented. No automatic approval/resume, config merge or claim to reverse external backend/runtime effects. |
| 45 | Shared SwiftUI Library, management, confirmation, Health, history and rollback controls use native system presentation and localization. `SukiruUITests` supplies a native plugin flow through these same shared surfaces. | Implemented; actual Cursor scenario execution is recorded separately from source inspection below. |

| #31 stories | Acceptance evidence | Result and limits |
| --- | --- | --- |
| 1–10, 14–18, 39–40 | `PluginInventoryReader+Cursor` recognizes both manifest formats, local discovery, cache versions and containment; `CursorPluginCLIIntegrationTests.localInventory` and `.cacheAndContainment` cover passive scanning, distinct identities, malformed manifests, contained/escaping links and cached-only Unknown state. | Implemented with the ADR-0008 evidence limit: uncalibrated SQLite state is not read. Cache alone proves neither installed project scope nor marketplace precedence, enablement or runtime loading. Same-name local/cache evidence remains separate. |
| 11–13 | `PluginInventoryReader+CursorComponents`; `.declaredComponents`, `.rootSkillDiscovery`, `.unreadableComponents` and `.localInventory` contract fixtures. | Rules, skills, MCP, agents, commands, hooks and variable names/schema metadata are inspected without executing commands or exposing variable defaults/secret values. |
| 19–20 | `PluginInventoryReader+CursorCatalogs` and `.marketplaceInventory` expose cached catalog provenance and Git ref. Explicit planning uses official structured registrations rather than cache names. | Cached catalog registration/scope stays Unknown. Official `user`, `team` and `global` registrations determine mutability only after explicit host listing. |
| 21–30 | `PluginLifecyclePlanner+Cursor`; `CursorPluginLifecycleCLIIntegrationTests.marketplacePlan`, `.marketplaceRoutes`, `.duplicateMarketplaceAdd`, `.ambiguousRegistrations`, `.executionFailure`, `.invalidStructuredOutput`, `.missingStructuredCapability`, and `.refreshObservation`. | Personal add/update/remove use verified `agent` help, exact argv, consent, capture/diff/rollback and post-state diagnostics. Team/global mutations and ambiguity are refused; file rollback cannot reverse account sync or server indexing. Exit zero with no local advance is reported as no observable change. |
| 31–38 | `.unsupportedOperations` covers install/remove/enable/disable/update; `.projectInstallInstructions` verifies the selected project reaches Customize and interactive `/plugin` instructions. `cursorLimitation` explicitly distinguishes marketplace refresh from plugin update. | Implemented as required host instructions, followed by explicit Sukiru refresh. These are acceptance-specified capability limits, not missing lifecycle implementation. No cache or SQLite writer is added. |
| 41–43 | `CursorLocalDisable.command` and `.validate`; `.localDisableRoundTrip` and `.localDisableBoundary` cover physical local directories, later-edit restoration, cache rejection and alias rejection. | Explicit snapshot-protected move from `~/.cursor/plugins/local` to `~/.cursor/plugins/disabled-local/<UUID>/…`; rollback restores captured state. No host-managed cache move. |
| 44–48 | `PluginHost.cursor.executable` routes to `agent`; `.capabilitiesAndIdentity` rejects another product named `agent` and verifies help-driven operation availability. Product CLI fixtures exercise Cursor list/health/capabilities/marketplaces and dry-run planning. | Implemented. Auto-updating build strings do not replace installed-help verification; unverified aliases are not selected. |
| 49–54 | Existing host sidebar ordering/hiding and shared plugin views include Cursor. ADR-0008 Cursor amendment records the boundary; standalone Hook policy stays under ADR-0010. `testCursorPluginInventoryAndMarketplacePreviewStayHostOwned` covers the native Cursor row, local rules, cached/Unknown distinctions, unavailable update/toggle actions, catalog Git ref and reviewed marketplace argv/effects consent. | Implemented using the existing native UI architecture. Native scenario uses a temporary HOME and bundled command substitute; it cancels the preview and asserts no marketplace add executed. |

The 2026-10-05 comments' three remaining concerns are resolved as follows:

- **Homebrew cask:** read-only GitHub inspection found the published
  [tap cask at revision `95ce2f5`](https://github.com/thedavidweng/homebrew-tap/blob/95ce2f5fa627aee2425eb3490b8d6649be066661/Casks/sukiru.rb).
  It declares version `1.7.0`, the GitHub release DMG, `Sukiru.app`, and the
  bundled `Contents/Helpers/sukiru` binary link. This matches README installation
  instructions. No external repository was changed and no brew installation or
  release-artifact verification was performed in this review.
- **UI test infrastructure:** `project.yml` now declares the macOS
  `SukiruUITests` target and bundles `SukiruUITests/Fixtures/bin/agent`.
  The integration owner's `xcodebuild test` run completed with exit 0
  on 2026-10-25 at 13:34:37 after 51.272 seconds; its result summary confirms
  the actual Cursor scenario passed (1/1). The scenario previews host-owned
  commands using isolated fixtures and cancels before mutation.
- **Cursor host limits:** #31 explicitly requires instructions for unsupported
  individual lifecycle operations and Unknown for uncalibrated state. The
  implementation and regression fixtures enforce those outcomes. A new
  Cursor non-interactive plugin API or private state-store calibration is not
  a prerequisite for closing this specification.

## Final verification

- The final integrated run passed 759 tests in 104 suites with Swift compiler
  warnings treated as errors, including pinned real pnpm lifecycle coverage.
- The integration owner also reports a native app build, strict formatting,
  strict SwiftLint, localization checks and `PnpmUITests` passing.
- The actual native Cursor UI test
  `SukiruUITests.testCursorPluginInventoryAndMarketplacePreviewStayHostOwned`
  passed (1/1), confirmed by the result summary. After regenerating the Xcode
  project, `LibraryLayoutUITests` separately passed (1/1) with a screenshot proving
  long descriptions stay above Owner/Scope; `PnpmUITests` also passed (1/1).
  The result bundles contain existing SwiftUI/runtime diagnostics (publishing
  changes during view updates and thread/QoS warnings); these are not represented
  as warning-free runtime execution. No compiler warning was accepted by the
  Swift test gate.
- The following standards/spec/effects review findings are retained from the
  earlier implementation evidence; this closeout did not rerun those checks.
- Standards review: no remaining actionable findings. Physical targets and
  ancestor link identities are captured; retargeted links require conflict
  choices. Unchanged links are not rewritten. Post-state errors retain history
  and never silently become an empty diff.
- Spec review: no remaining actionable findings. Local file URL references,
  explicit-reference disable refusal, and declared/conventional component
  semantics have real CLI regression coverage.
- Effects-consent review fixes cover repeated disclosure row identities,
  actual Git worktree configuration targets, and preservation of approved
  runtime/backend limits after file rollback. Native history exposes captured
  command output files. Consent refusal leaves files untouched; backup failure
  prevents execution even after consent.
- The later explicit-effects consent amendment removes the policy blockers
  for #24 and #25. Execution uses verified official commands, protects known
  captured files, and discloses effects that file restoration cannot undo.
