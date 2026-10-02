# Collision matrix experiments

Run on 2026-09-14 in a controlled sandbox (`/tmp/sukiru-cm`; `HOME` isolated
for `npx`, and `gh` wrote only to the sandbox project directory). Test skill:
`stale-docs-cleanup` (source `thedavidweng/skills`). Environment: `gh 2.100.0`,
`npx skills@latest` (Node v24.20.0). This record is factual evidence used to
calibrate the detection rules in ADR-0004.

## Matrix and results

| # | Scenario | Observed result | Implication for the referee |
|---|---|---|---|
| 0 | Discovery rules compared | `npx` deep traversal found 22 skills under the `maintenance/` prefix. `gh` convention-path scanning found 0, reported a "curated list", and could only install with an exact path plus the `SKILL.md` suffix. | **The same source repository is visible differently to each installer.** Missing provenance does not imply an ownerless skill; `gh` may simply be unable to install it. |
| 1 | `npx` baseline (`add -y`, claude-code) | Non-interactive default is **copy mode**: a shared copy in `.agents/skills` plus a copy in `.claude/skills`. The lock (v1) records `source`, `sourceType`, `skillPath`, and `computedHash`. Frontmatter stays identical to upstream. | Vercel's records live entirely in the lock ✓ |
| 2 | `gh` baseline (exact-path install) | Writes only the host directory. Injects `metadata.github-{path,ref,repo,tree-sha}`. Installing at `main` records `github-ref: refs/heads/main` (a branch name); content identity relies on the tree SHA. No project lock (but see the 2026-10-02 follow-up: `gh` also writes the global Vercel lock, which this run did not observe because `HOME` was isolated only for `npx`). | `gh`'s records travel with the skill ✓ |
| 3 | `npx` installs first → `gh --force` double-books | `gh` overwrites the `.claude` copy and injects provenance. The Vercel lock's `computedHash` is unchanged (**now stale**). The `.agents` shared copy is untouched, so **the host copy and the shared copy diverge**. Neither tool warns. | Double booking, lock drift, and copy divergence occur together, all silently. |
| 4 | `npx update -y -p` over the double-booked state | Reports "Updated ✓", but the lock hash is unchanged, the `gh` provenance in `.claude` **survives intact**, and the shared copy is untouched. | `npx update` neither verifies nor rewrites a drifted host copy. With no upstream change, the `gh` record survives (behavior with an upstream change was not tested). |
| 5 | `gh` installs first → `npx add -y` double-books in reverse | `npx` overwrites the `.claude` copy, **silently erasing the `gh` provenance** (grep count 0), and writes the Vercel lock. No shared copy is created (the difference from scenario 1 needs investigation). | The directions are asymmetric: `gh --force` preserves its own record, while `npx add` destroys the other tool's. |
| 6 | `npx remove -y` on a `gh`-only skill (no lock) | **Deletes it**: "Successfully removed 1 skill(s)", and `.claude/skills` is emptied. | `npx remove` **deletes by name at discovery level**, ignoring the lock and ownership. It can wrongly delete `gh`-owned or even ownerless skills. |
| 7 | `gh update --all` on `npx`-only skills | Skips each one with "no GitHub metadata", writes nothing, exits 0. Also confirmed that none of the skills in the user's real home directory have `gh` provenance. | `gh` respects ledger boundaries ✓. The local corpus is purely Vercel-managed. |
| 8 | Ownership view of a mixed project | `gh list`: 1 owned (`.claude`, `sourceURL` = repo) + 1 ownerless (shared copy, `sourceURL` = ""). `npx list`: 1 entry (shared copy, "Agents: Codex, Claude Code"). On disk: one name, three copies, and two ledgers that disagree. | **Ownership must reconcile three sources** (both ledgers plus disk discovery). `gh skill list --json` can help on the read side (an empty `sourceURL` means ownerless to `gh`). |

## Corrections to the v1 detection rules (merged into ADR-0004)

1. **New rule: shared copy / host copy divergence** (caused in copy mode when
   `gh --force` changes only the host copy).
2. **New safety rule: dangerous-removal warning.** Before dispatching
   `npx skills remove`, warn that it deletes by name and may cross ownership
   (confirmed by scenario 6).
3. A double-booked skill is detected as one skill name with both a Vercel lock
   entry and `gh` frontmatter provenance (both directions, scenarios 3 and 5).
4. **Untested variants** (future experiments): collisions in symlink mode (the
   non-interactive default is copy mode), and whether `npx update` erases `gh`
   provenance when upstream really changed.

## Follow-up (2026-10-02): `gh` writes the global Vercel lock

Run with `gh 2.102.0` and `npx skills@latest`, with `HOME` isolated for both
tools. Test skills: `brand-guidelines`, `internal-comms`, `xlsx` (source
`anthropics/skills`).

