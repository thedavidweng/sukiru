# Host Plugin Interface Evidence

Date: 2026-10-03. Execution decisions updated for the user-approved explicit-effects consent amendment to ADR-0008. This note records read-only verification for plugin-management
work. The installed host versions were checked with version/help commands only;
no inventory command, host session, plugin code, marketplace refresh, or lifecycle
mutation was run.

## Installed command surfaces

Confirmed local binaries:

| Host | Version | Safe help commands run | Exposed operations |
| --- | --- | --- | --- |
| Claude Code | `2.1.288` | `claude plugin --help`; `claude plugin marketplace --help`; subcommand `--help` for install, update, uninstall, enable, disable, list, marketplace add/list/remove/update | Plugin install/list/update/uninstall/enable/disable; marketplace add/list/remove/update. |
| Codex CLI | `0.160.0` | `codex plugin --help`; `codex plugin marketplace --help`; subcommand `--help` for add/list/remove and marketplace add/list/upgrade/remove | Plugin add/list/remove; marketplace add/list/upgrade/remove. No plugin check/update or enable/disable subcommand is exposed. |
| OpenCode | `v2.0.22` | `opencode plugin --help`; `--help` for add/list/check/update/remove | Plugin add/list/check/update/remove. This machine has no verified v1 binary. |

The exact high-level argv and flags from the installed help are summarized
below. These flags were observed on the named versions; re-run `--help` for a
different installed build before enabling an operation.

### Claude Code 2.1.288

```text
claude plugin install|i [options] <plugin>
  --accept-command <sha256>
  --config <key=value> (repeatable)
  --json
  --registry <url>
  -s, --scope <scope> (user|project|local; default user)
  -y, --yes

claude plugin update [options] <plugin>
  --accept-command <sha256>
  --json
  -s, --scope <scope> (user|project|local|managed; default auto-detect)
  -y, --yes

claude plugin uninstall|remove [options] <plugin>
  --json
  --keep-data
  --prune
  -s, --scope <scope> (user|project|local; default user)
  -y, --yes

claude plugin enable [options] <plugin>
  --json
  -s, --scope <scope> (user|project|local; default auto-detect)

claude plugin disable [options] [plugin]
  -a, --all
  --json
  -s, --scope <scope> (user|project|local; default auto-detect)

claude plugin list [options]
  --available (requires --json)
  --data-size [plugin] (requires --json)
  --json

claude plugin marketplace add [options] <source>
  --claudeai
  --json
  --scope <scope> (user|project|local; default user)
  --sparse <paths...>

claude plugin marketplace list [options]
  --json

claude plugin marketplace remove|rm [options] <name>
  --json
  --scope <scope> (user|project|local; omitted removes from all scopes)

claude plugin marketplace update [options] [name]
  --json (only emits JSON when a name is supplied)
```

