# divergence-canonical — expectation (VAL-SCAN-029)

Contents: a copy-mode install in `proj/` — canonical `.agents/skills/web-tool`
plus host copy `.claude/skills/web-tool`, both under ONE v1 lock source
identity. After install, the HOST COPY was overwritten out-of-band, so the two
placements hash differently; the lock's computedHash still matches the
canonical copy.

Scan with SUKIRU_HOME=<this>/.home, SUKIRU_ROOTS=<this>/proj.

A correct scan MUST exit 0 and emit a `canonical-host-divergence` finding
naming both placement paths, the shared source identity, and BOTH content
hashes. (A divergent-subtype cross-host-duplicate finding for the same pair is
also legitimate; the assertion targets canonical-host-divergence.)
