# symlink-mode — expectation

Contents: canonical `.agents/skills/tool` (vercel-owned, global lock) aliased
into the claude-code host via a symlink. This is the healthy symlink-mode install
shape (one canonical copy, hosts symlink to it) — contrast copy mode, which
double-copies.

A correct scan MUST exit 0 and present `tool` as ONE logical skill,
ownership=vercel, ambiguous=false, with 2 placements (canonical directory + one
symlink sharing the canonical path). The only finding permitted is the
info-severity alias duplicate; NO actionable findings (no divergence, no drift,
no double-booking).
