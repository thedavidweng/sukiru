# 0014: Native-first management, documented-config writes and bounded history

- Status: Accepted
- Date: 2026-10-25
- Amends: [0008](0008-host-plugin-management.md), [0010](0010-agent-hook-hygiene.md)

## Context

Sukiru's goal is one management surface for Skills, Plugins and Hooks across
every supported coding agent, with the same freedom the user has inside each
host and better visibility. ADR-0008 forbade every direct configuration write
and ADR-0010 limited hooks to removal. That left Codex plugins with a dimmed
switch although Codex itself toggles them with one documented `config.toml`
key, and left hooks with no way to add, edit or pause a handler.

Snapshots kept a fixed count of ten and execution records were never pruned,
so stored history could only grow.

## Decision

Writes follow a fixed preference order:

1. **Native interface.** When the host offers an official command for the
   operation, Sukiru runs that command through the existing Command Batch
   pipeline. This remains the default and is never bypassed for a
   configuration edit.
2. **Documented configuration key.** When the host has no command but
   documents the configuration file and key that controls the state, Sukiru
   may edit that key directly. The edit is limited to the documented key or
   entry, preserves every unrelated byte, checks the scanned content hash
   before snapshot capture and again immediately before writing, and runs
   through the same review, snapshot, diff and conflict-aware rollback as a
   native command. Unsupported representations (duplicate keys, unparseable
   values, unknown layouts) produce an inspection Problem instead of an
   approximate edit. Managed-policy sources stay read-only.
3. **Instructions.** Undocumented internal state (for example Cursor's
   SQLite state store), host installation records and plugin source are never
   written. Sukiru shows the current evidence, why it cannot change it, and
   how to change it in the host.

Rule 2 replaces ADR-0008's prohibition on writing host configuration and
broadens ADR-0010's removal-only exception: documented hook definitions may be
added, edited or removed under the same guarantees. The local-file disable
exception, trust boundaries, effects consent and the zero-ledger rule of
ADR-0001 are unchanged. Sukiru still keeps no lifecycle registry; any value it
needs to restore later lives in the host's own file or in the snapshot.

Every list row states why a control is absent. A plugin whose enablement the
host does not expose shows its evidenced status (for example a cached Cursor
payload) and where to manage it, rather than a blank row.

Claude Code treats an installed plugin missing from `enabledPlugins` as
disabled (`claude plugin list --json` reports `enabled: false`). Sukiru reports
that state as disabled, not unknown, for non-managed installations.

## Bounded history

Snapshots and execution records share one retention policy, applied after
every capture and on launch:

- keep at most a configured number of batches (default 20);
- drop batches older than a configured age (default 30 days);
- keep the snapshot store under a configured size (default 1 GB), removing the
  oldest first.

The most recent batch is always kept so the last change can be rolled back.
Pruning removes a batch's snapshot and execution record together; a pruned
batch can no longer be rolled back, which Settings states. Settings also offer
clearing all history. The policy is stored in
`~/Library/Application Support/Sukiru/settings.json` so the app and the CLI
apply the same limits, and the CLI exposes pruning and clearing.
