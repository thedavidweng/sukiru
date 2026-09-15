# FIX-AMBIGUOUS — expectation

Contents: the name `dup` present as TWO distinct canonical directories in the
SAME (user) scope — `.claude/skills/dup` and `.codex/skills/dup` — plus a global
lock entry claiming `dup`.

A correct scan MUST exit 0, emit an `ambiguous-name` finding naming both
colliding placement paths, resolve `dup` as ownership=ownerless with
ambiguous=true (attribution voided, never guessed), and still surface the lock
claim as data (not authoritative ownership). Per D1 this is per-scope after
alias collapse; these are two REAL dirs, not symlinks, so the rule fires.