The installed help states install/update can accept a marketplace-declared
command or `headersHelper` only after explicit `-y` or a command-specific
`--accept-command` digest. If non-interactive, `-y` is required. Claude's
official reference explains that a command-source install may be refused when
not run in a TTY and that `-y` has no effect when called inside a Claude Code
session. Sukiru does not automatically supply either acceptance flag. Commands requiring
native trust approval remain in the host review workflow. Treat command-source and headersHelper entries
as instructions for the user to review and run through Claude Code's own
approval flow. An approval refusal or missing TTY is an incomplete operation.
Sources: [installed CLI reference](https://code.claude.com/docs/en/plugins/cli-reference#plugin-install),
[marketplace source behavior](https://code.claude.com/docs/en/plugins/cli-reference#plugin-marketplace-add).

Marketplace update with no name refreshes every configured marketplace. A
marketplace removal from its final declaring scope deletes its catalog cache,
uninstalls its plugins, and may remove their saved options, secrets, and data.
Never present that operation as a catalog-only removal. Sources:
[marketplace commands](https://code.claude.com/docs/en/plugins/cli-reference#claude-plugin-marketplace-commands).

### Codex CLI 0.160.0

```text
codex plugin add [OPTIONS] <PLUGIN[@MARKETPLACE]>
  -m, --marketplace <MARKETPLACE>
  --json
  -c, --config <key=value>
  --enable <FEATURE> (global Codex feature flag, not plugin enable)
  --disable <FEATURE> (global Codex feature flag, not plugin disable)

codex plugin list [OPTIONS]
  -m, --marketplace <MARKETPLACE>
  --json
  --available (requires JSON output)

codex plugin remove [OPTIONS] <PLUGIN[@MARKETPLACE]>
  -m, --marketplace <MARKETPLACE>
  --json

codex plugin marketplace add [OPTIONS] <SOURCE>
  --ref <REF>
  --sparse <PATH> (repeatable)
  --json

codex plugin marketplace list [OPTIONS]
  --json

codex plugin marketplace upgrade [OPTIONS] [MARKETPLACE_NAME]
  --json

codex plugin marketplace remove [OPTIONS] <MARKETPLACE_NAME>
  --json
```

`marketplace upgrade <name>` refreshes that marketplace; omitting the name
refreshes all configured Git marketplace snapshots. It does not upgrade local
marketplace directories. There is no per-plugin update command in this
installed CLI. `codex plugin remove` explicitly removes the plugin's local
cache. The installed `--enable/--disable` switches are Codex feature flags,
not plugin lifecycle controls. Sources: [Codex CLI plugin command source](https://github.com/openai/codex/blob/main/codex-rs/cli/src/plugin_cmd.rs),
[marketplace command source](https://github.com/openai/codex/blob/main/codex-rs/cli/src/marketplace_cmd.rs).

Codex app-server plugin list/read/install/uninstall methods are marked under
development and explicitly say not to call from production clients. Do not use
them as a CLI fallback. Source: [Codex app-server plugin methods](https://learn.chatgpt.com/docs/app-server#plugin-operations).

### OpenCode v2.0.22

```text
opencode plugin add <package>
opencode plugin list [--builtin]
opencode plugin check [<target>]
opencode plugin update [<target>]
opencode plugin remove <package>
```

The installed help exposes no command-specific lifecycle flags besides global
CLI flags. CLI add/remove manage global package configuration. Current official
v2 docs specify that update without a target updates every outdated package;
with a target it checks/updates that configured package. Local plugins and
exact package versions/full Git commit hashes are skipped. This documentation
is newer than the installed version and should be version-gated.
Source: [OpenCode v2 plugin guide](https://opencode.ai/v2/docs/plugins).

### OpenCode v1.18.34 (versioned docs/source only)

No v1 binary was verified on this machine. The pinned v1 CLI contract is
`opencode plugin <module>` (alias `opencode plug <module>`), with `--global/-g`
to install globally and `--force/-f` to replace an existing plugin version.
It is an install-and-config-update command, not v2's add/list/check/update/remove
command group. Sources: [v1 CLI documentation](https://dev.opencode.ai/docs/cli/#plugin),
[v1.18.34 implementation](https://github.com/anomalyco/opencode/blob/v1.18.34/packages/opencode/src/cli/cmd/plug.ts).

## Passive inventory, config, and capture roots

These are read boundaries and snapshot candidates, not claims that every path
exists on every installation. Respect environment overrides and configured
absolute paths. Capture bytes, symlinks, file types, absent paths, and directory
entries for affected roots before invoking a host mutation.

### Claude Code

The [official plugin loading reference](https://code.claude.com/docs/en/plugins/loading)
names one plugin root: `~/.claude/plugins`, unless overridden by
`CLAUDE_CODE_PLUGIN_CACHE_DIR`. It documents these children:

| Path | Meaning |
| --- | --- |
| `installed_plugins.json` | Fetched install records with scope, installPath, and version. |
| `known_marketplaces.json` | Fetched marketplace sources, install location, lastUpdated, autoUpdate. |
| `known_marketplaces_claudeai.json` | Account-hosted marketplace record when used. |
| `cache/<marketplace>/<entry>/<version>/` | Copied plugin version and dependency `node_modules`. |
| `marketplaces/<name>/` | Cloned/downloaded marketplace source; local file/directory sources remain in place at their configured paths. |
| `data/<plugin-id>/` | Persistent plugin data, options, and secrets may be associated with uninstall behavior. |
| `synced/`, `.trash/`, `flagged-plugins.json` | Synced plugins, moved-aside plugins, and delisted-plugin records. |
| `installed_plugins.set-aside.*.json`, `installed_plugins.unreadable.*.kept` | Host recovery copies of install records. |

The private `installed_plugins.json` and `known_marketplaces.json` encodings
are not presented as stable write protocols. For installed inventory use the
official passive `claude plugin list --json`; each item distinguishes version,
scope, enabled, installPath, and load errors. For configured catalogs use
`claude plugin marketplace list --json`.

Enablement is merged from `enabledPlugins`; marketplace declarations use
`extraKnownMarketplaces`. Applicable files include user
`~/.claude/settings.json`, project `.claude/settings.json`, local
`.claude/settings.local.json`, and managed settings. Scope/precedence details
are in the [loading reference](https://code.claude.com/docs/en/plugins/loading#find-where-a-plugin-is-enabled).
Do not infer installability or effective loading from a setting alone.

Snapshot candidate: the complete plugin root, every applicable settings file,
and any external local marketplace/plugin paths named in marketplace entries.
Because host records can be moved to dated recovery filenames, snapshot the
whole root, not only two known JSON files.

### Codex

The effective config is layered. The installed default is `~/.codex/config.toml`
(`$CODEX_HOME/config.toml` when overridden), trusted project layers can be
`<repo>/.codex/config.toml` and nested `.codex/config.toml` layers, and system,
managed, or profile config may contribute. See the [Codex config loader](https://github.com/openai/codex/blob/main/codex-rs/config/src/loader/mod.rs).

Representative local marketplace declaration and enablement:

```toml
[marketplaces."team"]
source_type = "local"
source = "/path/to/marketplace"

[plugins."formatter@team"]
enabled = true
```

Codex's public plugin config type has `PluginConfig.enabled` (default true),
and marketplace `source_type`, `source`, optional ref/sparse paths, and
last-update/revision metadata. See [Codex config types](https://github.com/openai/codex/blob/main/codex-rs/config/src/types.rs).

Local marketplace files are conventionally `~/.agents/plugins/marketplace.json`
or `<repo>/.agents/plugins/marketplace.json`; repo `.claude-plugin/marketplace.json`
is also documented as a compatibility source for the desktop product. A
marketplace file's `source.path` points to the plugin source. Source:
[OpenAI plugin packaging docs](https://developers.openai.com/plugins/build/plugins).

Codex source defines install state from an active version under
`$CODEX_HOME/plugins/cache/<marketplace>/<plugin>/<version>`, plus persistent
data roots `$CODEX_HOME/plugins/data/<plugin>-<marketplace>` and
`$CODEX_HOME/plugins/data/agent-plugins/<hash>`. Config and cache represent
different facts: enabled config with no active cache is not an installed
payload; an unreferenced cache is not by itself a configured installation.
Sources: [plugin store](https://github.com/openai/codex/blob/main/codex-rs/core-plugins/src/store.rs),
[installed marketplace roots](https://github.com/openai/codex/blob/main/codex-rs/core-plugins/src/installed_marketplaces.rs).

Snapshot candidate: entire `$CODEX_HOME` for CLI plugin operations, every
applicable project `.codex/config.toml`, local/personal `.agents/plugins/`
catalog and payload locations, and any configured local source outside those
roots. The marketplace root for Git sources is
`$CODEX_HOME/.tmp/marketplaces/<name>`; local marketplace source roots are
used in place. The source tree is authoritative for local source content, not
the fetched-marketplace cache.

### OpenCode v1

OpenCode v1.18.34 source uses XDG roots: normally `~/.config/opencode` and
`~/.cache/opencode`; `OPENCODE_CONFIG_DIR` changes the config root. Its v1
package resolver caches packages under
`<cache-root>/packages/<sanitized-package-spec>/node_modules`. Sources:
[v1 global paths](https://github.com/anomalyco/opencode/blob/v1.18.34/packages/core/src/global.ts),
[v1 npm package resolver](https://github.com/anomalyco/opencode/blob/v1.18.34/packages/core/src/npm.ts).

The v1 CLI adds an npm package spec to project config by default or global
config with `--global`; `--force` replaces the configured version. Local
plugins have no separate installation record. They can be configured by path
or loaded from local plugin discovery directories. Candidate config/plugin
roots are global config, project `opencode.json(c)`, `.opencode` config and
plugin directories, plus all external paths referenced by plugin entries.

Capture candidate: complete effective global config root and package cache,
all relevant project config roots and `.opencode/plugins` payloads, plus the
actual external local plugin source. Plugin-owned durable data paths are not
bounded by the host interface. The exact v1 config write set depends on which
global/project config shape is already present; inspect the pinned source and
version-specific help before making that claim.

### OpenCode v2

The v2 plugin array is stored under `plugins` in JSON/JSONC config and arrays
from applicable files are merged. Official config order covers global
`~/.config/opencode/opencode.json(c)`, direct project `opencode.json(c)`, then
`.opencode/opencode.json(c)` files; later/higher-specificity sources apply
according to the [config guide](https://opencode.ai/v2/docs/config/#locations).
`OPENCODE_CONFIG`, `OPENCODE_CONFIG_DIR`, and `OPENCODE_CONFIG_CONTENT` can
redirect/override config. Local discovery reads direct `.ts`/`.js` files and
immediate packages under global config `plugins/` and every discovered
project `.opencode/plugins/`; a sibling project `plugins/` directory is not
auto-discovered. Source: [v2 plugin guide](https://opencode.ai/v2/docs/plugins).

The v2.0.22 NPM manager installs package payload generations under
`<XDG cache root>/opencode/npm/<cache-key>/<generation>/node_modules/<package>`.
Global config and cache roots can diverge when `OPENCODE_CONFIG_DIR` or XDG
environment variables are set. Sources: [v2.0.22 global paths](https://github.com/anomalyco/opencode/blob/v2.0.22/packages/util/src/global.ts),
[v2.0.22 NPM manager](https://github.com/anomalyco/opencode/blob/v2.0.22/packages/util/src/npm.ts).

Capture candidate: complete global config directory, package cache root,
applicable project config files, `.opencode/plugins` local payloads, and all
external paths referenced by package/local entries. Config edits to global
`plugins` are host-managed. There is no stable installation ledger, separate
data directory guarantee, or path boundary for plugin code's own storage.

## Known limits and operation bounds

- Host records and configured enablement do not prove that a plugin currently
  loads in a runtime. Do not start a host session or invoke plugin code for
  passive health checks. OpenCode v2's runtime `plugin.list()` API reports
  active plugins and is not the passive inventory surface.
- Claude marketplace removal is explicitly cascading. Codex marketplace
  removal source removes a configured marketplace and its installed snapshot
  root; no plugin-uninstall cascade is documented or evidenced. OpenCode v2
  package removal edits global package config; local auto-discovered files
  have no native delete operation.
- Claude command-source and headersHelper operations can hand control to an
  arbitrary marketplace-declared command. Sukiru must not auto-accept them or
  bypass native trust approval. Keep them as instructions
  for the user to review and run with host approval.
- OpenCode plugin code can write arbitrary files when loaded. Codex and
  Claude plugin runtime code can also write to plugin data or other user files.
  Official docs do not bound those runtime writes. Explicit runtime-effects consent permits execution without claiming those arbitrary effects are restorable. Package acquisition itself
  has constrained/ignored install scripts in some implementations, but this
  does not bound author code run in a later session.
- Therefore a “complete affected-file capture” cannot be proven from the
  command name alone for opaque author commands or plugin runtime behavior.
  For supported host CLI mutations, capture all known host config/catalog,
  installation/cache/data roots and declared local source paths before the
  command; fail closed if any required root cannot be completely enumerated.
  Post-scan after success or failure. Do not claim rollback of arbitrary
  effects outside the observed/captured roots.

## Pinned-source operation initialization decisions

The following source inspection supersedes any implication above that command
availability alone permits execution. These decisions apply to OpenCode
`v1.18.34`, OpenCode `v2.0.22`, and Codex `rust-v0.160.0`; other versions need
the same initialization-path verification. No lifecycle command was executed
to obtain this evidence.

| Host and operation | Sukiru execution decision |
| --- | --- |
| OpenCode v1 install/replacement, including `--global` and `--force` | Native batch with explicit effects consent: the command initializes installed plugins before its handler. |
| OpenCode v2 `plugin add` | Native batch candidate: package acquisition and entrypoint resolution do not load the plugin. Complete capture remains required. |
| OpenCode v2 `plugin remove` | Native batch candidate: removes global server/TUI package configuration, not payloads or automatically discovered local files. |
| OpenCode v2 `plugin list`, `check`, `update` | Explicit runtime batch with effects consent: these routes ensure/start a server and enumerate runtime plugins. Startup scanning remains passive. |
| Codex configured-marketplace plugin `add` and `remove` | Native batch candidates: standalone plugin manager, without an agent session. |
| Codex configured marketplace `add`, `upgrade`, `remove` | Native batch candidates with operation-specific capture and actual marketplace-wide impact. |
| Codex `openai-curated-remote` plugin `add` and `remove` | Native batch with explicit backend-effects consent. File restoration cannot undo backend installation state. |
| Codex plugin `list` | Explicit refresh only: unfiltered listing can fetch a remote catalog. Startup inventory reads local files. |

### OpenCode v1 eagerly initializes plugins

The pinned [plugin command](https://github.com/anomalyco/opencode/blob/v1.18.34/packages/opencode/src/cli/cmd/plug.ts)
uses `effectCmd` without `instance: false`.
[`effect-cmd.ts`](https://github.com/anomalyco/opencode/blob/v1.18.34/packages/opencode/src/cli/effect-cmd.ts)
loads an instance before calling the handler.
[`instance-store.ts`](https://github.com/anomalyco/opencode/blob/v1.18.34/packages/opencode/src/project/instance-store.ts)
invokes bootstrap, and
[`project/bootstrap.ts`](https://github.com/anomalyco/opencode/blob/v1.18.34/packages/opencode/src/project/bootstrap.ts)
explicitly calls `config.get()` and `plugin.init()` before initializing the
other project services. This happens even for global installation or forced
replacement. The installation handler's manifest-reading behavior does not
make the complete command passive. Do not recreate the installer in Sukiru
or launch it with an invented plugin-suppression workaround.

### OpenCode v2 separates package management from runtime inspection

The pinned [add handler](https://github.com/anomalyco/opencode/blob/v2.0.22/packages/cli/src/commands/handlers/plugin/add.ts)
uses `Npm.add` and `Host.resolve`.
[`Host.resolve`](https://github.com/anomalyco/opencode/blob/v2.0.22/packages/plugin/src/host.ts)
resolves entrypoints; importing plugin code is the separate `Host.load` call,
which this handler does not make. The
[NPM manager](https://github.com/anomalyco/opencode/blob/v2.0.22/packages/util/src/npm.ts)
sets Arborist `ignoreScripts: true`. The
[remove handler](https://github.com/anomalyco/opencode/blob/v2.0.22/packages/cli/src/commands/handlers/plugin/remove.ts)
updates global configuration without connecting to the server.

In contrast, [inventory inspection](https://github.com/anomalyco/opencode/blob/v2.0.22/packages/cli/src/commands/handlers/plugin/inventory.ts)
first calls `ServerConnection.resolve()` and `client.plugin.list()`. Both
[check](https://github.com/anomalyco/opencode/blob/v2.0.22/packages/cli/src/commands/handlers/plugin/check.ts)
and [update](https://github.com/anomalyco/opencode/blob/v2.0.22/packages/cli/src/commands/handlers/plugin/update.ts)
use that inspection, including when the selected target is a TUI package.
[List](https://github.com/anomalyco/opencode/blob/v2.0.22/packages/cli/src/commands/handlers/plugin/list.ts)
also resolves a server directly.
[`server-connection.ts`](https://github.com/anomalyco/opencode/blob/v2.0.22/packages/cli/src/services/server-connection.ts)
uses `Service.ensure()` or `Standalone.start()`. There is no verified passive
CLI check/update route to substitute.

Capture for add/remove includes `cli.json` and configuration temporary files,
not only `opencode.json`/`opencode.jsonc`. Removal calls `Config.get()`, whose
[implementation](https://github.com/anomalyco/opencode/blob/v2.0.22/packages/cli/src/config/config.ts)
can run [legacy configuration migration](https://github.com/anomalyco/opencode/blob/v2.0.22/packages/cli/src/config/migrate.ts)
into `cli.json` even when the requested package is absent. The
[global service](https://github.com/anomalyco/opencode/blob/v2.0.22/packages/util/src/global.ts)
creates data/config/state/log/bin/repository/temporary directories at startup.
The [NPM config reader](https://github.com/anomalyco/opencode/blob/v2.0.22/packages/util/src/npm-config.ts)
loads the effective npm configuration; its cache can be outside OpenCode's
package-generation directory. Resolve and capture that cache for acquisition
operations rather than claiming the OpenCode roots alone cover all writes.

### Codex local operations and remote backend mutations are distinct

The pinned [plugin CLI](https://github.com/openai/codex/blob/rust-v0.160.0/codex-rs/cli/src/plugin_cmd.rs)
loads configuration/auth and constructs a
[standalone plugin manager](https://github.com/openai/codex/blob/rust-v0.160.0/codex-rs/core/src/plugins/mod.rs).
Configured-marketplace installation materializes a source, stores its payload,
and enables it in user configuration through the
[manager](https://github.com/openai/codex/blob/rust-v0.160.0/codex-rs/core-plugins/src/manager.rs).
The [marketplace CLI](https://github.com/openai/codex/blob/rust-v0.160.0/codex-rs/cli/src/marketplace_cmd.rs)
dispatches add/upgrade/remove without starting an agent session. For npm plugin
sources, [materialization](https://github.com/openai/codex/blob/rust-v0.160.0/codex-rs/core-plugins/src/npm_source.rs)
uses `npm pack --ignore-scripts`; it does not install package dependencies.
Its inherited effective npm cache/log paths must join capture bounds when
that source type is supported.

The same CLI branches specially on `openai-curated-remote`.
[Remote mutations](https://github.com/openai/codex/blob/rust-v0.160.0/codex-rs/core-plugins/src/remote_mutations.rs)
call backend installation/uninstallation APIs in addition to changing local
bundles and caches. This is demonstrated non-filesystem state, not a
hypothetical risk. ADR-0008 requires a separate decision for it. The explicit-effects consent amendment supplies that decision: native remote
mutations require batch-specific agreement to backend changes. Snapshot
restoration must not be described as reversing backend installation.

### Capability regression expectations

Tests should distinguish host-exposed commands from Sukiru-executable routes:

- OpenCode v1 install/force replacement use exact native arguments and require
  explicit effects consent despite matching help output.
- OpenCode v2 list/check/update require explicit runtime-effects consent, including
  a selected TUI target; all operations capture known host roots before execution.
- OpenCode v2 removal is global package configuration removal, never deletion
  of a local discovered plugin file or its payload.
- Codex configured-marketplace add/remove and marketplace operations remain
  distinct from `openai-curated-remote` backend mutations, which require separate
  effects agreement and persist their rollback limits in history.
- Startup scanning invokes no lifecycle/list/check commands. Version/help
  detection does not infer runtime load success or promote an unverified
  operation to executable status.
- A capture plan lacking an operation's effective configuration/package/npm
  cache paths cannot claim complete protection; capture failure prevents the
  subprocess from starting.
