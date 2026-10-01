# FIX-DIRTY-SUITE — expectation

One tree triggering several rules at once, with findings in BOTH scopes:

- user scope (`.home`, claude-code detected via config.json):
  `rotted-link` dangling symlink -> `broken-symlink` (action);
  `gh-owned` github-provenanced -> `dangerous-removal-surface` (action);
  `user-orphan` no ledger -> `files-without-lock` (info).
- project scope (`proj`):
  `drifted` edited after install -> `vercel-lock-drift` (action);
  `proj-orphan` no ledger -> `files-without-lock` (info).
- `.qoder/` contains ONLY an empty `skills/` entry: CLI spray residue, a
  leftover workspace (installed=false) with ZERO placements and ZERO
  findings — the Health workspace filter's reachable empty state.

Scan with SUKIRU_HOME=<this>/.home SUKIRU_ROOTS=<this>/proj.

A correct scan MUST exit 0 with exactly these SEVEN findings: the five above
PLUS a `dangerous-removal-surface` advisory for each ownerless name
(`user-orphan`, `proj-orphan`) — the advisory fires on gh-owned AND
ownerless skills, but not on `rotted-link`: a dangling link holds no
SKILL.md, so `npx skills remove` cannot match it. Two severity levels render (action + info);
the dangling link additionally surfaces as a `broken-symlink` ISSUE. Each
finding carries its rule's concrete evidence. Ownership: gh-owned=github,
drifted=vercel, the two orphans and rotted-link=ownerless. The app drives
its grouped-findings, severity-display, per-workspace filter,
keyboard-disclosure, and selection-persistence assertions off this tree.
