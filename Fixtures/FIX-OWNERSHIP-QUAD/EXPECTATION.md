# FIX-OWNERSHIP-QUAD — expectation

Contents: FIVE user-scope skills, one per ownership state the UI asserts on:
- `vercel-skill` — canonical `.agents/skills/vercel-skill` + global v3 lock
  entry (lock-derived source `thedavidweng/skills`, ref `refs/heads/main`).
- `gh-pinned` — `.claude/skills/gh-pinned`, github provenance, `github-pinned:
  true`, ref `refs/tags/v1.2.3`.
- `gh-unpinned` — `.claude/skills/gh-unpinned`, github provenance, NO
  `github-pinned` key (absent = unpinned), ref `refs/heads/main`.
- `double-booked-skill` — canonical store, global lock entry AND
  `metadata.github-repo` frontmatter.
- `ownerless-skill` — canonical store, no ledger of any kind.

A correct scan MUST exit 0 and resolve ownership: vercel-skill=vercel,
gh-pinned=github (pinned), gh-unpinned=github (unpinned),
double-booked-skill=double-booked, ownerless-skill=ownerless. Expected
findings: `double-booked` (both-ledger evidence), `dangerous-removal-surface`
for gh-pinned, gh-unpinned, and ownerless-skill, and `files-without-lock` for
ownerless-skill. This is deliberately NOT a clean tree — github/ownerless
skills always raise the advisory, which is why FIX-CLEAN stays vercel-only;
do not merge the two.
