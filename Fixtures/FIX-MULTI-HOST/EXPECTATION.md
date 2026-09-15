# FIX-MULTI-HOST — expectation (M3 health-area, VAL-HEALTH-005/009)

Contents: `web-api` lives in the canonical user store (`.agents/skills`,
global v3 lock, ownership=vercel) and is SYMLINKED into three host global
dirs — claude-code (`.claude/skills`), codex (`.codex/skills`), cursor
(`.cursor/skills`) — each host detected via a config.json marker. `.qoder/`
contains ONLY an empty `skills/` entry: CLI spray residue (leftover,
installed=false), which sees NO skills.

A correct scan MUST exit 0 and present `web-api` as ONE logical skill with 4
placements (1 canonical directory + 3 symlinks sharing one canonical path) —
never as four skills. The ONLY finding is the info-severity alias
cross-host-duplicate. The qoder workspace MUST be reported installed=false
(leftover) and must NOT count as a host that sees `web-api`; the app's
host-presence region lists exactly claude-code, codex, and cursor.
