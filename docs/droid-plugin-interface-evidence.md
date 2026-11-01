# Droid Plugin Interface Evidence

Checked 2026-10-31 against `droid` 1.1.0 and the official pages
[Plugins](https://docs.factory.com/harness/plugins),
[Internal Plugin Marketplaces](https://docs.factory.com/enterprise/internal-plugin-marketplaces),
[Enterprise controls](https://docs.factory.com/enterprise/hierarchical-settings-and-org-control),
[Skills](https://docs.factory.com/harness/skills) and [MCP](https://docs.factory.com/harness/mcp).
Disk layouts below were observed by running the real CLI with `HOME` pointed at an empty
temporary directory; nothing touched a real profile.

## Native commands

`droid plugin --help` lists `install|i`, `uninstall|remove`, `update` and `list`; each takes
`-s, --scope <user|project>`. `droid plugin marketplace --help` lists `add <url>`,
`remove <name>`, `list` and `update [name]`. There is no enable or disable command: the docs
state that enablement lives in `enabledPlugins`. `list` prints a table only, so Sukiru reads
the records below instead.

On 2026-10-31, operation help was rechecked against the installed `droid` 1.1.0:
install specifies `plugin@marketplace` and user/project scope; marketplace add, update,
remove and list show the arguments above and no JSON option. This recheck inspected help
only; it did not establish authentication requirements or execute a mutation.

Sukiru routes:

| Operation | Route |
| --- | --- |
| install, update, remove | `droid plugin install\|update\|uninstall <plugin@marketplace> --scope <scope>`, run in the scope root |
| enable, disable | edit `enabledPlugins["<id>"]` in the scope's `settings.json` |
| marketplace add | `droid plugin marketplace add <source>` (user only; Droid writes user settings) |
| marketplace refresh | `droid plugin marketplace update <name>` |
| marketplace remove | user: `droid plugin marketplace remove <name>`; project: delete `extraKnownMarketplaces.<name>` from that project's settings; org: instructions |

Each command must pass the `--help` check (`Usage: droid plugin <verb>` and `--scope` for
plugin verbs) before it runs. The verified baseline is 1.1.0 within major 1.

## On-disk state

- `~/.factory/plugins/installed_plugins/<id>-<scope>-<hash>.json`:
  `{"schemaVersion":1,"pluginId":"hello@mkt","entry":{"scope":"user","installPath":…,
  "version":"mvx6bkpv","source":"mkt",…}}`. A project-scope record carries no project path.
- `~/.factory/plugins/cache/<marketplace>-<hash>/<plugin>-<hash>/<version>/`: the payload.
  A Claude Code layout arrives translated (`.claude-plugin/` → `.factory-plugin/`,
  `agents/` → `droids/`).
- `~/.factory/plugins/known_marketplaces/<name>-<hash>.json`: `name`, `entry.source`,
  `entry.installLocation`, `entry.lastUpdated`, `entry.autoUpdate`.
- `~/.factory/plugins/marketplaces/<name>/`: Git clones. A local marketplace stays in place.
- Install writes `enabledPlugins["<id>"]: true` to the installing level (`~/.factory/settings.json`
  or `<project>/.factory/settings.json`); `marketplace add` writes user
  `extraKnownMarketplaces`.

Observed behaviour the inventory relies on:

- An id missing from `enabledPlugins` lists as `disabled`. A project install lists as
  disabled outside that project, because the project settings do not apply there.
- `droid plugin marketplace remove` deletes the user declaration and registry record but
  leaves plugins installed from it.
- One id can be installed in only one scope at a time ("Uninstall it first to change scope").
- A local marketplace registers under its directory name, not the manifest `name`.

## Inventory

Installations come from the records; a project record is attributed to each added project
whose settings list the id. Components are read from the payload: `skills/` (recursive,
first directory with `SKILL.md`), `commands/`, `droids/*.md`, `output-styles/*.md`,
`hooks/hooks.json` and `mcp.json` `mcpServers`. Hooks flow into the hook inventory through
the shared plugin path.

Marketplaces come from `extraKnownMarketplaces` at each level (org, user, each added
project), joined with the registry by name for location and fetch time; a registered
marketplace no level declares is shown as user. Catalogs are read from
`.factory-plugin/marketplace.json`, falling back to `.claude-plugin/marketplace.json`.

Org settings come from `/Library/Application Support/Factory/settings.json` when present
(documented as authoritative), else `managedSettings` in
`~/.factory/org-managed-settings.cache.json`, which Droid keeps but does not document. Org
installations offer details only, as `/plugins` does. `strictKnownMarketplaces` and
`strictEnabledPlugins` are reported in the review text; Droid enforces them.

## Capture and rollback

Every Droid command captures `~/.factory/plugins`, `~/.factory/settings.json` and each
added project's `.factory/settings.json`. Install, update and marketplace add or refresh
also capture npm roots, because npm-sourced plugins install through
`npm install --ignore-scripts`. Settings edits
capture only the edited file.
