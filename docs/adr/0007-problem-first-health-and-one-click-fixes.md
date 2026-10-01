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
