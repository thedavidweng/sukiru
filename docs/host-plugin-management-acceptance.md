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
| #23 | Native Codex configured-marketplace add/remove. Unsupported operations have explicit instructions. | Curated remote add/remove also change backend state and therefore remain instructions only. No independent enable/disable/update command exists in the verified CLI. |
| #24 | Version-specific v1 capability detection and installation/replacement instructions. | Native execution is deliberately unavailable: the verified v1 command initializes plugins before its handler. Literal native-install acceptance is blocked by ADR-0008's no-plugin-execution policy. |
| #25 | Verified v2 global add/remove with config, payload, data, npm cache/log and temporary-root capture. | List/check/update connect to or start a server and can load plugins; those paths remain instructions only. Native runtime check/update acceptance is blocked by the same policy. |
| #26 | Claude marketplace add/update/remove; final-scope cascade preview/capture includes registered projects outside the Library selection. | Opaque command/header sources refuse automatic execution. |
| #27 | Codex marketplace add/upgrade/remove; local-marketplace update limits and full marketplace granularity are shown. | Curated backend installation changes remain outside filesystem rollback. |

The native management sheet previews operations in shared Pending Changes.
Deletion consequences, scopes, observed versions and capture roots appear in
the reviewed batch. Host failures retain stdout/stderr and partial file diffs;
approval/authentication steps remain in the host, with no assumed automatic
resumption. The UI uses SwiftUI system controls, semantic styles, accessibility
identifiers/help, and English/Simplified Chinese String Catalog entries.

## CLI contract

`scan` includes `pluginInventory` when plugin facts or inspection issues exist.
`plugins capabilities --host claude|codex|opencode` explicitly probes version/help.
`plugins plan --requests FILE` previews an array of requests with `host`,
`action`, `target`, `scope`, and absolute `scopeRoot` fields.
`plugins execute --requests FILE --reviewed` executes only supported plans;
dangerous operations also require `--confirm-dangerous`.
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

- 604 tests in 80 suites pass with Swift compiler warnings treated as errors.
- Native app build, strict Swift formatting, strict SwiftLint, String Catalog
  synchronization/translation checks, and `git diff --check` pass.
- Standards review: no remaining actionable findings. Physical targets and
  ancestor link identities are captured; retargeted links require conflict
  choices. Unchanged links are not rewritten. Post-state errors retain history
  and never silently become an empty diff.
- Spec review: no remaining actionable findings. Local file URL references,
  explicit-reference disable refusal, and declared/conventional component
  semantics have real CLI regression coverage.
- Literal native execution acceptance for #24 and #25 remains blocked by the
  host behavior and ADR-0008 limits described above.
