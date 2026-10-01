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
| 2 | `gh` baseline (exact-path install) | Writes only the host directory. Injects `metadata.github-{path,ref,repo,tree-sha}`. Installing at `main` records `github-ref: refs/heads/main` (a branch name); content identity relies on the tree SHA. No lock. | `gh`'s records travel with the skill ✓ |
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