- Every `gh skill install` and every applied `gh skill update` also writes
  `~/.agents/.skill-lock.json` (version 3, the Vercel global lock), keyed by
  bare skill name, whatever the scope or `--dir`. The `gh` source
  (`internal/skills/lockfile`) says the version must match Vercel's for
  interop. A user-scope `gh` install therefore shows as double-booked, and a
  project-scope `gh` install leaves a global lock entry with no user-scope
  files.
- `gh skill update --force`, `gh skill install --pin <ref> --force`, and
  `gh skill update --unpin` in a project each rewrote the user-scope Vercel
  record of the same name (source fields, hash, timestamps, `pinnedRef`).
  After the pin rewrite, `npx skills update -g` saw a phantom update and
  reinstalled the user copy.
- `gh skill update --dry-run` writes nothing (snapshot diff empty, lock
  included). With `--dir` it scans only that directory and skips symlinked
  entries.
- Non-interactive `gh skill update <names> --dir <dir>` exits 1 with
  "re-run with --all" whenever an update exists; `--all` combined with names
  updates only the named skills.

## Follow-up (2026-10-02, second run): telling gh's records apart

Run with `gh 2.102.0` and `npx skills@1.7.0` (Node v24), `HOME` and the
project isolated per tool. Test skills: `xlsx`, `brand-guidelines`,
`internal-comms` (source `anthropics/skills`, the latter two pinned to an
older commit). Every lock write was captured before and after each command.

- **The write signature.** A record `gh` created stamps `installedAt` /
  `updatedAt` with `time.RFC3339` (UTC, whole seconds, e.g.
  `2026-10-02T20:43:32Z`) and contains only `source`, `sourceType`,
  `sourceUrl`, `skillPath`, `skillFolderHash`, the timestamps, and
  optionally `pinnedRef`. `npx skills` stamps `toISOString()`, always with
  milliseconds (verified in every published `skills` release that writes
  the global lock, 1.1.0 through 1.7.0), and can add `ref`, `pluginName`,
  `sourceBaseUrl`, `wellKnownDigest`. gh's `internal/skills/lockfile` has
  written this way since the `gh skill` scaffold shipped in **gh 2.90.0**
  (2026-04-16), Sukiru's minimum supported gh.
- **gh rewrites the whole file.** One `gh skill install` into a lock npx
  had written dropped the other entries' `ref` and `pluginName` fields,
  the top-level `lastSelectedAgents`, and an empty `dismissed` map, and
  reordered entries (source: `writeTo` re-marshals a struct with only gh's
  fields). An entry npx created survives as an entry but loses those
  fields; its `installedAt` keeps npx's millisecond stamp, so it still
  reads as a Vercel record.
- **`npx skills` acts on gh's records.** `npx skills update -g` (bare) and
  `npx skills update <name> -g` both treat a gh-written entry as their own:
  they compare its `skillFolderHash` against the upstream HEAD tree —
  ignoring `pinnedRef` — and reinstall, which materializes the skill at
  user scope (shared copy plus a copy in every detected host), rewrites
  the record with npx's field set, and erases the gh frontmatter
  provenance from the refreshed copy. A pinned gh install therefore shows
  a phantom update.
- **The project-scope ghost materializes.** A project-scope `gh` install
  leaves a global-lock entry with no user-scope files; the next bare
  `npx skills update -g` installs that skill at user scope even though the
  user never asked for it there. `npx skills remove <name> -g` on such a
  ghost deletes only the entry (no files exist in the scope), but gh
  recreates the entry at the next project install or update.
- **`gh skill update --dry-run` still writes nothing**, and `--from-local`
  installs never touch the lock (`installer.InstallLocal` has no
  `RecordInstall` call).

Consequences for the referee are recorded in ADR-0004's companion-record
amendment: the signature above decides whether a global-lock entry is gh's
companion record (the GitHub ledger's business, not a Vercel claim) or a
genuine Vercel record, ghost companions are notes rather than stale lock
entries, and a gh write is withheld whenever its whole-file rewrite would
drop data `npx skills` needs.

## Evidence samples

Frontmatter of `.claude/skills/stale-docs-cleanup/SKILL.md` after scenario 3:

```yaml
metadata:
  github-path: maintenance/stale-docs-cleanup
  github-ref: refs/heads/main
  github-repo: https://github.com/thedavidweng/skills
  github-tree-sha: 214349b9b6ede59ff72ba15797186668fcfec535
```

The Vercel lock in the same project (not updated):

```json
"stale-docs-cleanup": {
  "source": "thedavidweng/skills",
  "sourceType": "github",
  "skillPath": "maintenance/stale-docs-cleanup/SKILL.md",
  "computedHash": "8844f550…"
}
```
