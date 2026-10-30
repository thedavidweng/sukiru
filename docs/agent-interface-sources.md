# Agent interface sources

Version: 2026-10-30

The version is the date of the most recent change to this file. Update it, and the row's
Checked date, whenever a source is re-verified or a command or key changes.

Each row names the official documentation, or the installed CLI's own `--help` where no
public page exists, behind every command and configuration key that Sukiru runs or edits
for that agent. When a host renames or drops a command, start here: compare the row with
the current documentation, then update the route in
`Sources/SukiruCore/Extensions/AgentExtensionRoutes.swift`, the reader that matches the
key, and this row. Plugin lifecycles for Claude Code, Codex, OpenCode, Cursor and
Antigravity are covered in more detail in
[host-plugin-interface-evidence.md](host-plugin-interface-evidence.md).

Sukiru tries the host's command first, when its CLI is on `PATH` and
`<command> --help` lists the subcommand. Otherwise it edits the documented key
(ADR-0014 rule 2), and if there is no such key it gives instructions instead.

## Commands and keys

| Agent | What Sukiru changes | Command | Documented key or file | Sources | Checked |
| --- | --- | --- | --- | --- | --- |
| Pi | Auto-loaded extension on/off | none | `~/.pi/agent/settings.json` `extensions`: `-extensions/<file>` | [Settings](https://pi.dev/docs/latest/settings) | 2026-10-30 |
| Pi | Package remove, on/off | `pi remove <source>` | `packages` entry; empty `extensions`/`skills`/`prompts`/`themes` filters | [Packages](https://pi.dev/docs/latest/packages) | 2026-10-30 |
| oh-my-pi | Extension module on/off | none | `~/.omp/agent/config.yml` `disabledExtensions`: `extension-module:<stem>` | [Settings](https://github.com/can1357/oh-my-pi/blob/main/docs/settings.md), [Extension authoring](https://omp.sh/docs/extension-authoring) | 2026-10-30 (omp 18.14.0) |
| oh-my-pi | MCP server remove, on/off | none | `~/.omp/agent/mcp.json` `mcpServers.<name>.enabled` | [MCP config](https://github.com/can1357/oh-my-pi/blob/main/docs/mcp-config.md) | 2026-10-30 |
| DSH | Bundle plugin remove | `dsh plugin --profile <p> remove <pkg>` | `~/.dsh/profiles/<p>/package.json` dependencies; patch-layer `insert` lines stay manual | [CLI](https://deepseekdocs.com/en/docs/user-guide/cli), [Plugins](https://deepseekdocs.com/en/docs/user-guide/plugins), [Configuration](https://deepseekdocs.com/en/docs/user-guide/configuration) | 2026-10-30 (docs only) |
| DSH | Plugin on/off | none (plugin panel) | none | [Plugins](https://deepseekdocs.com/en/docs/user-guide/plugins) | 2026-10-30 |
| Hermes | Plugin remove, on/off | `hermes plugins remove\|disable\|enable <name>` | `~/.hermes/config.yaml` `plugins.enabled` / `plugins.disabled` | [Plugins](https://hermes-agent.nousresearch.com/docs/user-guide/features/plugins), `hermes plugins --help` | 2026-10-30 (v0.22.5) |
| Hermes | MCP server remove, on/off | `hermes mcp remove <name>` | `mcp_servers.<name>.enabled` | [MCP](https://hermes-agent.nousresearch.com/docs/user-guide/features/mcp) | 2026-10-30 (v0.22.5) |
| Amp | Plugin file on/off | none | none; Sukiru moves the file to `~/.config/amp/disabled-extensions` (ADR-0008 local-file exception) | [Amp docs](https://ampcode.com/docs) | 2026-10-30 |
| OpenCode | Local plugin file on/off | none | none; moved to `<config>/disabled-extensions` | [Plugins](https://opencode.ai/docs/plugins/) | 2026-10-30 (v2.2.2) |
| OpenCode | MCP server remove, on/off | none | `opencode.json` `mcp.<name>.enabled` | [MCP servers](https://opencode.ai/docs/mcp-servers/) | 2026-10-30 (v2.2.2) |
| Claude Code | MCP server remove | `claude mcp remove <name> --scope user` | `~/.claude.json` `mcpServers`; no user-scope switch | [MCP](https://code.claude.com/docs/en/mcp) | 2026-10-30 (2.1.314) |
| Claude Code | `disableAllHooks` | none | settings `disableAllHooks` | [Settings](https://code.claude.com/docs/en/settings), [Hooks](https://code.claude.com/docs/en/hooks) | 2026-10-30 |
| OpenClaude | Plugin remove, on/off | `openclaude plugin uninstall\|disable\|enable <id> --scope user` | `~/.openclaude/settings.json` `enabledPlugins` | [Repository](https://github.com/Twigpine/openclaude), `openclaude plugin --help` | 2026-10-30 (0.16.1) |
| OpenClaude | MCP server remove | `openclaude mcp remove <name> --scope user` | `~/.openclaude.json` `mcpServers` | `openclaude mcp --help` | 2026-10-30 (0.16.1) |
| OpenClaude | `disableAllHooks` | none | `~/.openclaude/settings.json` `disableAllHooks` (Claude Code setting) | [Claude Code settings](https://code.claude.com/docs/en/settings) | 2026-10-30 |
| Codex | MCP server remove, on/off | `codex mcp remove <name>` | `config.toml` `[mcp_servers.<name>] enabled` | [MCP](https://learn.chatgpt.com/docs/extend/mcp?surface=cli), [Config reference](https://learn.chatgpt.com/docs/config-file/config-reference) | 2026-10-30 (0.166.0) |
| Cursor | MCP server on/off, remove | `cursor-agent mcp disable\|enable <name>` | `~/.cursor/mcp.json` `mcpServers` (removal) | [CLI MCP](https://cursor.com/docs/cli/mcp) | 2026-10-30 (2026.10.22) |
| Droid | Plugin remove, on/off | `droid plugin uninstall <id> --scope user` | `~/.factory/settings.json` `enabledPlugins` | [Plugins](https://docs.factory.ai/cli/configuration/plugins) | 2026-10-30 (1.0.0) |
| Droid | MCP server remove, on/off | `droid mcp remove <name>` | `~/.factory/mcp.json` `mcpServers.<name>.disabled` | [MCP](https://docs.factory.ai/cli/configuration/mcp) | 2026-10-30 (1.0.0) |
| Devin | Plugin remove | `devin plugins remove <name> -y` | `~/.local/share/devin/cli/plugins/lock.json` (read only); no disable | `devin plugins --help` | 2026-10-30 (3000.11.234) |
| Devin | MCP server remove, on/off | `devin mcp remove\|disable\|enable <name> --scope user` | `~/.config/devin/mcp_config.json` `mcpServers` | `devin mcp --help` | 2026-10-30 (3000.11.234) |
| Muse | MCP server remove, on/off | none | `~/.config/muse/settings.json` `mcpServers.<name>.enabled` | [MCP servers](https://meta-models.github.io/muse-code-sdk/next/guides/extend/mcp-servers/) | 2026-10-30 (1.4.14) |
| Muse | Plugins | `muse plugins remove\|disable\|enable <id>` (not routed: no documented installation record to read) | none | `muse plugins --help` | 2026-10-30 (1.4.14) |
| Gemini CLI | MCP server remove, on/off | `gemini mcp remove <name>`, `gemini mcp enable|disable <name>` (state in `~/.gemini/mcp-server-enablement.json`) | `~/.gemini/settings.json` `mcp.excluded` | [MCP servers](https://geminicli.com/docs/tools/mcp-server/) | 2026-10-30 (docs only) |
| Gemini CLI | Hook on/off | `/hooks disable <name>` inside a session | none in a file | [Hooks](https://geminicli.com/docs/hooks/) | 2026-10-30 |
| Grok | MCP server remove, on/off | `grok mcp remove\|disable\|enable <name>` | `~/.grok/config.toml` `[mcp_servers.<name>] enabled` | `grok mcp --help` | 2026-10-30 (1.0.70) |
| Kiro | Hook on/off | none | hook file `hooks[].enabled` | [Hooks](https://kiro.dev/docs/hooks/) | 2026-10-30 (docs only) |
| Qwen Code | `disableAllHooks` | none | `~/.qwen/settings.json` `disableAllHooks` | [Hooks](https://qwenlm.github.io/qwen-code-docs/en/users/features/hooks/) | 2026-10-30 (docs only) |
| GitHub Copilot CLI | `disableAllHooks` | none | `~/.copilot/hooks/*.json` `disableAllHooks` | [Hooks reference](https://docs.github.com/en/copilot/reference/hooks-reference) | 2026-10-30 (docs only) |

"Docs only" means the CLI was not installed when the row was checked; Sukiru follows the
documentation and its tests use fixtures.
