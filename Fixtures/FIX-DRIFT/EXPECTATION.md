# FIX-DRIFT — expectation (M3 health-area, VAL-HEALTH-014/038)

Contents: project root `proj/` holds `drifted`, whose SKILL.md was edited
out-of-band after install — the v1 lock's computedHash (hash of the ORIGINAL
content) no longer matches disk. The fake home is empty.

Scan with SUKIRU_HOME=<this>/.home SUKIRU_ROOTS=<this>/proj.

A correct scan MUST exit 0, resolve `drifted` as ownership=vercel, and emit a
`vercel-lock-drift` finding (severity action) whose evidence names the lock
path, the entry key, the stored (expected) hash, and the recomputed (actual)
hash. The app Health surface MUST render that finding with an expandable
evidence block and a reveal-in-Library navigation action.
