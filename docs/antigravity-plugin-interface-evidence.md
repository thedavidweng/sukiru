# Antigravity Plugin Interface Evidence

Verified 2026-10-25 against `/opt/homebrew/bin/agy` **1.4.7**, current Google
documentation, and first-party guides shipped with that installation. This is
agent-plugin evidence; editor/VS Code extensions are a separate facility.
No real host plugin, configuration, credential, or session was changed.
Lifecycle probes used disposable profiles under `/private/tmp`, with a separate
`HOME` supplied only to each fixture subprocess.

## Native management surfaces

`agy plugin --help` and `agy plugin help` expose exactly:

```text
agy plugin list [--json]
agy plugin import [source]
agy plugin install <target>
agy plugin uninstall <name>
agy plugin enable <name>
agy plugin disable <name>
agy plugin validate [path] [--strict] [--json]
agy plugin link <mp> <target>
agy plugin help
```

Both parent `agy plugin --help` and `agy plugin validate --help` write help to stderr
with exit code 0 in 1.4.7. Capability verification must inspect both output streams.

Only `validate --help` is a verified subcommand help interface. Other
subcommands can interpret `--help` as their target. Verify this host through
the group help, rather than probing mutation subcommands with help flags.

| Operation | Verified native contract / boundary |
| --- | --- |
| Install | `<target>` accepts an official catalog name, `name@antigravity-plugins-official`, GitHub repository URL, or local directory. No scope flag. A local fixture was staged under the shared user root below. [Plugin guide](https://antigravity.google/docs/plugins/). |
| Enable / disable / uninstall | Argument is the **install directory name**, including signed numeric directory names; it is not necessarily manifest `name`. Isolated `-12345` directory targets work directly without `--`. No project-scope flag is exposed. |
| List | JSON is an array of objects with `name`, `enabled`, optional `version` and `source`, `path`, and component-name arrays such as `skills`, `agents`, `rules`, `mcpServers`, `hooks`. Missing arrays can be omitted. It includes shared App-installed plugins. A fixture project plugin did not appear, so this is not authoritative project discovery. |
| Import | `gemini` and `claude` are accepted sources. With no argument, an empty isolated profile prints `No gemini extensions found.` followed by `No claude extensions found.` and exits 0; each explicit source scans only that source. Error text also mentions an invalid path, but local-path import semantics were not established. |
| Validate | Path defaults to current directory and may be a directory or manifest. JSON contains `dir`, `manifest`, `name`, `agentPluginsSpec`, `components` counts, and `findings` with `severity`, `file`, `message`. Errors fail; warnings fail only with `--strict`. It inspects authored files without starting an agent session. |
| Link | Exactly two positional arguments, `<mp> <target>`. Help calls it “Generate link to a marketplace.” No supported marketplace value or successful output was established; `antigravity-plugins-official`, `gemini`, `claude`, and `codex` were rejected as unknown marketplaces. Do not invent further semantics or flags. |
| Update / catalogs | No shell `update`, marketplace add/remove/list/refresh/search, or scope commands appear in this baseline. Catalog search, MCP configuration forms, and native authentication remain host workflows. |

The CLI's interactive `/plugin` (`/plugins`) offers Installed/Discover search,
details, install, uninstall, enable/disable, and install from a local directory.
The App provides the corresponding Customizations / Marketplace / Installed
pages. App installations sync to the CLI and receive automatic updates; this
does not establish a separate manual update command.
[Marketplace guide](https://antigravity.google/docs/marketplace/),
[CLI features](https://antigravity.google/docs/cli/features/).

`list --json` finished as an inventory command without opening an interactive
agent session in these probes. No hook/MCP execution was observed; that is not
a proof of every possible host implementation's external effects or runtime
health. Passive startup should continue to read files and reserve CLI execution
for an explicit operation.

## Local state, identity, and capture boundaries

Current v1.4.7 native fixture install wrote:

```text
~/.gemini/config/plugins/<manifest-name>/plugin.json
~/.gemini/config/import_manifest.json
```

Enable/disable wrote `~/.gemini/config/config.json`:

```json
{"plugins":{"<install-directory>":{"enabled":false}}}
```

That preference overrides manifest `disabled`; otherwise most plugins default
enabled, with host exceptions for plugins awaiting required configuration.
The preference is global and keyed by directory, so it can affect a matching
directory id across discovered roots. Treat workspace applicability separately
from the user's enablement preference. First-party installed guide:
`~/.gemini/antigravity-cli/builtin/skills/agy-customizations/docs/plugins.md`.

The import manifest observed after native local install was:

```json
{"imports":[{"name":"native","source":"antigravity","importedAt":"2026-10-26T06:46:24Z","components":null}]}
```

CLI uninstall removed its payload, import record, and enablement entry, leaving
empty maps/lists. `source: "antigravity"` is an import classification, not proof
of a marketplace association. The live `installed_version.json` files contained
only `{"version":"..."}`; neither file establishes a source repository or
catalog identity.

Additional read/capture roots include project `.agents/plugins/` and
`.agents/plugins.json`, shared `~/.gemini/config/plugins.json`, legacy
`~/.gemini/antigravity-cli/plugins/`, and discovered `/builtin/plugins/`
directories. The public CLI location examples still point at the legacy CLI
root, whereas v1.4.7 isolated install uses the shared root. Preserve both as
discovery evidence; do not redirect native writes to match stale prose.
[Manual discovery and documented CLI locations](https://antigravity.google/docs/plugins/).

The local official catalog cache is:

```text
~/.gemini/antigravity-cli/cache/marketplaces/antigravity-plugins-official/
  marketplace.json
  meta.json
```

Observed non-secret schema:

```json
{"name":"antigravity-plugins-official","description":"...","plugins":[
  {"name":"firebase","displayName":"Firebase","version":"1.0.3",
   "description":"...","author":{},"repository":"https://github.com/firebase/agent-skills",
   "source":{"type":"archive","url":"https://www.gstatic.com/antigravity/plugins/...","sha256":"..."}}
]}
```

`meta.json` contains `lastModified`. This is a cached catalog, not installation
provenance. Matching names do not justify associating an installed plugin with
that catalog. Capture the native cache/config/payload paths relevant to each
reviewed action, including absent paths and symlinks; do not invent a Sukiru
installation ledger.

## Components and configuration

Runtime manifests support root `plugin.json`,
`.antigravity-plugin/plugin.json`, or `.gemini-plugin/plugin.json`; filenames
are case-insensitive in the verified release. JSONC comments/trailing commas
are accepted. App/runtime manifests may omit `name` and use the directory;
native CLI install rejects a nameless manifest. Public schema is narrower than
the newer loader: do not reject host extensions solely because the published
schema lists only name/description.
[Plugin manifest reference](https://antigravity.google/docs/plugins/),
[CLI release notes](https://antigravity.google/docs/changelog?tab=cli),
first-party plugin skill `~/.gemini/antigravity-cli/builtin/skills/plugin/SKILL.md`.

| Component | Native location / declaration |
| --- | --- |
| Skills | `skills/<name>/SKILL.md`; root `skills.json`; explicit manifest `skills` paths. |
| Rules | `rules/*.md`, including `rules/AGENTS.md`; root `rules.json`. Root `AGENTS.md` is not a plugin rule. |
| Subagents | `agents/*.md`; root `agents.json`. |
| MCP | Root `mcp_config.json`, `{"mcpServers":{"id":{"command":"...","args":[],"env":{}}}}`; remote entries can use `url` (legacy `serverUrl` also accepted in installed guide). Required variables, credentials, OAuth, and restart/configure are host workflows. Do not expose configured secret values. |
| Hooks | Root `hooks.json`. `hooks/hooks.json` is not loaded for native plugins; pure Claude/Gemini imports can stage it to the root. A Claude-style top-level `hooks` wrapper is not the native event layout. |
| Sidecars | `sidecars/<id>/sidecar.json`; root `sidecars.json` is recognized by current validator. Separate sidecar enablement below. |
| Context providers | Agent Plugins manifest extension `extensions["com.google.antigravity"].contextProviders`; current validator recognizes these declarations. |
| Executables / data | Plugin `bin/` tools and host-provided `PLUGIN_DATA`; these are executable behavior/persistent data, not additional lifecycle shell verbs. |

Installed primary component guides are
`~/.gemini/antigravity-cli/builtin/skills/agy-customizations/docs/plugins.md`,
`~/.gemini/antigravity-cli/builtin/skills/agy-customizations/docs/mcp_servers.md`,
`~/.gemini/antigravity-cli/builtin/skills/agy-customizations/docs/hooks.md`.
Later declarations and validation behavior appear in the
[CLI changelog](https://antigravity.google/docs/changelog?tab=cli).
`commands/` and `workflows/*.md` are explicitly not loaded plugin components;
legacy extension commands are converted to skills during import.
[Migration guide](https://antigravity.google/docs/cli/gcli-migration/).

The installed first-party JSON guide explicitly gives this shared schema for
`skills.json` and `plugins.json`:

```json
{"inherits":[{"path":"/shared/plugins.json","include_only":["wanted"],"exclude":["old"]}],
 "entries":[{"path":"pool","exclude":["experimental-.*"]}]}
```

Entries scan one level deep; nested items can be named explicitly in
`include_only`. Every `.agents/` between cwd and project root can declare
configuration. `~/` and absolute paths are supported. The same guide calls
relative paths both “relative to the directory containing the dot-dir, with a
project-root fallback” and “repository-root relative”; retain this ambiguity.
It calls include/exclude strings “patterns” without defining regex anchoring.
An isolated `validate` probe reported all three authored skill definitions
unchanged for regex-like and glob-like excludes, so validator counts cannot
prove filtered runtime membership. The exact matcher/anchoring is unverified.
Do not claim an independently reproduced anchored-regex contract. Root
rules/agents/sidecars declaration support is established, but a complete
public schema for each was not located.
`~/.gemini/antigravity-cli/builtin/skills/agy-customizations/docs/json_configs.md`.

A context-provider declaration in the first-party catalog's
[`gdrive` 0.0.7 archive](https://www.gstatic.com/antigravity/plugins/gdrive/gdrive.zip?v=fe3f498c8a76)
uses:

```json
{"extensions":{"com.google.antigravity":{"contextProviders":{
 "drive":{"trigger":"drive","label":"Google Drive","iconUri":"https://...",
          "command":["${PLUGIN_ROOT}/skills/gdrive/scripts/gdrive","context-provider"],
          "debounceMs":300,"options":["multi-word"],"uriPatterns":["regex"]}
}}}}
```

This identifies a component surface, not a verified complete schema or a
standalone management API; native validation remains authoritative.

Sidecar `sidecar.json` has one of `command` or `builtin` (`schedule`), plus
optional `args`, `restart_policy` (`always`, `on-failure`, `never`),
`description`, `env`, and `display_name`. Its separate disabled-by-default
preference is:

```json
{"sidecars":{"<plugin-directory>/<sidecar-directory>":{"enabled":true,"projectId":"..."}}}
```

It lives in shared `config.json`; runtime data/logs/events are under
`~/.gemini/antigravity/sidecar_data/<id>/`. There is no verified `agy plugin`
command for sidecar enablement or project registration. Keep their
configuration in native host workflows rather than synthesizing lifecycle
commands or silently editing their source/config files.
[Sidecar schema and lifecycle](https://antigravity.google/docs/sidecars/).

## First-party App RPC (documented locally, not exercised)

The bundled plugin skill documents a local Connect service at
`http://${ANTIGRAVITY_LS_ADDRESS}/exa.language_server_pb.LanguageServerService/<Method>`,
JSON request body, and `x-codeium-csrf-token: ${ANTIGRAVITY_CSRF_TOKEN}`.
This requires an existing host endpoint; no host was launched to obtain it.

| Method | Body / documented semantics |
| --- | --- |
| `GetAllPlugins` | `{"workspaceUris":["file:///workspace"]}` (or `{}`). Includes workspace discovery and **full skill text**, so filter before rendering. Fields include `name`, `path`, `disabled`, `isGlobal`, `skills`, `agents`, `rules`, `hooksJson`, `mcpServers`. |
| `JetboxWriteState` | `{"userConfig":{"plugins":{"<directory>":{"enabled":true}}}}`; deep merge, live reload. The skill explicitly advises this native write over hand-editing `config.json`. |
| `DeletePlugin` | `{"pluginId":"<directory>"}`. Builtins cannot be deleted. Unlike observed CLI uninstall, this guide warns that App deletion leaves the enablement entry, and advises enabling a disabled plugin before deletion. |
| `InstallCustomization` | `{"id":"<marketplace-id>"}`. ID comes from the App Marketplace, cannot be derived from manifest name, and new directories require restart. |

Marketplace directory IDs can be signed 64-bit hashes and differ from names.
These RPCs are first-party installed guidance, not a verified public versioned
API; CLI lifecycle remains the externally verifiable shell contract. Source:
`~/.gemini/antigravity-cli/builtin/skills/plugin/SKILL.md`.
