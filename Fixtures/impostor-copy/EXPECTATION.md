# impostor-copy — expectation (VAL-SCAN-026)

Contents: `tool` exists in the canonical store (`.agents/skills/tool`, claimed
by the global v3 lock) AND in the claude-code host dir — but
`.claude/skills/tool` is a REAL DIRECTORY (a physical copy, byte-identical
content) where the managed canonical-store layout implies a symlink into the
store. A double-copied impostor.

A correct scan MUST exit 0 and emit a `symlink-authenticity` finding
identifying the impostor path (`.claude/skills/tool`) and the canonical path it
should link to (`.agents/skills/tool`). Accepting the copy silently as a
normal placement is a fail. (An exact-subtype cross-host-duplicate finding for
the pair is also legitimate; the assertion targets symlink-authenticity.)
