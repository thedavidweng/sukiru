# ignore-list — expectation

Contents: `.agents/skills/` holds ONE real skill (`real-skill`) plus noise
containers that must never become placements: `node_modules/`, `__pycache__/`,
`.archive/`, and an unknown dot-dir `.hidden-junk/` (each carrying a
valid-looking SKILL.md), `dist/` and `build/` (non-skill files), and — in
generator output only — `.git/` (git refuses to track a `.git` path component,
so the checked-in tree lacks it; the assertion is unchanged either way).

A correct scan MUST exit 0 and inventory EXACTLY ONE placement: `real-skill`.
No ignored container may surface as a placement or skill.
