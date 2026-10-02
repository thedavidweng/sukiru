# 0004: v1 product contract: full local read side, command-batch safety model, health check first

- Status: Accepted (the review step is amended by ADR-0007)
- Date: 2026-09-14

## Context and decision

This is the concrete shape of the zero-ledger red line (ADR-0001), decided in
one batch in the 2026-09-14 design review:

- **The read side is built entirely in-house.** Both ledger schemas (Vercel
  `skills-lock.json` v1 and the global v3 lock `~/.agents/.skill-lock.json`;
  `gh` `metadata.github-*`), `SKILL.md` frontmatter parsing, and the host
  directory table absorbed from the archived `agents.rs`. (The decision record
  originally cited 116 hosts; the absorbed table in `research/host-table.json`
  has 56, from `vercel-labs/skills@1.5.9`.) Sukiru does **not** check for
  remote updates; that is the job of `gh skill update --dry-run` and
  `npx skills update`, and we do not build a second updater. Sukiru does
  **not** build a planner that predicts write-side diffs (red line: no
  write-side protocol knowledge).
- **Safety model.** Every command batch is forced through snapshot → execute
  → post-run diff → one-click rollback (carried over from the old spec, kept
  on the archive branch). File operations on ownerless skills may run
  directly (there is no ledger to touch, and the snapshot protects them).
- **Dependencies.** Require `gh` ≥ 2.90.0. On the Vercel side, probe whether
  `npx skills` resolves, with the version number as a secondary signal. Bundle
  nothing: never install a runtime automatically; degrade per ADR-0002 when a
  tool is missing.
- **v1 detection rules.** Duplicates across hosts; real versus broken
  symlinks; Vercel lock drift (recompute `computedHash` and reconcile); `gh`
  provenance presence and pin display; locked but missing on disk; on disk
  but not locked; double-booked. Detecting kitter / aghub leftovers is
  deferred to v2.
- **MVP milestones.** Ship the read-only health check first (zero write risk,
  validates demand early), then repair orchestration, then new installs.

## Consequences

- Repair correctness depends on read-side ownership decisions. The collision
  matrix experiments (controlled mixed installs with the real CLIs, see
  [`docs/collision-matrix.md`](../collision-matrix.md)) calibrate the
  assumptions behind the detection rules.
- "Review before writing" takes the form of command preview + post-run diff +
  rollback, not a predicted file-level diff.

## Calibration from experiments (2026-09-14 collision matrix)

Two rules were added to the list above, both confirmed by controlled
experiments:

- **Shared copy / host copy divergence.** In copy mode, `gh --force` changes
  only the host copy and leaves the `.agents/skills` shared copy untouched.
  The two copies drift apart and neither tool warns.
- **Dangerous-removal warning.** `npx skills remove` deletes by name at
  discovery level and crosses ownership (it deleted a `gh`-only skill in the
  experiment). Dispatching it requires a warning and snapshot protection.

Factual corrections: a double-booked skill is detected as a skill name that
has both a Vercel lock entry and `gh` frontmatter provenance; non-interactive
`npx skills add -y` defaults to copy mode; the two installers use different
discovery rules for the same source repository (`gh` fails to discover skills
under a maintenance-style path prefix).

## Amendment (2026-10-02): uninstalling a GitHub-ledger skill

`gh skill` has no uninstall command. The `gh` ledger record lives in the
skill's own `SKILL.md` frontmatter, so deleting the skill's placements also
deletes its ledger entry without writing to any ledger. A Library uninstall
of a GitHub-ledger skill is therefore a flagged direct file operation: links
are removed as links (never followed), then directories are deleted, all
inside the batch snapshot. Vercel-ledger uninstalls still go through
`npx skills remove`. The same direct deletion removes a GitHub-ledger skill
when a Health fix cleans it up, so that path no longer needs Node.js.

## Amendment (2026-10-02): `gh` writes the Vercel global lock

The follow-up experiment in
[`docs/collision-matrix.md`](../collision-matrix.md) showed that `gh skill`
install and update also write the Vercel global lock, keyed by bare skill
name. Consequences for v1:

- Sukiru runs `gh skill update --dry-run` as a read-only update check
  ("Check for Updates"); it writes nothing.
- A `gh skill update` is withheld when the skill is user-scope or when a
  user-scope skill of the same name has Vercel provenance, because the write
  would rewrite that Vercel record. Pinning, unpinning, and forced reinstall
  through `gh` rewrite the same record and are not offered.
- `gh skill update` is dispatched with `--all` plus the skill names, since
  non-interactive runs refuse to apply updates without it.
- The batch snapshot always captures the global lock, so rollback restores
  any `gh` write to it.
