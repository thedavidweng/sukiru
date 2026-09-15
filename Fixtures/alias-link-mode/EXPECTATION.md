# alias-link-mode — expectation

Contents: canonical `.agents/skills/demo` plus two host symlinks
(`.claude/skills/demo`, `.codex/skills/demo`) pointing at it.

A correct scan MUST exit 0 and present `demo` as ONE logical skill with exactly
3 placements: the canonical directory plus two kind=symlink placements, each
recording its linkTarget and the SAME resolved canonicalPath. The group is an
alias duplicate (cross-host-duplicate subtype=alias, info). It MUST produce
ZERO `ambiguous-name` findings and report `demo` with ambiguous=false (D1
negative: aliases collapse to one canonical path).
