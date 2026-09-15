# FIX-USER-SCOPE-COPY-MODE — expectation (accepted v1 false positive)

Contents: `copy-tool` is a LEGITIMATE user-scope COPY-MODE install — the
global v3 lock claims it, the canonical store holds the real directory
(`.agents/skills/copy-tool`), and the claude-code and cursor host dirs hold
byte-identical PHYSICAL copies (not symlinks). This is what a copy-mode
install (`add --copy`, or older CLI versions that always copied) produces at
user scope. Nothing is rotted; nothing needs repair.

KNOWN v1 LIMITATION (accepted per the health-analyzer handoff): the
`symlink-authenticity` rule is a structural heuristic — a user-scope managed
layout implies host placements are symlinks into the canonical store, so it
flags every physical host copy as an impostor. The global lock records no
install-mode bit, so this legitimate shape is indistinguishable from a rotted
link-mode install (see `impostor-copy`).

PINNED CURRENT BEHAVIOR: a correct v1 scan MUST exit 0, resolve
ownership=vercel with ambiguous=false, emit the exact-subtype
cross-host-duplicate warning (three physical copies, one hash), NO drift and
NO lock-without-files — AND emit TWO `symlink-authenticity` warnings, one per
host copy (`.claude/skills/copy-tool`, `.cursor/skills/copy-tool`), each
carrying `canonicalPath` = the store copy. Those two findings are FALSE
POSITIVES by design in v1.

A future fix (e.g. flagging only when SIBLING host placements are symlinks
into the same store — mixed link/copy shape is the true rot signal) must flip
this expectation deliberately, with the fixture updated in the same commit.
