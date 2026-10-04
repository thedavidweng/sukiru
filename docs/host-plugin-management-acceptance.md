# Host plugin management acceptance evidence

Parent: [#14](https://github.com/thedavidweng/sukiru/issues/14).
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
Library toolbar is unchanged, and the Plugins section lists Claude Code,
Codex, and OpenCode separately with their own counts. Users choose which hosts
the section shows and their order in General settings (a native reorderable
list with a switch per host, plus Move Up/Down in the row menu), or with Move Up/Down in
the sidebar row menu. The sidebar
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
`plugins capabilities --host claude|codex|opencode` explicitly probes version/help.
`plugins plan --requests FILE` previews an array of requests with `host`,
`action`, `target`, `scope`, and absolute `scopeRoot` fields.
OpenCode v1 uses `install` or explicit `replace` (`--force`), with user scope
mapping to `--global` and project/local scope to the host's actual configuration
directory. Git subdirectories capture the worktree-root `.opencode`, which is
shown in the preview. OpenCode v2 `list`, `check`, and `update` are explicit
runtime operations; target `*` omits the optional target and includes all
packages in the selected runtime. A specific check/update target is passed
unchanged, preserving native exact-version and full-commit locks.
`plugins execute --requests FILE --reviewed` executes only supported plans;
destructive operations and runtime/backend effects also require `--confirm-dangerous`.
This acknowledges the disclosed effects and file rollback limits for that batch.
The shared executor independently refuses effects-bearing batches without consent.
Instructions-only plans do not execute a partial batch.

`rollback ID --preview` lists conflicts. Repeated `--restore PATH` and
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

## Final verification

- 610 tests in 84 suites pass with Swift compiler warnings treated as errors.
- Native app build, strict Swift formatting, strict SwiftLint, String Catalog
  synchronization/translation checks, and `git diff --check` pass.
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
