## Problem Statement

Sukiru users manage Agent Skills alongside Agent Plugins in Claude Code, Codex,
and OpenCode, but cannot inspect or manage plugins through Sukiru. Host state,
installation scope, configured enablement, and runtime loading are easy to
confuse. A concrete local example is three v1-style OpenCode plugins rejected
by OpenCode v2: the host's package update commands cannot migrate those local
implementations.

Users need native plugin management and actionable health diagnosis without
introducing a Sukiru installation ledger, duplicating host installation
protocols, or weakening file snapshot and rollback guarantees.

## Solution

Add a Plugins view alongside Skills in Library, covering Claude Code, Codex,
and OpenCode v1 and v2 in user scope and already-added projects. Show each
Plugin Installation independently, with its host, source, scope, components,
configured enablement, and evidenced load status. Route supported lifecycle
and marketplace operations through the host's official interface, and explain
unsupported operations precisely.

Sukiru supplies health diagnosis that the host does not provide. Incompatible
local files can be explicitly disabled by moving them out of automatic
discovery with snapshot protection. Deletion uses the host's native management
capability. Trust approval remains in the coding agent. Every mutation retains
the snapshot, execution, file diff, and rollback workflow, with explicit
resolution of changes made after the batch.

## User Stories

1. As a Sukiru user, I want to switch between Skills and Plugins in Library, so that I can manage both without confusing their identities.
2. As a Sukiru user, I want to inspect Claude Code plugins, so that I can see that host's installed extensions.
3. As a Sukiru user, I want to inspect Codex plugins, so that I can see that host's installed extensions.
4. As an OpenCode v1 user, I want version-appropriate discovery and commands, so that support does not assume the v2 interface.
5. As an OpenCode v2 user, I want version-appropriate discovery and commands, so that legacy configuration and plugins are interpreted accurately.
6. As a Sukiru user, I want to filter plugins by host, so that unrelated installations remain easy to distinguish.
7. As a Sukiru user, I want user-scope plugins separated from project-scope plugins, so that I know where a change applies.
8. As a Sukiru user, I want plugins in already-added projects to be discovered, so that project management uses the existing project list.
9. As a Sukiru user, I want installations in different projects or marketplaces to remain distinct, so that identical names do not collapse into a false conflict.
10. As a Sukiru user, I want to inspect a plugin's source and reported version, so that I can understand its provenance without Sukiru inventing installation records.
11. As a Sukiru user, I want to inspect bundled components in plugin details, so that I can see the skills and other components it supplies.
12. As a Sukiru user, I want component management to respect the host's supported granularity, so that deleting a skill does not unexpectedly remove its plugin.
13. As a Sukiru user, I want installation, enablement, and load status displayed separately, so that enabled does not misleadingly mean running.
14. As a Sukiru user, I want missing runtime evidence shown as unknown, so that Sukiru does not claim unverified loading success.
15. As a Sukiru user, I want historical load errors identified as historical, so that old logs do not imply current failure.
16. As a Sukiru user, I want to browse configured marketplaces, so that I can discover plugins using the host's catalogs.
17. As a Sukiru user, I want to add a marketplace through supported host commands, so that its state remains owned by the host.
18. As a Sukiru user, I want to refresh a marketplace explicitly, so that I control when remote information is fetched.
19. As a Sukiru user, I want to remove a marketplace through the host, so that Sukiru does not duplicate its removal protocol.
20. As a Sukiru user, I want marketplace removal to disclose dependent plugin removals, so that I can assess the full impact before confirming.
21. As a Sukiru user, I want to enter supported repository or package addresses and local paths, so that installation is not limited to marketplace browsing.
22. As a Sukiru user, I want unsupported installation sources or scopes explained, so that Sukiru does not silently substitute another operation.
23. As a Sukiru user, I want to install plugins through the official host interface, so that installation records remain authoritative.
24. As a Sukiru user, I want to check for updates explicitly using supported official operations, so that Sukiru does not implement a competing updater.
25. As a Sukiru user, I want update confirmation to state its actual plugin or marketplace scope, so that a bulk update is not disguised as a single-plugin change.
26. As a Sukiru user, I want host version locks respected, so that an update does not silently replace a pinned version.
27. As a Sukiru user, I want to enable or disable plugins where the host supports it, so that the host remains responsible for lifecycle state.
28. As a Sukiru user, I want to delete plugins through native host capabilities, so that uninstall semantics remain those of the official manager.
29. As a Sukiru user, I want unavailable native deletion clearly explained, so that deleting configuration is not mistaken for deleting an automatically discovered local file.
30. As a Sukiru user, I want incompatible local plugins diagnosed without running them, so that inspection itself does not trigger their behavior.
31. As a Sukiru user, I want an incompatible local plugin moved out of discovery after explicit confirmation, so that I can stop its load errors without modifying its implementation.
32. As a Sukiru user, I want local-file disable described as stopping loading, so that I do not mistake it for restoring functionality.
33. As a Sukiru user, I want verified author migration instructions when relevant, so that I can restore an integration through its producer without Sukiru maintaining custom migrations.
34. As a Sukiru user, I want trust approvals handled in my coding agent, so that I use the official approval flow.
35. As a Sukiru user, I want approval-blocked operations shown as incomplete, so that Sukiru does not claim installation succeeded or will automatically resume.
36. As a Sukiru user, I want shared Health and Pending Changes surfaces, so that plugin diagnosis and changes follow familiar workflows.
37. As a Sukiru user, I want all affected files captured before a plugin mutation, so that I can restore configuration, records, payloads, caches, and data.
38. As a Sukiru user, I want execution prevented when complete capture fails, so that a backup failure cannot become an unprotected mutation.
39. As a Sukiru user, I want post-execution scanning and file differences even after command failure, so that partial changes remain visible.
40. As a Sukiru user, I want rollback to restore captured bytes and links and remove batch-created paths, so that I can undo the actual filesystem change.
41. As a Sukiru user, I want conflicts with later edits presented before restoration, so that another tool's changes are not overwritten without my decision.
42. As a Sukiru user, I want to choose snapshot restoration or current-file preservation for conflicts, so that Sukiru does not guess how to merge host configuration.
43. As a Sukiru user, I want changes applied by the host to appear after refresh, so that Sukiru stays an observer of authoritative state.
44. As a Sukiru user, I want startup inspection to remain local and passive, so that opening Sukiru does not start host sessions or perform remote checks.
45. As a macOS user, I want plugin management to use native system controls and appearance, so that the extension feels consistent with the app and platform.

