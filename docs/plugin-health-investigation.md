# Local plugin health investigation

Date: 2026-10-03. This investigation informed the repair boundary subsequently
accepted in ADR-0008; it did not authorize changes to this machine's host state.

## OpenCode: confirmed v1 plugin definitions loaded by v2

The installed `opencode` and `opencode2` commands both resolve to OpenCode
v2.0.22. Existing `~/.local/share/opencode/log/opencode.log` entries confirm
the same loader error for three local files:

| Local file | Observed definition | Recorded error |
| --- | --- | --- |
| `~/.config/opencode/plugin/vibeusage-tracker.js` | Named async factory only | Missing default definition with an id and effect or setup; reference `err_a96dd2ae` |
| `~/.config/opencode/plugins/muxy-notify.js` | Named async factory only | Same loader error |
| `~/.config/opencode/plugins/rtk.ts` | Named async factory only | Same loader error |

Orca and Herdr's local server plugins have default definitions with `id` and
`setup`; they do not have this structural defect. The presence of those fields
alone does not prove their behavior is correct. No server was started or
plugin executed to reproduce the errors during this investigation.

These are incompatible plugin payloads, not evidence of damaged installation
records. The [v2.0.22 module loader](https://github.com/anomalyco/opencode/blob/v2.0.22/packages/core/src/plugin/module.ts#L55)
requires a default object with a string `id` and a function-valued `effect` or
`setup`, before running the plugin's hooks. The [official v2 plugin documentation](https://opencode.ai/v2/docs/plugins)
states that `plugin update` skips local plugins and that `plugin remove`
removes global package configuration. Those commands do not migrate these
local JavaScript or TypeScript files.

The [official migration guide](https://opencode.ai/v2/docs/build/plugins/migrate-v1)
requires porting plugin implementation code. Negative `-id` configuration is
not a repair for these files: the [supervisor](https://github.com/anomalyco/opencode/blob/v2.0.22/packages/core/src/plugin/supervisor.ts#L34)
loads modules before applying the configured ID filter, and these failed
modules have no valid ID. The current official plugin API has no migration or
disable operation, and the configuration PATCH schema cannot write plugins.

Repair choices have different meanings:

- Replace the file using its producer's verified v2-compatible release or
  integration installer: restores the integration without Sukiru owning its
  implementation. Whether each producer offers this has not been established.
- Port the plugin to v2: restores behavior only if the event and hook mapping
  is correct; adding an empty setup merely suppresses the load error.
- Stop loading the incompatible file: an explicit disable action, which does
  not restore the integration's behavior.
- Use a compatible v1 host: changes the host environment and requires checking
  the other installed integrations; no downgrade was performed or proposed
  as an automatic repair.

The preferred repair is a verified producer-provided migration when available.
Sukiru can identify the incompatible host/plugin pair itself. Generic rewriting
of plugin code would make it responsible for integration behavior and cannot
be justified by this loader error alone. This case does not demonstrate a
need to change ADR-0001's ban on installation-record writes. ADR-0008 subsequently
allows confirmed, snapshot-protected moves of incompatible local files out of
automatic discovery; deletion uses the host's native management interface.
Direct host configuration and installation-record writes remain excluded.

## Claude Code: no confirmed installation-record corruption

Claude Code v2.1.288 reports seven user-scope plugin installations and four
marketplaces. Every recorded installation path and marketplace directory
exists; each installation matches a marketplace entry. Two unreferenced cache
version directories are present, but are not classified as damage.

Official validation reports a reserved-name error for `claude-session-driver`
in `superpowers-marketplace`. The [upstream marketplace](https://github.com/obra/superpowers-marketplace/blob/main/.claude-plugin/marketplace.json)
still declares that name at the time of inspection. Refreshing the marketplace
is therefore not an established repair for that naming defect.

Validating the official `claude-code-setup` plugin alone reports a reserved
name and instructs the caller to validate its official marketplace instead.
That marketplace passes validation. This context-sensitive result must not
be promoted to an installation-corruption finding.

The validator prefers a marketplace manifest when given a directory containing
both marketplace and plugin manifests. The investigation subsequently targeted
the plugin manifest files explicitly to validate Ponytail and both Superpowers
installations. See the [official validation reference](https://code.claude.com/docs/en/plugins/cli-reference#validate-a-directory).

All host inspection was read-only. It did not establish runtime loading health
for Claude plugins, inspect credentials, or update, uninstall, disable, or
rewrite any installed plugin.

## Verified official interface boundaries

This is an observed capability baseline, not a promise that every installed
version supports the same commands. Implementation must detect the installed
host version and actual operation capabilities.

| Host baseline | Official lifecycle surface | Important limits |
| --- | --- | --- |
| Claude Code 2.1.288 | Plugin install, list, update, uninstall, enable, disable; marketplace add, list, update, remove | Marketplace writes are not all JSON; install may require approval in the host |
| Codex CLI 0.160.0 | Plugin add, list, remove; marketplace add, list, upgrade, remove | No independent update or enable/disable CLI subcommands in this inspected version |
| OpenCode v1.18.34 | `plugin <module>` / `plug`, local or global installation, force replacement | No v2-style add/list/check/update/remove command group; configuration uses `plugin` |
| OpenCode v2.0.22 | Plugin add, list, check, update, remove | Add/remove operate on global package configuration; update skips local files and exact revisions; configuration uses `plugins` |

Sources: [Claude CLI reference](https://code.claude.com/docs/en/plugins/cli-reference),
[Codex CLI source](https://github.com/openai/codex/blob/main/codex-rs/cli/src/plugin_cmd.rs),
[OpenCode v1 command](https://github.com/anomalyco/opencode/blob/v1.18.34/packages/opencode/src/cli/cmd/plug.ts),
and [OpenCode v2 documentation](https://opencode.ai/v2/docs/plugins).

Codex app-server also exposes plugin methods, but its documented plugin
list/read/install/uninstall methods carried an explicit warning against
production-client use at the time of investigation. Their existence alone
does not establish a supported production integration.
See the [official app-server reference](https://learn.chatgpt.com/docs/app-server).

OpenCode v2 plugin listing can connect to a server and enumerate active
plugins. Under ADR-0008's passive-check policy, an operation that starts a
session or runs plugin code is excluded from health checking; its name alone
does not prove that it is passive.
