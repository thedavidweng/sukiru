# Agent interface sources

Version: 2026-10-31

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

## Installed-agent detection

`Sources/SukiruCore/Hosts/AgentLauncher.swift` decides which agents count as installed,
and so which ones the sidebar lists under Agents rather than Not Installed. An agent counts
as installed when one of its commands is on `PATH` or in `~/.local/bin`, one of its apps
is in `/Applications` or `~/Applications`, or one of its VS Code-family extensions is in an
editor's `extensions` folder. Commands come from the official installer docs or from the
`bin` field of the vendor's own npm package. App names come from the vendor's download
page or the `app` stanza of the Homebrew cask, because download pages rarely name the
bundle. Extension ids come from the vendor's VS Code Marketplace listing. For agents
without a row here, no official source named a command, app bundle, or extension id when
the table was checked, so Sukiru judges them by their config folder alone: AiderDesk, AstrBot, CodeArts Agent, Codemaker,
Code Studio, Firebender, inference.sh, Jazz, jcode, Junie, Kimchi, Lingma, Loaf, MCPJam,
MiniMax Code, Moxby, Mux, Ona, Posit Assistant, Qoder CN, Sarvam Code, Terramind,
Tinycloud and Zenflow.

| Agent | Command | App | Extension | Sources | Checked |
| --- | --- | --- | --- | --- | --- |
| AdaL | `adal` | | | [Docs](https://docs.sylph.ai/), [npm @sylphai/adal-cli](https://www.npmjs.com/package/@sylphai/adal-cli) | 2026-10-31 (1.11.5) |
| Amp | `amp` | | | [CLI](https://ampcode.com/docs/cli), [npm @sourcegraph/amp](https://www.npmjs.com/package/@sourcegraph/amp) | 2026-10-31 |
| Antigravity | | Antigravity | | [Cask antigravity](https://formulae.brew.sh/cask/antigravity) | 2026-10-31 (2.28.2) |
| Antigravity CLI | `agy` | | | [Getting started (CLI)](https://antigravity.google/docs/getting-started?tab=cli) | 2026-10-31 |
| Augment | `auggie` | | `augment.vscode-augment` | [CLI](https://docs.augmentcode.com/cli/overview), [Marketplace](https://marketplace.visualstudio.com/items?itemName=augment.vscode-augment) | 2026-10-31 (0.36.0) |
| Autohand Code CLI | `autohand` | | | [CLI](https://autohand.ai/cli/), [npm autohand-cli](https://www.npmjs.com/package/autohand-cli) | 2026-10-31 (0.9.9) |
| IBM Bob | `bob` | | | [npm @ibm/bob](https://www.npmjs.com/package/@ibm/bob) | 2026-10-31 (2.0.9) |
| Claude Code | `claude` | Claude | | [Setup](https://code.claude.com/docs/en/setup), [Desktop: Claude Code is the Code tab](https://code.claude.com/docs/en/desktop), [Cask claude](https://formulae.brew.sh/cask/claude) | 2026-10-31 (2.1.316) |
| Cline | `cline` | | `saoudrizwan.claude-dev` | [Installing Cline](https://docs.cline.bot/getting-started/installing-cline), [Marketplace](https://marketplace.visualstudio.com/items?itemName=saoudrizwan.claude-dev) | 2026-10-31 (3.0.74) |
| CodeBuddy | `codebuddy` | CodeBuddy | | [CLI installation](https://www.codebuddy.ai/docs/cli/installation), [Cask codebuddy](https://formulae.brew.sh/cask/codebuddy) | 2026-10-31 (2.179.0) |
| Codex | `codex` | Codex | | [CLI](https://learn.chatgpt.com/docs/codex/cli), [Cask codex-app](https://formulae.brew.sh/cask/codex-app) | 2026-10-31 (0.166.0) |
| Command Code | `cmd`, `commandcode`, `command-code` | | | [Docs](https://commandcode.ai/docs), [npm command-code](https://www.npmjs.com/package/command-code) | 2026-10-31 (1.88.2) |
| Continue | `cn` | | `continue.continue` | [CLI quickstart](https://docs.continue.dev/cli/quickstart), [Marketplace](https://marketplace.visualstudio.com/items?itemName=Continue.continue) | 2026-10-31 (1.5.47) |
| Cortex Code | `cortex` | | | [Cortex Code CLI](https://docs.snowflake.com/en/user-guide/cortex-code/cortex-code-cli) | 2026-10-31 |
| Crush | `crush` | | | [Repository](https://github.com/charmbracelet/crush), [npm @charmland/crush](https://www.npmjs.com/package/@charmland/crush) | 2026-10-31 (0.99.0) |
| Cursor | `agent` | Cursor | | [CLI installation](https://cursor.com/docs/cli/installation), [Cask cursor](https://formulae.brew.sh/cask/cursor) | 2026-10-31 (3.27.22) |
| Deep Agents | `dcode` | | | [Deep Agents Code](https://docs.langchain.com/oss/deepagents/code/overview) | 2026-10-31 |
| Devin for Terminal | `devin` | | | [Devin CLI](https://docs.devin.ai/cli) | 2026-10-31 |
| Dexto | `dexto` | | | [Repository](https://github.com/truffle-ai/dexto) | 2026-10-31 |
| Droid | `droid` | | | [Quickstart](https://docs.factory.com/droid-cli/quickstart), [npm @factory/cli](https://www.npmjs.com/package/@factory/cli) | 2026-10-31 (1.1.0) |
| DSH | `dsh` | | | [CLI](https://deepseekdocs.com/en/docs/user-guide/cli), [npm @deepseek-ai/dsh](https://www.npmjs.com/package/@deepseek-ai/dsh) | 2026-10-31 |
| ForgeCode | `forge` | | | [Repository](https://github.com/antinomyhq/forge), [npm forgecode](https://www.npmjs.com/package/forgecode) | 2026-10-31 (2.13.21) |
| fx | `fx` | | | [Repository](https://github.com/vercel-labs/fx) | 2026-10-31 |
| Gemini CLI | `gemini` | | | [Installation](https://geminicli.com/docs/get-started/installation/) | 2026-10-31 (0.66.0) |
| GitHub Copilot | `copilot` | | `github.copilot-chat` | [Install Copilot CLI](https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/install-copilot-cli), [Marketplace](https://marketplace.visualstudio.com/items?itemName=GitHub.copilot-chat) | 2026-10-31 (1.0.105) |
| Goose | `goose` | Goose | | [Installation](https://goose-docs.ai/docs/getting-started/installation/), [Cask block-goose](https://formulae.brew.sh/cask/block-goose) | 2026-10-31 (1.57.0) |
| Grok Build | `grok` | | | [Grok Build](https://x.ai/build), `grok --help` | 2026-10-31 |
| Hermes Agent | `hermes` | | | [Installation](https://hermes-agent.nousresearch.com/docs/getting-started/installation) | 2026-10-31 |
| iFlow CLI | `iflow` | | | [Quickstart](https://platform.iflow.cn/en/cli/quickstart) | 2026-10-31 (0.5.19) |
| Kilo Code | `kilo` | | `kilocode.kilo-code` | [CLI](https://kilo.ai/docs/code-with-ai/platforms/cli), [Marketplace](https://marketplace.visualstudio.com/items?itemName=kilocode.Kilo-Code) | 2026-10-31 (7.8.18) |
| Kimi Code CLI | `kimi` | | | [Getting started](https://moonshotai.github.io/kimi-cli/en/guides/getting-started.html) | 2026-10-31 |
| Kiro CLI | `kiro-cli` | Kiro, Kiro CLI | | [Cask kiro-cli](https://formulae.brew.sh/cask/kiro-cli), [Cask kiro](https://formulae.brew.sh/cask/kiro) | 2026-10-31 (1.4.62) |
| Kode | `kode` | | | [Repository](https://github.com/shareAI-lab/kode) | 2026-10-31 (2.2.1) |
| Mistral Vibe | `vibe` | | | [Install and setup](https://docs.mistral.ai/vibe/code/cli/install-setup) | 2026-10-31 |
| Muse | `muse` | | | [Quickstart](https://meta-models.github.io/muse-code-sdk/next/guides/quickstart/) | 2026-10-31 |
| Neovate | `neovate` | | | [Repository](https://github.com/neovateai/neovate-code) | 2026-10-31 (0.28.5) |
| oh-my-pi | `omp` | | | [Docs](https://omp.sh/docs), [npm @oh-my-pi/pi-coding-agent](https://www.npmjs.com/package/@oh-my-pi/pi-coding-agent) | 2026-10-31 (18.14.1) |
| OpenClaude | `openclaude` | | | [Repository](https://github.com/Twigpine/openclaude) | 2026-10-31 (0.33.0) |
| OpenClaw | `openclaw` | | | [Install](https://docs.openclaw.ai/install) | 2026-10-31 |
| OpenCode | `opencode` | OpenCode | | [Docs](https://opencode.ai/docs/), [Cask opencode-desktop](https://formulae.brew.sh/cask/opencode-desktop) | 2026-10-31 (2.2.5) |
| OpenHands | `openhands` | | | [CLI installation](https://docs.openhands.dev/openhands/usage/cli/installation) | 2026-10-31 |
| Pi | `pi` | | | [Quickstart](https://pi.dev/docs/latest/quickstart) | 2026-10-31 |
| Pochi | `pochi` | | | [npm @getpochi/cli](https://www.npmjs.com/package/@getpochi/cli) | 2026-10-31 (0.6.21) |
| Qoder | `qodercli` | Qoder | | [CLI installation](https://docs.qoder.com/cli/installation), [npm @qoder-ai/qodercli](https://www.npmjs.com/package/@qoder-ai/qodercli), [Cask qoder](https://formulae.brew.sh/cask/qoder) | 2026-10-31 (1.1.81) |
| Qwen Code | `qwen` | | | [Overview](https://qwenlm.github.io/qwen-code-docs/en/users/overview/) | 2026-10-31 (0.26.4) |
| Reasonix | `reasonix` | | | [Repository](https://github.com/esengine/DeepSeek-Reasonix) | 2026-10-31 (2.56.0) |
| Roo Code | | | `rooveterinaryinc.roo-cline` | [Marketplace](https://marketplace.visualstudio.com/items?itemName=RooVeterinaryInc.roo-cline) | 2026-10-31 (3.54.0) |
| Rovo Dev | `acli` (Rovo Dev runs as `acli rovodev`) | | | [Install Rovo Dev CLI](https://support.atlassian.com/rovo/docs/install-and-run-rovo-dev-cli-on-your-device/) | 2026-10-31 |
| Tabnine CLI | `tabnine` | | | [Quickstart](https://docs.tabnine.com/main/getting-started/tabnine-cli/getting-started/quickstart) | 2026-10-31 (maintenance mode) |
| Trae | | Trae | | [Cask trae](https://formulae.brew.sh/cask/trae) | 2026-10-31 (2.3.61406) |
| Trae CN | | Trae CN | | [Cask trae-cn](https://formulae.brew.sh/cask/trae-cn) | 2026-10-31 (2.3.62837) |
| Warp | | Warp | | [Cask warp](https://formulae.brew.sh/cask/warp) | 2026-10-31 |
| Windsurf | | Windsurf, Devin | | [Devin Desktop is the new name for Windsurf](https://devin.ai/download), [Cask devin-desktop](https://formulae.brew.sh/cask/devin-desktop) | 2026-10-31 |
| ZCode | | ZCode | | [Cask zcode](https://formulae.brew.sh/cask/zcode) | 2026-10-31 (3.16.3) |
| Zed | `zed` | Zed | | [Getting started](https://zed.dev/docs/getting-started), [Cask zed](https://formulae.brew.sh/cask/zed) | 2026-10-31 (1.26.2) |
| Zencoder | | | `zencoderai.zencoder` | [Marketplace](https://marketplace.visualstudio.com/items?itemName=ZencoderAI.zencoder) | 2026-10-31 (3.85.9011) |

`agent` (Cursor) and `acli` (Rovo Dev) are generic names: another tool's `agent` command,
or ACLI installed without Rovo Dev, also counts as installed.
