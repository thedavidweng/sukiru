# FIX-MUTABLE — expectation (M3 health-area, VAL-HEALTH-035/036)

Contents: one vercel-owned user-scope skill `greet` (global v3 lock) — a
zero-findings clean tree. Validators COPY this tree, launch the app against
the copy, mutate the copy on disk mid-session (add/remove a skill), and
assert: nothing changes without explicit Refresh (no watchers); after
Refresh (Settings control or keyboard shortcut) the new disk state renders.

A correct scan of the UNMUTATED tree MUST exit 0 with exactly one skill,
ownership=vercel, zero findings, zero issues.
