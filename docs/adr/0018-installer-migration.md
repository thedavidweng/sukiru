# 0018: Installer migration delegates both halves to the official CLIs

- Status: Accepted
- Date: 2026-11-05
- Spec: [GitHub issue #83](https://github.com/thedavidweng/sukiru/issues/83)

## Context

The two installers are not interchangeable in practice: `gh skill` places a
skill for hosts whose global folders `npx skills` bypasses, and `npx skills`
covers agents `gh skill` may not. Until now, switching a skill between the
ledgers meant a manual uninstall and re-install (re-typing the repository and
the target hosts), or deliberately creating a double booking from the terminal
and repairing it in Health.

Sukiru already reads complete provenance from both ledgers — the Vercel lock's
`source`, `ref` and repo-relative `skillPath`, and the `metadata.github-*`
frontmatter — and already repairs double bookings in both directions
(`arbitrate` with `keep-vercel` / `keep-github`). Migration is therefore the
same command shapes applied to a skill one ledger owns alone.

## Decision

- Migration is one Library request (`LifecycleAction.migrate`) planned through
  the existing Command Batch: one confirmation, one snapshot, the shared
  rollback. No new executor, ledger or planner layer.
- **Vercel → GitHub** is the keep-GitHub arbitration shape generalized to a
  single-owned skill: the danger-flagged
  `npx skills remove <name> (-g|-p) -y` first, then
  `gh skill install <owner/repo> <skillPath> --force --dir <dir>` for **every
  skills folder the skill held**, links included. The removal deletes all
  placements, so each folder must be rebuilt or that host silently loses the
  skill.
- **GitHub → Vercel** is one
  `npx skills add <owner/repo> --skill <name> [-a <host>…] [--copy] (-g|-p) -y`
  — the same overwrite the keep-Vercel arbitration relies on. Rewriting the
  skill's files erases the `metadata.github-*` provenance and the Vercel lock
  records the skill; gh has no uninstall command and none is needed, because
  its ledger entry lives in those files.
- **Removal precedes installation.** `npx skills remove` deletes by name at
  discovery level across ownership, so an install-first order would have npx
  delete the fresh gh copy; a scoped `-a <host>` removal keeps the other
  placements **and the lock record**, so it cannot drop the ledger entry. The
  transient unavailability window is covered by the batch snapshot.
- The destination follows ownership (ADR-0002): no backend setting, and the
  current owner decides which commands run. Adoption (ownerless) and
  arbitration (double-booked) stay separate requests.
- Recorded provenance is the only source of coordinates. The move is withheld
  with a reason when the record lacks what the destination needs (a GitHub
  source with repo-relative `skillPath`; a `github-repo`), when the
  destination CLI is missing, when the skill is pinned (the Vercel ledger has
  no pin), or when the gh write would cost another Vercel record data
  (`githubWriteBlocker`).
- Entry points: the Library inspector button, row and group context menus, and
  `sukiru skills migrate NAME --installer vercel|github`, under the existing
  dry-run, confirmation and danger-acknowledgement rules.

## Considered options

- **Order the steps install-first, then remove.** Rejected: npx would delete
  the gh copy it just installed, and no CLI can drop only the Vercel record.
- **Re-link every host folder after the gh installs** (gh copy, then
  `relink` to the shared copy). Rejected: the relink command's "discards local
  changes" disclosure is computed from the pre-move state and would warn
  falsely, while identical copies are gh's own layout and the existing
  copy-instead-of-link fix repairs them on demand.
- **Bulk migration (`--all`).** Deferred: provenance quality varies per skill,
  so a bulk command that silently skips half the selection adds nothing over
  repeated single moves.
- **A `skills transfer` verb.** Rejected in favor of the existing vocabulary:
  a `migrate` command with the same `--installer` choice `skills adopt` uses.

## Consequences

- A skill that held several skills folders ends up with one real copy per
  folder after moving to the GitHub ledger. Those identical copies are the
  existing "copy instead of link" problem and are repairable with the existing
  relink fix; Sukiru does not create links gh would not create (its ledger
  record travels in the copy).
- Moving to the Vercel ledger resets content to the recorded repository's
  default branch, since the Vercel ledger records no pin. Pinned skills are
  refused rather than silently unpinned.
- The verified command shapes for both directions are recorded in
  [`docs/collision-matrix.md`](../collision-matrix.md) (2026-11-05 follow-up),
  and the real-CLI suite exercises a Vercel → GitHub → Vercel round trip in an
  isolated home.
