# FIX-HOST-DIVERGENCE — expectation

Contents: a copy-mode install in `proj/` — canonical `.agents/skills/web-tool`
plus host copy `.claude/skills/web-tool` under ONE v1 lock source identity.
The host copy was overwritten out-of-band, so the two placements hash
differently; the lock computedHash still matches the CANONICAL copy.

Scan with SUKIRU_HOME=<this>/.home SUKIRU_ROOTS=<this>/proj.

A correct scan MUST exit 0 and emit a `canonical-host-divergence` finding
(severity action) naming both placement paths, the shared source identity,
and BOTH content hashes. The drifted host copy also legitimately raises
`vercel-lock-drift` (its hash no longer matches the lock) and the pair is a
divergent cross-host duplicate; `web-tool` stays ownership=vercel,
ambiguous=false (the lock hash explains the canonical placement).
