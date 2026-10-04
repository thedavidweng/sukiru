# 0008: Manage host plugins as independent units without a Sukiru ledger

- Status: Accepted
- Date: 2026-10-03

The user confirmed the complete design summary on 2026-10-03. The following
decisions are agreed product scope, not authorization to modify installed
plugins on the user's machine.

## Decision

Plugin support extends Sukiru's zero-ledger model. An Agent Plugin is a
management unit distinct from an Agent Skill; its components are independently
manageable only where the host exposes that granularity. Treating each bundled
skill as a separate installation would misrepresent the plugin's lifecycle.
Plugin lifecycle and update management use the coding agent's official
interfaces. Sukiru builds health detection and supplies repairs that official
tools do not provide; whether those repairs may write host configuration or
installation records was left open in the initial round and is resolved by
the repair-boundary amendment below.

The first plugin release covers Claude Code, Codex, and both OpenCode v1 and
v2. Later host candidates and installation workflows are researched from
multi-host plugins such as [ponytail](https://github.com/dietrichgebert/ponytail),
including Grok Build, then checked against each host's official interface.
This scope does not imply identical operations across hosts or versions.

User scope and project scope are both included; project discovery uses the
projects already added to Sukiru. Plugin installation identity includes the
host, source, host plugin identifier, and concrete scope, so two projects or
two marketplaces do not collapse into one installation.

Installation entry points are browsing host-configured marketplaces and
entering the addresses or local paths supported by that host's official
interface. Sukiru does not maintain its own plugin catalog. Ponytail is a
workflow validation example and a source of future host candidates, not an
installation protocol authority.

## Evidence for the repair boundary

The [local plugin investigation](../plugin-health-investigation.md) found three
v1-style local plugins rejected by OpenCode v2.0.22. Official package updates
skip local files. This establishes a need for Sukiru's own compatibility
diagnosis, but not a need to rewrite installation records or generically
transform plugin source.

## Amendment (2026-10-03): repair and deletion boundary

ADR-0001 remains unchanged. Sukiru supplies compatibility diagnosis and
prefers verified producer-provided migration interfaces when available; it
does not generically rewrite plugin source or directly write host installation
records or configuration. Official lifecycle writes remain with the host.

For incompatible local files that the host cannot disable through an official
interface, Sukiru may offer an explicitly confirmed, snapshot-protected file
operation that moves them outside automatic discovery. The result is labeled
disabled; it does not claim to restore the plugin's behavior. This local-file
policy is specific to plugins and does not broaden ADR-0007's repair policy
for agent-managed skills.

Deletion is also offered and dispatched through the agent host's native
management interface. If that interface cannot delete the particular plugin,
Sukiru reports the capability limit; direct deletion is not implied by the
local-file disable exception. OpenCode's global package removal command must
not be presented as deleting an automatically discovered local plugin file.

## Product presentation

Library offers Skills and Plugins views within the same user and project
scopes. Plugins can be filtered by host; component inventories appear in
plugin details and respect the host's management granularity. Health, Pending
Changes, and Snapshots remain shared product surfaces.

## Amendment (2026-10-03): preserve file snapshot and rollback guarantees

Plugin commands retain the existing snapshot -> execute -> file diff ->
rollback sequence. Extend capture bounds for each host operation to include
its affected configuration, installation records, plugin payloads, caches,
and data files. Capture must complete before execution; a failure to back up
an in-scope file prevents the command batch from running. File-backed options
or secrets are not inherently excluded from restoration.

Snapshot restoration restores captured state rather than implementing an
installation protocol, as in the existing skill rollback path. Existing
skill-specific capture bounds are not sufficient for plugin commands.
Effects outside the captured filesystem are governed by the explicit-effects
consent amendment below. They do not weaken restoration of captured files.

## Amendment (2026-10-03): state evidence and rollback conflicts

Present installation, configured enablement, and evidenced load status
separately. Missing runtime evidence means unknown, not successfully loaded.
The first plugin release does not monitor every host session. Historical
load errors retain their context and do not alone establish current failure.

Before restoring a file, detect changes made since the command batch's
post-execution state. Show conflicts and let the user choose snapshot
restoration or preservation of the current file; do not automatically merge
host configuration. This extends the current rollback behavior, which restores
captured bytes without checking for later edits. Newly created paths likewise
must be attributed to the batch rather than assumed to be batch-created solely
because they were absent from the pre-execution snapshot.

## Amendment (2026-10-03): leave trust approval to the host

Plugin trust and execution approvals remain in the coding agent's native
workflow. Sukiru does not recreate an approval dialog, accept commands on the
user's behalf, or bypass the host's confirmation requirement. If an official
operation requires approval, report that the operation has not completed and
direct the user to handle it in the host when they next open it. Refresh reads
the resulting host state afterwards.

Do not assume that a refused CLI operation creates a pending request or will
resume automatically in the host; communicate the next step supported by that
host's official workflow. This approval boundary is distinct from Sukiru's
existing confirmation of a command batch and its local file operations.

## Amendment (2026-10-03): invocation and refresh policy

Sukiru invokes official host interfaces. It does not automatically execute
plugin-author installation or migration scripts. Author commands requiring
host trust approval remain in that host's review workflow; Sukiru does not
accept or bypass those approvals. No plugin-specific migration implementation
is added.

Startup reads local state. Official refresh and remote update checks are
explicit user actions; a completed or failed mutation is followed by a local
rescan and file diff. There is no scheduled network activity. Operations that
start a host session or run plugin code remain separate from passive inventory
and require the effects consent described below when they may affect results.

## Amendment (2026-10-03): permit execution with explicit effects consent

The user revised the boundary: execution is permitted when it does not affect
results; operations that may affect results are also permitted with the user's
explicit consent. Starting a host or loading plugin code is not, by itself,
a reason to prohibit an official operation. Unknown runtime effects are not
assumed harmless.

For official operations that may run plugin code, change uncaptured files, or
mutate backend state, show the exact command, selected scope, intended change,
known effects and file rollback limits before execution. Require explicit
consent for that batch. Merely opening Sukiru, scanning, requesting a preview,
or previously consenting to a different batch does not supply consent.
Host trust and authentication approvals still remain with the host.

OpenCode v1 native installation/force replacement and v2 runtime list/check/
update are eligible under this rule. Codex curated remote add/remove are also
eligible when the user agrees to backend installation changes. Capture all
known affected host/config/package/cache/data files before execution and retain
the transcript and post-state after success or failure. Backup failure still
prevents execution. Persist the approved limits in history: file rollback
restores captured files, but does not undo arbitrary plugin effects, running
services, or backend installation state. Do not describe file rollback as a
complete reversal of these operations.

## Amendment (2026-10-03): marketplace and update scope

The first release offers browsing, adding, refreshing, and removing marketplaces
where the host provides an official management interface. If marketplace removal
also uninstalls plugins, the command-batch confirmation lists the affected
installations. Unsupported host operations remain explicit capability limits.

Updates follow the host's actual operation granularity and version-lock rules.
Confirmation states whether the operation affects one plugin, a marketplace,
or a wider set; a bulk update is not presented as a single-plugin action.
The first release adds no version-lock editing or downgrade feature. Rollback
continues to restore captured files rather than asking the host to downgrade.
