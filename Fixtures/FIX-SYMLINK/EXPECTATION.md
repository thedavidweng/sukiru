# FIX-SYMLINK — expectation

Contents: in the claude-code host dir (detected via config.json), a DANGLING
symlink `.claude/skills/rotted -> /nonexistent/rotted-target`; plus `tool` in
the canonical store (global v3 lock) with a PHYSICAL copy at
`.claude/skills/tool` where the managed layout implies a symlink — a
double-copied impostor.

A correct scan MUST exit 0 and report:
- a brokenSymlink placement `rotted` (null canonical path/hash) AND a
  `broken-symlink` finding (severity action) naming the link path and its
  unreadable target — the link also surfaces as a `broken-symlink` ISSUE (no
  `dangerous-removal-surface` advisory: `npx skills remove` cannot match a
  link without SKILL.md);
- a `symlink-authenticity` finding (severity warning) naming the impostor path
  (`.claude/skills/tool`) and the canonical path it should link to;
- an exact-subtype `cross-host-duplicate` (warning) for the two identical
  physical copies of `tool`;
- `tool` stays ownership=vercel (the lock claim is intact).
