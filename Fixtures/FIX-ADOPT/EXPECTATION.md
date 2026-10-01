# FIX-ADOPT — expectation

Contents: a two-part tree (`.home` + `proj`, scan with
SUKIRU_HOME=<this>/.home SUKIRU_ROOTS=<this>/proj) whose project scope
holds exactly one skill, `.agents/skills/stale-docs-cleanup`, with NO
project lock entry and NO gh frontmatter provenance → ownerless.

A correct scan MUST exit 0 and report:
- skill `stale-docs-cleanup` in the PROJECT workspace with ownership
  `ownerless`;
- findings `files-without-lock` and `dangerous-removal-surface` for it;
- nothing else.

The name deliberately MATCHES the real upstream test skill
(thedavidweng/skills, path `maintenance/stale-docs-cleanup/SKILL.md`):
probe-verified `gh skill install <repo> <path> --force --dir <parent>`
treats `--dir` as the skills ROOT and installs into `<parent>/<repo skill
name>`, so adopt only re-anchors provenance onto an existing directory
when the names agree. The skill lives in PROJECT scope because gh install
pollutes the vercel GLOBAL lock on user-scope installs (→ instant
double-booked); project-scope installs stay github-only. After the adopt
batch executes (GH_TOKEN injected), a rescan MUST show ownership `github`
with frontmatter `github-repo`/`github-path`/`github-ref`/`github-tree-sha`
on disk and NO `files-without-lock` finding.
