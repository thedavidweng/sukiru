# FIX-GARBAGE — expectation (defect manifest)

One tree, many independent defects. Every defect MUST surface as its own
issue/finding and none may suppress the others. Scan MUST exit 0.

Planted defects:
- `.agents/skills/survivor` — HEALTHY; MUST be inventoried (ownerless).
- `.agents/skills/nameless/SKILL.md` — malformed (missing name) -> skill-md-invalid issue, no placement.
- `.agents/.skill-lock.json` — truncated JSON -> ledger-unreadable issue; scope treated as no-lock.
- `.claude/skills/rotted -> /nonexistent/rotted-target` — dangling symlink -> brokenSymlink placement + broken-symlink finding.
- `.agents/skills/README.txt`, `loose.bin` — stray non-skill files -> ignored, never placements.
- `.agents/skills/no-skill-md/` — dir without SKILL.md -> not a placement.
- `.agents/skills/locked-dir/` — see prepare-runtime.sh: chmodded 000 at runtime
  to exercise the unreadable-dir path (issue naming the path). Its inner skill
  survives once readable.

Runtime note: git cannot store a chmod-000 directory; run
`Scripts/fixtures/prepare-runtime.sh <FIXTURES_DIR>` before validators exercise
the unreadable-dir behavior. The offline smoke test does not require it.
