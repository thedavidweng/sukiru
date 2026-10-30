# 0017: Native management of every agent's add-ons

- Status: Accepted
- Date: 2026-10-30
- Amends: [0014](0014-native-first-management-and-bounded-history.md), [0016](0016-third-party-integrations-across-agents.md)

## Context

ADR-0016 made third-party extensions visible and removable. Other add-ons stayed out of
reach: Pi packages, DSH bundle plugins, plugins of agents without a `PluginHost` lifecycle
(Droid, OpenClaude, Devin), and MCP servers in every agent. Nothing could be switched off
without deleting it. The user asked that every add-on of every agent can at least be
removed and disabled, preferably through the agent's own CLI.

## Decision

The extension inventory lists four categories per host: auto-loaded extensions, packages,
plugins, and MCP servers. Each entry carries the enablement the host records, or unknown.
Scanning reads documented files only and runs no host command.

`remove-extension`, `disable-extension` and `enable-extension` requests follow ADR-0014's
order:

1. The host's command, when its CLI is on `PATH` and `<command> --help` lists the
   subcommand. The command runs through the Command Batch with the declaring file and the
   payload it manages as capture roots.
2. Otherwise the documented key, edited in place. The edit is recomputed at execution from
   the file whose hash matched the plan, and the result must parse to exactly the intended
   change (JSON, block YAML, or `[mcp_servers.<name>]` TOML). Edits to one file merge into
   one command and run before host commands. A file that would also get a hook edit in the
   same batch is refused, so the user applies one change, refreshes, then queues the other.
3. Otherwise instructions, which keep the batch from running.

Amp and OpenCode document no per-file switch. Disabling one of their auto-loaded files moves
it to a sibling `disabled-extensions` folder, extending ADR-0008's local-file exception to
these hosts. Enabling moves it back.

Hook switches widen in the same way. `disableAllHooks` is offered wherever a host documents
it: Claude Code, OpenClaude, Qwen Code, and each Copilot CLI hook file. Kiro's
`hooks[].enabled` becomes a per-hook switch. Gemini CLI toggles hooks only inside a session,
so Sukiru gives instructions for it.

[docs/agent-interface-sources.md](../agent-interface-sources.md) names the official source,
or the CLI help, behind every command and key. It is versioned by the date of its latest
change and is updated with any route.

## Limits

- DSH toggles bundle plugins only in its plugin panel, and `dsh plugin remove` leaves
  patch-layer `insert` lines for the user to remove.
- Devin has no plugin disable. Claude Code and OpenClaude document no user-scope MCP switch.
- Muse documents its plugin commands but not where installations are recorded, so Muse
  plugins are not listed.
- File rollback restores captured files. It does not undo what a host command changed
  outside them, such as package caches.
