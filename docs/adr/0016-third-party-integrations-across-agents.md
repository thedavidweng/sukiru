# 0016: Third-party integrations across every agent they touch

- Status: Accepted, amended by [0017](0017-native-add-on-management.md)
- Date: 2026-10-30
- Amends: [0010](0010-agent-hook-hygiene.md), [0014](0014-native-first-management-and-bounded-history.md)

## Context

Apps such as Orca install the same integration into many agents at once:
hook entries in about twenty agents' configuration files, extension files in
Pi, oh-my-pi, Amp and OpenCode discovery folders, a Hermes plugin with its
`plugins.enabled` entry, and helper scripts in `~/.orca/agent-hooks`. Sukiru
read hooks only for Claude Code and Codex. After the app was uninstalled, its
other entries were neither visible nor removable in Sukiru.

## Decision

Hooks are keyed by a hook host, separate from plugin hosts. Besides Claude
Code and Codex, Sukiru reads the user-scope hook files of Cursor, Antigravity
(`~/.gemini/config/hooks.json` bundles), Gemini CLI, Droid, OpenClaude, Qoder,
Qoder CN, Qwen Code, CodeBuddy, Command Code, Devin, GitHub Copilot CLI
(`hooks/*.json`), Grok (`hooks/*.json`), Kimi Code (`[[hooks]]` tables), Kiro
(`hooks/*.json` and `agents/*.json`, object and list forms), jcode (`[hooks]`
command keys), ZCode (`hooks.events`), Muse (`managed_hooks_path`) and DSH.
These hosts are view and remove only. Add, edit and `disableAllHooks` stay with
Claude Code and Codex. Removal follows ADR-0010: exact entries, scanned
hashes, unrelated bytes kept, a snapshot, and rollback.

A command belongs to Orca when it names a script in Orca's payload boundary
(`~/.orca/agent-hooks/…`, through a literal path, `${HOME-}`, or
`${ORCA_AGENT_HOOK_ROOT-}`). Orca's own installers use the same rule. Literal
paths are read from guarded wrapper text. Runtime-resolved paths keep their
targets Unknown. This replaces the exact runtime-home wrapper match in ADR-0010.
Codex `[hooks.state…]` trust tables are not hook definitions.

Extensions form a separate passive inventory: entries directly inside each
host's user discovery folder, plus Hermes `plugins.enabled` names without a
plugin directory. Producer attribution uses the producer's own name prefix
(`orca-`, `muxy-`). Sukiru never loads extension code. Removing an extension
deletes exactly the scanned entry (or its single enabled-list line), after
checking its hash again.

`remove-leftovers` for an absent producer covers its leftover hooks, its
extensions, and every unreferenced regular file in its helper boundary. A
helper counts as referenced if a remaining hook has it as a literal target,
or if a command with unknown targets names the helper's file, `agent-hooks`
or `Muxy`. Unrelated ambiguous commands no longer block helper cleanup.
Execution preflight replays the same sweep. The app offers it as one Queue
Cleanup action in Health.