## Implementation Decisions

- Preserve the zero-ledger and pure Swift, Apple-framework constraints. Lifecycle writes use supported official host interfaces; no direct installation-record or host-configuration protocol writer is added.
- Introduce a plugin model and read/lifecycle boundary alongside the existing skill model. Do not encode plugins as additional Skill Ownership cases or merge components into standalone skill installations.
- Plugin Installation identity includes host, source, host identifier, and concrete scope. Cache presence alone establishes neither installation nor effective loading.
- Use capability detection appropriate to each installed host version and operation. Claude Code, Codex, OpenCode v1, and OpenCode v2 have different official surfaces; lack of an operation is a capability limit, not a reason to emulate it.
- The observed baseline includes Claude plugin CRUD, update and enable/disable; Codex plugin add/list/remove and marketplace commands; OpenCode v1 plugin installation and force replacement; OpenCode v2 global package CRUD and update checks. Revalidate installed-version behavior during implementation.
- Do not depend on official experimental methods that explicitly prohibit production-client use. The existence of an app-server method alone does not establish a production integration contract.
- Keep passive local inventory separate from explicit official refresh and remote update checks. No scheduled network activity or runtime/plugin execution during passive startup inspection. Explicit official runtime checks may execute after batch-specific consent to their effects and rollback limits.
- Add per-host Plugins destinations beside the Skills Library, with common user/project scope grouping, host-specific operations, and component details. Reuse Health, Pending Changes, and Snapshots.
- Browse, add, refresh, and remove marketplaces where supported. Use host-supported address and local-path inputs; do not create an independent plugin catalog.
- Respect official update granularity and locking rules. Disclose actual command impact, including marketplace removal cascades.
- Retain native deletion semantics and native enable/disable where available. For incompatible local files without an official disable interface, permit only explicitly confirmed, snapshot-protected moves outside discovery. Define the destination and restore behavior from verified discovery boundaries during implementation; do not create a new lifecycle ledger to track them.
- Author installation or migration commands requiring native trust approval remain in the host review workflow; Sukiru does not automatically accept them. Do not add plugin-specific migrations or generic JavaScript/TypeScript transformations.
- Preserve command-batch confirmation. Leave plugin trust/execution approvals to the host; do not auto-accept or recreate the approval UI. Report incomplete operations and supported next steps without inventing an automatic pending/resume mechanism.
- Extend file snapshot bounds per operation to capture affected configuration, installation records, payloads, caches, and data. File-backed options and secrets are not inherently excluded. Capture failure blocks execution.
- Retain serialized execution and first-error stopping behavior; subsequent commands remain not run. Rescan and calculate file differences after success or failure.
- Rollback restores captured state, not a reimplemented installation protocol. Compare current state against the batch's recorded post-execution state to expose later modifications; users choose restoration or preservation without automatic configuration merging. Attribute created paths to the batch before deleting them.
- Preserve existing skill behavior and regression coverage. Snapshot protection changes needed for plugin support must not make later user-created skill placements eligible for silent deletion.
- Treat historical errors and runtime observations as contextual evidence. Do not classify valid inline manifests, disabled plugins, same-name cross-host installations, or unreferenced cache versions as corruption without supporting evidence.

