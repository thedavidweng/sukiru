# FIX-AMBIGUOUS — expectation

Contents: the name `dup` present as TWO distinct canonical directories in the
SAME (user) scope — `.claude/skills/dup` and `.codex/skills/dup` — plus a global
lock entry claiming `dup`.

A correct scan MUST exit 0, emit an `ambiguous-name` finding naming both
colliding placement paths, resolve `dup` as ownership=ownerless with
ambiguous=true (attribution voided, never guessed), and still surface the lock
claim as data (not authoritative ownership). Ambiguity is judged per scope
after alias collapse; these are two REAL dirs with DIVERGENT content, and
neither is explained: the lock claims `dup` but there is NO canonical-store
placement to hash-anchor them to, and neither carries gh frontmatter
— two unexplained copies, two distinct hashes, so the rule fires.
