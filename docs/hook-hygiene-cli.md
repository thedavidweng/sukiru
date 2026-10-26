# Hook hygiene CLI

`scan --json` includes optional `hookInventory` with configured handlers,
source tiers, exact source positions, producer evidence, health, and inspection
issues. `hooks inventory` emits the same shared report. Multiple Claude/Codex
sources are additive; OpenCode remains in `pluginInventory`.

Create a requests file containing exact scanned hook IDs:

```json
[{"action":"remove","hookID":"<id from hookInventory.hooks>"}]
```

Or choose `{"action":"remove-leftovers","producer":"Muxy"}` (also Orca), or
`{"action":"disable-producer","producer":"Orca"}` for installed Orca. Producer
disable applies across hosts, not to one handler. Source-managed definitions
return instructions rather than independently executable mutations.

```sh
sukiru hooks plan --requests requests.json --json > hook-plan.json
sukiru hooks execute --plan hook-plan.json --yes --confirm-dangerous --json
sukiru rollback --batch <execution batchID> --yes --json
```

Review the plan's `hooks`, `helperPaths`, `instructions`, and every batch command
before execution. Execute the saved plan, not a re-created plan: source bytes and
resolved paths must still match the scan. Changes require rescan and replanning.
Execution returns the shared record including snapshot ID, command diagnostics,
and post-run diff, even after a producer command fails. Existing conflict-aware
rollback options apply.

## Add, edit, and disableAllHooks

The same plan/execute flow also adds and edits hooks in Claude Code
`settings.json` / `settings.local.json` and Codex `hooks.json` (ADR-0014
rule 2). Codex `config.toml` hook tables stay remove-only. Plugin, skill,
subagent, and managed sources stay read-only.

Add a command handler. `scope` is `user` (default), `project`, or `local`
(Claude Code `settings.local.json` only). For project and local scopes,
`scopeRoot` must be a root passed with `--root` (or `SUKIRU_ROOTS`). Pass the
same roots to `hooks execute`.

```json
[{"action":"add","host":"claude","scope":"project","scopeRoot":"/work/app",
  "event":"PreToolUse","matcher":"Bash",
  "handler":{"type":"command","command":"rtk hook claude","timeout":5}}]
```

`add` always appends a new matcher group `{"matcher": …, "hooks": [handler]}`
to `hooks.<event>`, even when a group with the same matcher exists. It creates a
missing `hooks` object, event array, or file. An omitted or empty `matcher`
writes no matcher key. Handler keys are written in the order `type`, `command`,
`timeout`, `statusMessage`. `statusMessage` is accepted for Codex only. Claude
Code events must be in its documented list. Codex accepts other identifiers,
and the plan includes a warning.

Edit an exact scanned command handler. The request sets `matcher`, `command`,
`timeout`, and (Codex only) `statusMessage` to exactly the given values. An
omitted optional field is removed. Other handler keys are kept. The event and
scope do not change.

```json
[{"action":"edit","hookID":"<id>","matcher":"Edit|Write",
  "handler":{"type":"command","command":"lint-staged","timeout":10}}]
```

When the matcher changes in a group that holds several handlers, the handler
moves to a new group with the new matcher. Otherwise, the group's matcher is
edited in place.

Turn Claude Code's documented per-file `disableAllHooks` setting on or off.
`true` sets or inserts the key. `false` removes it, because `false` is the
default.

```json
[{"action":"set-disable-all","path":"/Users/me/.claude/settings.json","disableAllHooks":true}]
```

Neither host offers a per-hook pause, so Sukiru does not either.

All changes to one file become one `replace-hook-source` command. The command
carries the scanned hash, or an absent marker for a file that does not exist yet.
Only the edited token ranges change. Inserted text matches the file's
indentation (tabs, 2 or 4 spaces, or single-line). Rollback deletes a file that
the batch created. Duplicate keys or an unexpected structure make the plan fail.
Codex asks you to trust new or changed hooks before they run.

## App and isolation

The native app offers per-host Hooks destinations, Needs Attention grouping,
source/target reveal, source-unit navigation, Health inspection, and cleanup in
the shared Pending Changes cart. It also offers Add Hook, Edit, and Claude
Code's Disable All Hooks in This File. Hook changes join other queued changes in
one reviewed batch and one snapshot.

`SUKIRU_HOME` and `SUKIRU_ROOTS` isolate home/project sources as elsewhere in the
CLI. `SUKIRU_SYSTEM_ROOT` points to a mounted system tree for managed-policy
inspection; an overridden home otherwise excludes the machine's system policy.
Managed files are always read-only, even when writable by the current user.
