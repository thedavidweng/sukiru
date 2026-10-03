# Sukiru

Formerly Gino (see ADR-0003). A native macOS app that reads the two official
installer ledgers plus disk facts, then detects and repairs messy agent skill
libraries. All ledger writes are delegated to the official CLIs; Sukiru keeps
no ledger of its own. Decisions are recorded in [`docs/adr/`](docs/adr/README.md).

## Language

Each term lists the Simplified Chinese (`zh-Hans`) term used in the UI and
the words to avoid.

**Agent Skill** (技能):
A directory containing a `SKILL.md`: the portable instruction unit defined by
the agentskills.io specification. A host activates it through its frontmatter.
_Avoid_: plugin, capability

**Agent Plugin** (插件):
A host-recognized extension package that forms one management unit and may
contain skills or other components. Its components are not independently
managed unless the host exposes that granularity.
_Avoid_: skill, Agent Skill

**Plugin Installation** (插件安装实例):
A plugin installed for one host in one concrete user or project scope. Its
identity includes its source and the host's plugin identifier; installations
from different sources or in different projects remain distinct.
_Avoid_: skill placement

**Plugin Enablement** (插件启用配置):
The configured choice to enable or disable a plugin in a host and scope.
This choice does not establish that a running session has loaded the plugin.
_Avoid_: loaded, running

**Plugin Load Status** (插件加载状态):
Evidence of whether a plugin loaded in a particular host runtime or session.
Without such evidence the status is unknown, even when the plugin is enabled.
_Avoid_: installed, enabled

**Agent Host** (宿主):
A coding agent that consumes Agent Skills or Agent Plugins (Claude Code,
Codex, OpenCode, Cursor, …). A host may also manage its own plugin installations.
_Avoid_: platform, client

**Ledger** (账本):
An installation manager's private install record: what was installed, from
where, at which version, and for whom. The manager may be a standalone installer
or an agent host; Sukiru keeps no ledger of its own.
_Avoid_: metadata, record

**Vercel Ledger** (Vercel 账本):
The ledger of the Vercel CLI (`npx skills`), kept in separate lockfiles
(project `skills-lock.json`; global v3 lock `~/.agents/.skill-lock.json`).
Skill files stay byte-identical to upstream; the record lives beside them.

**GitHub Ledger** (GitHub 账本):
The ledger of `gh skill`, written at install time into the `SKILL.md`
frontmatter as `metadata.github-*` (repo, path, ref, pinned, tree-sha). The
record travels with the skill.

**Companion Record** (伴随记录):
The entry every `gh skill` install or update also writes into the Vercel
ledger's global lock, keyed by bare skill name, "for interop" (gh
`internal/skills/lockfile`). It is recognized by gh's write signature
(whole-second UTC timestamps, only gh's fields) and belongs to the GitHub
ledger: a skill whose only Vercel-lock record is a companion is
GitHub-owned, not double-booked.

**Provenance** (溯源):
The part of a ledger entry that identifies the source: repository, ref, and
content hash.
_Avoid_: source info

**Ownerless Skill** (野技能):
A skill that neither ledger records (copied by hand or placed by a script).
Hosts can still use it, but no installer can update or cleanly uninstall it.
It is the main target of repair.
_Avoid_: not installed, Untracked Skill (retired term from the old spec)

**Drift** (漂移):
Disk facts and ledger records disagree. Example: after a `gh` update, the
content hash in the Vercel lock is stale, or the reverse.
_Avoid_: inconsistency

**Ownership** (归属):
Which ledger claims a skill. It is a fact determined by ledger records, not a
user preference. Repairs and updates are routed to the official CLI that owns
the skill.
_Avoid_: backend choice, global backend

**Adoption** (收编):
Bringing an ownerless skill under a ledger so it becomes manageable. Example:
interactive `gh skill update` asks for the source and injects provenance.
Adoption requires choosing a ledger, so it is a user decision.
_Avoid_: import

**Double-booked** (双重记账):
Both ledgers claim the same skill. The repair must let the user decide which
ledger to keep; there is no objectively correct answer.

**Command Batch** (命令批次):
A sequence of commands to run and their expected effects. It contains
official CLI commands, plus link-management file operations that no CLI can
perform. The whole batch is confirmed once before it runs, is wrapped in a
snapshot, and can be rolled back (ADR-0007). The UI keeps the name
"Pending Changes".
_Avoid_: file-operation plan (retired meaning)

**Agent-managed Skill** (宿主自管技能):
A skill in a directory that a host manages with its own records (Hermes
`.bundled_manifest` / `.hub/lock.json`, Codex `.system/`). Its ownership is
`agent`; Sukiru shows it but never repairs it.
_Avoid_: built-in skill

**Problem** (问题):
A user-facing kind of issue that one or more detection findings roll up into
(for example a broken link, or a copy where a link belongs). Each kind has an
explanation and a default one-click fix (ADR-0007). Healthy layouts and
standing notices are Notes, not problems.
_Avoid_: finding (a Finding is the raw output of the rule layer)

**Shared Copy** (共享副本):
The real skill directory in the scope's shared skills directory
(`~/.agents/skills` or the project's `.agents/skills`). Each host directory
should hold a link to it.
_Avoid_: canonical, store
