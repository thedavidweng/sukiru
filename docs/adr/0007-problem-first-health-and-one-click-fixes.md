# 0007: Present Health as problems, fix in one click, confirm once per batch

- Status: Accepted (amends the review step in ADR-0004)
- Date: 2026-10-01

## Context and decision

The old Health view listed findings by detection rule ID, so users could not
tell what had happened or what to do. Every repair had to go through Pending
Changes, with each command marked as reviewed, and there was no Fix All. A scan
of a real machine produced 466 findings: 153 were healthy layouts (alias links
into the shared directory) and 100 were standing notices, burying the real
problems.

Drawing on `npx skills` (shared directory plus links by default, automatic
copies for a single host), cc-switch, and magpie (shared store plus links,
copy fallback, backup before changes), we decided:

- **Problem catalog (`ProblemKind`).** Rules map to problem kinds in user
  language: stale lock record, broken link, copy instead of link, diverging
  copies, unknown source, owner conflict, newer lockfile version, and notes.
  Healthy layouts and standing notices go to Notes, which are collapsed by
  default and not counted as problems. Each kind has explanatory copy and a
  default one-click fix.
- **One-click fixes and Fix All.** `CommandBatchBuilder.buildApplicable` builds
  leniently: whatever can be fixed goes into one batch, and items that need a
  user choice are listed as "not included" without blocking the rest.
- **One confirmation per batch replaces per-command review.** Each batch shows
  one confirmation sheet that summarizes the changes in plain language, with
  the commands available in an expandable section. Snapshots and one-click
  rollback are unchanged, and the result page offers undo right away. The
  safety value of per-command review is covered by snapshot and rollback,
  while its cost made repairing hundreds of stale records unusable.
- **Direct file operations extend to link management.** Ledger writes still go
  only through the official CLIs (the ADR-0001 red line is unchanged). Disk
  layout operations that no CLI can perform go through `sukiru-fileop`, with
  danger flags, snapshot protection, and a path-containment pre-check:
  deleting a broken link (`delete-link`), replacing a copy with a link to the
  shared copy (`relink`), turning a link into a copy (`materialize`), and
  removing a leftover host folder (`remove-leftover-skills-dir`).
- **Leftover host folders (`leftover-host-dir`).** `npx skills add` creates a
  skills folder for every host it knows, installed or not. A user-scope host
  folder of an uninstalled host that holds only links is a problem; its fix
  deletes the folder, plus its parent when only Finder files remain, since an
  empty host config folder reads as an installed host. The operation
  re-checks at run time that only links remain, and rollback recreates the
  folders and links. A leftover folder holding a real copy is never flagged.
- **The Health filter is per scope.** Most rules attribute findings to the
  user scope or a project, not a host folder, so a per-host filter showed
  every host as clean. The filter offers All, User scope, and each project.
- **Stale lock records use `npx skills remove <name> -g -y`.** Testing showed
  it removes both the lock record and leftover links. Only broken links with
  no lock record, which `npx` cannot handle, use `delete-link`.
- **Agent-managed skills (`Ownership.agent`).** Skills in directories that a
  host manages with its own records, Hermes (`.bundled_manifest` /
  `.hub/lock.json`) and Codex (`.system/`), are labeled "managed by agent",
  excluded from duplicate, impostor, and divergence problems, and shown but
  never repaired.
- **Switching between link and copy.** Library switches mode per skill
  (`buildModeSwitch`). The Health fix for "copy instead of link" turns the copy
  back into a link. Settings offers "Install new skills as copies"
  (`npx skills add --copy`).
- **Skills with unknown sources.** Sukiru looks up the name on skills.sh to
  suggest candidate sources, and the user can also enter any `owner/repo` or
  URL. Adoption into the Vercel ledger runs
  `npx skills add <source> --skill <name> -a <hosts…>`. The user can also
  delete the skill instead.

## Considered options

- **Keep per-command review and only add Fix All.** Rejected. 111 stale lock
  records would mean 111 clicks, which is no Fix All at all.
- **Have Sukiru rewrite lockfiles to remove stale records.** Rejected. It
  violates the zero-ledger red line, and `npx skills remove` already does it.
- **Convert copies to links by reinstalling with `npx skills add`.** Rejected.
  It needs the network and a source, and does nothing for copies with unknown
  sources or agent-managed copies. A local relink can be snapshotted and
  rolled back.

## Consequences

- Pending Changes keeps only the repair decision panel and execution results.
  Inspecting individual commands moves into the expandable command section of
  the confirmation sheet.
- `relink` can replace a copy whose content differs (danger flag
  `discardsLocalChanges`); the confirmation sheet lists a separate line saying
  local changes will be discarded.
- Agent-managed directories are treated as read-only facts. If a host changes
  its record format, detection must follow.

## Amendment (2026-11-05): a host's missing global link is an action, not a Problem

Issue #82 asked Health to flag every global skill without a link in
Antigravity's global folder, then let the user deploy the chosen ones. The
underlying defect is real, but the detection half is wrong for this product.

The pinned installer returns the shared store for a universal agent's global
install before it creates the agent's link (`isGlobal && isUniversalAgent`), so
`npx skills add … -g` fills only `~/.agents/skills`. That affects every
universal agent whose global folder differs from the shared store (Cursor,
Gemini CLI, GitHub Copilot, OpenCode, Droid, Antigravity, …), not only
Antigravity, and it is still present in `skills` 1.7.6. The fix cited by the
issue (vercel-labs/skills#2567) is unrelated; #1851 and #1874 remain open.

An agent holding a subset of the shared store is a legitimate choice, and no
ledger records which agents a global install was meant to target. Making the
missing links Problems would repeat ADR-0007's original failure (hundreds of
findings over a healthy layout) and would invert the glossary's Shared Copy
expectation: a link is wanted where the user wants the skill, not everywhere.

Decisions:

- **Deployment is user-initiated.** `HostLinkPlanner` lists the detected
  hosts whose global folder can receive a user-scope Skill's shared copy; the
  Library's Hosts section offers them in a "Link into Agent…" menu, and
  `sukiru skills link NAME --host ID` does the same. Nothing is detected as a
  Problem, counted in Health, or included in Fix All.
- **One new direct file operation, `sukiru-fileop link <path> <target>`.** It
  creates a symlink only where no entry exists (refusing to overwrite), creates
  the host folder when the agent never made one, and writes no ledger. Like the
  other link operations it is danger-flagged and runs inside the batch snapshot;
  rollback deletes the link and any folder the batch created.
- **Only detected hosts.** Leftover spray folders are never deployment targets,
  matching the leftover-host-dir rule. Only user-scope Skills with a real
  shared-store copy qualify; project deployment is out of scope.
- **Antigravity's folders follow the vendor, not the installer.** Every
  Antigravity surface reads `~/.gemini/config/skills`; the IDE also reads legacy
  `~/.gemini/antigravity/skills`, and the CLI also reads
  `~/.gemini/antigravity-cli/skills` and `~/.gemini/skills`. The host table now
  names the documented folder as the global read root, keeps the two installer
  folders as read-only legacy roots, and records them as the installer's own
  path (`installSkillDirRelative`), so host-removal planning still models the
  folder `npx skills remove` cleans. Links Sukiru deploys into the documented
  folder are therefore outside the installer removal surface; rollback or
  deleting the link covers undo. A personal discovery manifest and the CLI's
  extra folders are documented alternatives to per-skill links.