## Testing Decisions

- Prefer the existing CLI end-to-end contract seam, using isolated temporary filesystem trees and official-command substitutes, to exercise inventory, planned commands, execution, snapshot, diff, and rollback together. Test observable reports, command arguments, exit/result states, and filesystem outcomes rather than provider internals.
- Prior art includes the existing CLI integration, batch execution, rollback integration, fixture-corpus, and tree-checksum suites. Extend those facilities rather than introducing a second orchestration test framework.
- Cover all four host/version paths, user/project identity, marketplace/source distinctions, unknown load status, and unsupported operations. Verify that scanning starts no host session and invokes no plugin code.
- Cover official lifecycle routing, scope arguments, update impact and pinned/local skips, approval refusal, cascading marketplace removal, and first-error stopping with post-failure differences.
- Reproduce the local v1-plugin/v2-host incompatibility with minimal load-definition fixtures. Include valid v2 definitions and contextual official-manifest cases to prevent false positives. Do not execute untrusted fixture plugins to establish diagnosis.
- Verify byte-exact capture and restore of config, records, payloads, data, links, absent paths and batch additions. Snapshot failure must leave the command substitute uninvoked and host state unchanged.
- Exercise rollback conflicts after external modification, creation and deletion: restoration and preservation choices must produce the selected filesystem result, and unrelated later additions must survive. No configuration auto-merge is expected.
- Keep UI verification focused on Library selection, scopes, host filters, status distinctions, consequences and conflict choices. Follow repository formatting, lint, and native-interface gates.
- The user confirmed this test seam before publication on 2026-10-03.

## Out of Scope

- A Sukiru installation ledger, cross-host synchronization, or an independent plugin catalog.
- Direct host configuration or installation-record mutation protocols, beyond restoring captured files during rollback.
- Generic plugin-source migration, plugin-specific porting, or automatic execution of author scripts.
- Automatic trust acceptance, mirrored host approval dialogs, or host UI automation.
- Continuous runtime-session monitoring, background update checks, or unapproved plugin execution for health inspection.
- Additional version-lock editing or downgrade features. Snapshot rollback remains included.
- First-release hosts beyond Claude Code, Codex, and OpenCode v1/v2.
- Repairing the user's existing local plugins as part of implementing or publishing this specification.

## Further Notes

The complete design was confirmed by the user on 2026-10-03 and is recorded in
ADR-0008. ADR-0001 remains unchanged. The local investigation found v1-style
VibeUsage, Muxy, and RTK plugins rejected by OpenCode v2, not installation-record
corruption requiring a new write protocol.

Future host candidates and installation workflows should be researched from
mature multi-host plugins such as [ponytail](https://github.com/dietrichgebert/ponytail),
including Grok Build, then verified against each host's official capabilities.
Ponytail is a validation example, not the authority for host protocols.

Official reference baselines: [Claude plugin CLI](https://code.claude.com/docs/en/plugins/cli-reference),
[Codex plugin CLI source](https://github.com/openai/codex/blob/main/codex-rs/cli/src/plugin_cmd.rs),
[OpenCode v1 command](https://github.com/anomalyco/opencode/blob/v1.18.34/packages/opencode/src/cli/cmd/plug.ts),
[OpenCode v2 plugins](https://opencode.ai/v2/docs/plugins), and
[OpenCode v1 migration](https://opencode.ai/v2/docs/build/plugins/migrate-v1).
